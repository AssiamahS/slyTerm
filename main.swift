import Cocoa
import WebKit

// Transparent overlay that sits ON TOP of the WKWebView and intercepts
// Finder drags before the web view can swallow them. Using an overlay
// instead of subclassing WKWebView avoids fighting WebKit's internal drag
// handling, which became unreliable on macOS 26.
final class DropOverlayView: NSView {
    var onDrop: ((NSDraggingInfo) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .string, .URL, .tiff, .png]
        // File promise types — macOS screenshot floating thumbnail and other
        // NSItemProvider sources hand off via NSFilePromiseReceiver instead of
        // a direct file URL.
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) })
        registerForDraggedTypes(types)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Transparent to mouse/keyboard events so clicks, scroll, and key
    // input still reach the WKWebView underneath — but visible to the
    // AppKit drag-and-drop dispatcher, which also uses hitTest: to find
    // the drop target. Returning nil for everything (the previous
    // behavior) preserved copy/paste but silently broke Finder drops.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Cross-app drags from Finder dispatch with no NSApp.currentEvent
        // (the event originated in another process). Claim the hit so we
        // receive draggingEntered:/performDragOperation:.
        guard let event = NSApp.currentEvent else { return self }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .mouseEntered, .mouseExited,
             .scrollWheel, .keyDown, .keyUp, .flagsChanged,
             .cursorUpdate, .tabletPoint, .tabletProximity,
             .gesture, .magnify, .swipe, .rotate,
             .beginGesture, .endGesture,
             .smartMagnify, .pressure, .directTouch, .changeMode:
            return nil
        default:
            // appKitDefined and other system events (used by drag tracking)
            return self
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return onDrop?(sender) ?? false
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }
}

func slyLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    let path = ("~/Library/Logs/slyterm.log" as NSString).expandingTildeInPath
    if let data = line.data(using: .utf8) {
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// tmux is the source of truth for which chats exist: one window in the
/// "slywatch" group per chat, one TermPane per window. Everything here runs
/// /opt/homebrew/bin/tmux synchronously and is called off the main thread.
enum Tmux {
    static let group = "slywatch"
    static let homeWindow = "home"
    static var path: String? {
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    @discardableResult
    static func run(_ args: [String]) -> (status: Int32, out: String) {
        guard let path else { return (127, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (126, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Chat windows in the group (the sleeper "home" window excluded).
    static func windows() -> [String]? {
        let r = run(["list-windows", "-t", "=" + group, "-F", "#{window_name}"])
        guard r.status == 0 else { return nil }
        return r.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty && $0 != homeWindow }
    }

    /// Window names that currently have a live client (= a tab whose
    /// websocket is still connected). A pane whose window is missing from
    /// this set is showing a dead connection.
    static func attachedWindows() -> Set<String> {
        let r = run(["list-clients", "-F", "#{session_group} #{window_name}"])
        guard r.status == 0 else { return [] }
        var out = Set<String>()
        for line in r.out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 1)
            if f.count == 2, f[0] == group { out.insert(String(f[1])) }
        }
        return out
    }

    static func killWindow(_ name: String) {
        let r = run(["kill-window", "-t", "=\(group):=\(name)"])
        slyLog("tmux kill-window \(name) status=\(r.status)")
    }
}

class TermPane: NSView, WKNavigationDelegate {
    static let backend = "http://127.0.0.1:7681/"
    let webView: WKWebView
    let dropOverlay = DropOverlayView(frame: .zero)
    /// tmux window name this tab is bound to (passed to ttyd as ?arg=).
    let name: String
    /// Set once the supervisor has seen our window exist; a later absence
    /// then means the chat ended (as opposed to "not created yet").
    var sawWindow = false
    private(set) var loaded = false
    private var loadStartedAt = Date()
    private var retryDelay: TimeInterval = 0.5
    private var retryTimer: Timer?
    private let status = NSTextField(labelWithString: "")

    var secondsSinceLoad: TimeInterval { Date().timeIntervalSince(loadStartedAt) }

    static func makeName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HHmmss"
        return "sly-\(fmt.string(from: Date()))-\(String(format: "%02x", Int.random(in: 0..<256)))"
    }

    init(name: String? = nil) {
        self.name = name ?? Self.makeName()
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        self.webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) slyTerm/1.0"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = NSColor.clear.cgColor
        layer?.borderWidth = 1
        // No white flash / white void: the page background is ours until
        // xterm paints.
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .black }
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        status.textColor = NSColor.white.withAlphaComponent(0.6)
        status.alignment = .center
        status.isHidden = true
        addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: centerXAnchor),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
        // Drop overlay on top of webView (added last = topmost)
        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dropOverlay)
        NSLayoutConstraint.activate([
            dropOverlay.topAnchor.constraint(equalTo: topAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            dropOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        dropOverlay.onDrop = { [weak self] info in
            return self?.handleDrop(info) ?? false
        }
        load(reason: "open")
    }

    deinit { retryTimer?.invalidate() }

    // MARK: - Loading with retry (ttyd may not be up yet at login)

    func load(reason: String) {
        retryTimer?.invalidate(); retryTimer = nil
        loaded = false
        loadStartedAt = Date()
        var comps = URLComponents(string: Self.backend)!
        comps.queryItems = [URLQueryItem(name: "arg", value: name)]
        guard let url = comps.url else { return }
        slyLog("pane \(name): load (\(reason))")
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10))
    }

    private func showStatus(_ text: String) {
        status.stringValue = text
        status.isHidden = false
    }

    private func scheduleRetry(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }   // superseded by a newer load
        loaded = false
        showStatus("waiting for terminal backend 127.0.0.1:7681 … (\(ns.code)) retrying")
        slyLog("pane \(name): load failed \(ns.domain)/\(ns.code) — retry in \(retryDelay)s")
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
            self?.load(reason: "retry")
        }
        retryDelay = min(retryDelay * 2, 5)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        retryDelay = 0.5
        status.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        scheduleRetry(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        scheduleRetry(error)
    }

    /// WebKit killed the content process (memory pressure during sleep is
    /// the usual cause) — that is the classic silent white screen.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        slyLog("pane \(name): web content process terminated")
        load(reason: "content-process-died")
    }

    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ active: Bool, paneCount: Int) {
        if paneCount > 1 && active {
            layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        } else {
            layer?.borderColor = NSColor.clear.cgColor
        }
    }

    // MARK: - Drag and drop -> paste file path into terminal

    private static func dropLog(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let path = ("~/Library/Logs/slyterm-drop.log" as NSString).expandingTildeInPath
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }

    private func handleDrop(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        // Debug: log every type the source put on the pasteboard
        let types = pb.types?.map { $0.rawValue }.joined(separator: ", ") ?? "<nil>"
        let itemTypes = (pb.pasteboardItems ?? []).enumerated().map { (i, it) in
            "item\(i)[\(it.types.map { $0.rawValue }.joined(separator: "|"))]"
        }.joined(separator: " ")
        Self.dropLog("DROP types=[\(types)] items=\(itemTypes)")

        // 1. Direct file URLs (Finder, most apps)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            Self.dropLog("  -> matched NSURL: \(urls.map { $0.path })")
            let text = urls.map { url -> String in
                let path = url.isFileURL ? url.path : url.absoluteString
                return path.contains(" ") ? "\"\(path)\"" : path
            }.joined(separator: " ")
            injectIntoTerminal(text)
            return true
        }

        // 2. File promises (macOS screenshot floating thumbnail, Mail attachments,
        // anything using NSItemProvider with a file representation). The sender
        // hands us NSFilePromiseReceivers; we resolve them to real files in our
        // dropbox dir. The resolution is async, so we accept the drop now and
        // inject when the files materialize.
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            Self.dropLog("  -> matched NSFilePromiseReceiver: count=\(receivers.count) types=\(receivers.flatMap { $0.fileTypes })")
            let destStr = ("~/Pictures/slyterm-drops" as NSString).expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: destStr, withIntermediateDirectories: true)
            let dest = URL(fileURLWithPath: destStr)
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1   // serialize callbacks (fix v2.5 race)
            var paths: [String] = []
            let group = DispatchGroup()
            for receiver in receivers {
                group.enter()
                receiver.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: queue) { url, error in
                    if let error = error {
                        Self.dropLog("  -> receivePromisedFiles error: \(error)")
                    } else {
                        Self.dropLog("  -> receivePromisedFiles got: \(url.path)")
                        paths.append(url.path)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                Self.dropLog("  -> promise resolution complete, paths=\(paths)")
                guard !paths.isEmpty else { return }
                let text = paths.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
                self?.injectIntoTerminal(text)
            }
            return true
        }

        // 3. Raw image data (Shottr/CleanShot snap mode — image bytes on the
        // pasteboard with no file URL or promise).
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !images.isEmpty {
            Self.dropLog("  -> matched NSImage: count=\(images.count)")
            let saved = images.compactMap { Self.saveDroppedImage($0) }
            if !saved.isEmpty {
                let text = saved.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
                injectIntoTerminal(text)
                return true
            }
        }

        // 4. Plain string fallback
        if let str = pb.string(forType: .string) {
            Self.dropLog("  -> matched plain string")
            injectIntoTerminal(str)
            return true
        }

        Self.dropLog("  -> NO MATCH, returning false")
        return false
    }

    private static func saveDroppedImage(_ image: NSImage) -> String? {
        let dir = ("~/Pictures/slyterm-drops" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let path = "\(dir)/drop-\(fmt.string(from: Date())).png"
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil ? path : nil
    }

    func injectIntoTerminal(_ text: String) {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        let js = """
        (function(){
          var s = "\(escaped)";
          try {
            if (window.term && typeof window.term.paste === 'function') { window.term.paste(s); return; }
            if (window.term && window.term._core && window.term._core.coreService) {
              window.term._core.coreService.triggerDataEvent(s, true); return;
            }
          } catch(e) {}
          var ta = document.querySelector('textarea.xterm-helper-textarea') || document.querySelector('textarea');
          if (ta) {
            ta.focus();
            var ev = new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: new DataTransfer() });
            try { ev.clipboardData.setData('text/plain', s); } catch(e) {}
            ta.dispatchEvent(ev);
          }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

class SplitContainer: NSView {
    var panes: [TermPane] = []
    var activeIndex: Int = 0
    private var gridConstraints: [NSLayoutConstraint] = []

    init(frame: NSRect, initialPane: String?) {
        super.init(frame: frame)
        addPane(name: initialPane)
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func addPane(name: String? = nil) -> TermPane? {
        guard panes.count < 4 else { return nil }
        let pane = TermPane(name: name)
        pane.translatesAutoresizingMaskIntoConstraints = false
        let click = NSClickGestureRecognizer(target: self, action: #selector(paneClicked(_:)))
        pane.addGestureRecognizer(click)
        panes.append(pane)
        addSubview(pane)
        activeIndex = panes.count - 1
        relayout()
        return pane
    }

    @objc func paneClicked(_ sender: NSClickGestureRecognizer) {
        guard let pane = sender.view as? TermPane,
              let idx = panes.firstIndex(where: { $0 === pane }) else { return }
        activeIndex = idx
        updateBorders()
    }

    func removeActivePane() {
        guard panes.indices.contains(activeIndex) else { return }
        removePane(panes[activeIndex], killChat: true)
    }

    /// killChat: closing a tab ends its chat (1:1 with tmux and the watch);
    /// false when the chat already ended and the tab is just following it.
    func removePane(_ pane: TermPane, killChat: Bool) {
        guard panes.count > 1, let idx = panes.firstIndex(where: { $0 === pane }) else { return }
        pane.removeFromSuperview()
        panes.remove(at: idx)
        activeIndex = min(max(0, activeIndex >= idx ? activeIndex - 1 : activeIndex), panes.count - 1)
        if killChat {
            let name = pane.name
            DispatchQueue.global().async { Tmux.killWindow(name) }
        }
        relayout()
    }

    func updateBorders() {
        for (i, pane) in panes.enumerated() {
            pane.setActive(i == activeIndex, paneCount: panes.count)
        }
    }

    func relayout() {
        NSLayoutConstraint.deactivate(gridConstraints)
        gridConstraints.removeAll()
        let gap: CGFloat = 1

        switch panes.count {
        case 1:
            let p = panes[0]
            gridConstraints = [
                p.topAnchor.constraint(equalTo: topAnchor),
                p.bottomAnchor.constraint(equalTo: bottomAnchor),
                p.leadingAnchor.constraint(equalTo: leadingAnchor),
                p.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        case 2:
            let l = panes[0], r = panes[1]
            gridConstraints = [
                l.topAnchor.constraint(equalTo: topAnchor),
                l.bottomAnchor.constraint(equalTo: bottomAnchor),
                l.leadingAnchor.constraint(equalTo: leadingAnchor),
                l.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -gap),
                r.topAnchor.constraint(equalTo: topAnchor),
                r.bottomAnchor.constraint(equalTo: bottomAnchor),
                r.leadingAnchor.constraint(equalTo: centerXAnchor, constant: gap),
                r.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        case 3:
            let tl = panes[0], tr = panes[1], b = panes[2]
            gridConstraints = [
                tl.topAnchor.constraint(equalTo: topAnchor),
                tl.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -gap),
                tl.leadingAnchor.constraint(equalTo: leadingAnchor),
                tl.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -gap),
                tr.topAnchor.constraint(equalTo: topAnchor),
                tr.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -gap),
                tr.leadingAnchor.constraint(equalTo: centerXAnchor, constant: gap),
                tr.trailingAnchor.constraint(equalTo: trailingAnchor),
                b.topAnchor.constraint(equalTo: centerYAnchor, constant: gap),
                b.bottomAnchor.constraint(equalTo: bottomAnchor),
                b.leadingAnchor.constraint(equalTo: leadingAnchor),
                b.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        case 4:
            let tl = panes[0], tr = panes[1], bl = panes[2], br = panes[3]
            gridConstraints = [
                tl.topAnchor.constraint(equalTo: topAnchor),
                tl.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -gap),
                tl.leadingAnchor.constraint(equalTo: leadingAnchor),
                tl.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -gap),
                tr.topAnchor.constraint(equalTo: topAnchor),
                tr.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -gap),
                tr.leadingAnchor.constraint(equalTo: centerXAnchor, constant: gap),
                tr.trailingAnchor.constraint(equalTo: trailingAnchor),
                bl.topAnchor.constraint(equalTo: centerYAnchor, constant: gap),
                bl.bottomAnchor.constraint(equalTo: bottomAnchor),
                bl.leadingAnchor.constraint(equalTo: leadingAnchor),
                bl.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -gap),
                br.topAnchor.constraint(equalTo: centerYAnchor, constant: gap),
                br.bottomAnchor.constraint(equalTo: bottomAnchor),
                br.leadingAnchor.constraint(equalTo: centerXAnchor, constant: gap),
                br.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        default: break
        }
        NSLayoutConstraint.activate(gridConstraints)
        updateBorders()
    }
}

class AppWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if let mainMenu = NSApp.mainMenu {
                if mainMenu.performKeyEquivalent(with: event) { return }
            }
        }
        super.keyDown(with: event)
    }
}

// Clear xterm selection on all panes when clicking anywhere.
// Must use mouseDown — mouseUp also fires at the end of a drag-to-select,
// which would wipe the selection the user just made.
func installClickMonitor() {
    NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
        if let delegate = NSApp.delegate as? AppDelegate {
            for entry in delegate.windows {
                for pane in entry.split.panes {
                    pane.webView.evaluateJavaScript(
                        "if(window.term&&window.term.hasSelection())window.term.clearSelection()",
                        completionHandler: nil
                    )
                }
            }
        }
        return event
    }
}

// Intercept Cmd shortcuts before WebView can swallow them
// But let Cmd+C/V/X/A pass through to WebView for terminal copy/paste.
func installKeyMonitor() {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.modifierFlags.contains(.command) {
            let chars = event.charactersIgnoringModifiers ?? ""
            // Cmd+V: always intercept and inject from NSPasteboard. WKWebView
            // blocks navigator.clipboard.readText() from cross-origin reads, so
            // xterm.js's own paste handler silently fails when the clipboard
            // came from another app. Reading the system pasteboard in Swift and
            // injecting via JS bypasses the WebKit restriction entirely.
            if chars == "v" {
                let pb = NSPasteboard.general
                var payload: String? = nil
                if let s = pb.string(forType: .string), !s.isEmpty {
                    payload = s
                } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
                    payload = urls.map { url -> String in
                        let path = url.isFileURL ? url.path : url.absoluteString
                        return path.contains(" ") ? "\"\(path)\"" : path
                    }.joined(separator: " ")
                }
                if let text = payload,
                   let delegate = NSApp.delegate as? AppDelegate,
                   let split = delegate.activeSplit,
                   split.panes.indices.contains(split.activeIndex) {
                    split.panes[split.activeIndex].injectIntoTerminal(text)
                    return nil
                }
                return event
            }
            // Let copy/cut/selectAll go to WebView (xterm.js handles them)
            if ["c", "x", "a"].contains(chars) {
                return event
            }
            if let mainMenu = NSApp.mainMenu, mainMenu.performKeyEquivalent(with: event) {
                return nil // consumed
            }
        }
        return event
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [(window: NSWindow, split: SplitContainer)] = []

    private var terminating = false
    private var supervisor: Timer?
    private let tmuxQueue = DispatchQueue(label: "slyterm.tmux")
    /// Orphan windows must be seen on two consecutive polls before a tab is
    /// opened for them, so a window mid-creation is never double-adopted.
    private var orphanSeen: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        installKeyMonitor()
        installClickMonitor()
        slyLog("launch v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
        // Chats already alive in tmux (previous run, a crash, the watch)
        // come back as tabs; only a truly empty tmux gets a fresh chat.
        tmuxQueue.async { [weak self] in
            let attached = Tmux.attachedWindows()
            let existing = (Tmux.windows() ?? []).filter { !attached.contains($0) }
            DispatchQueue.main.async {
                guard let self else { return }
                if existing.isEmpty {
                    self.openNewWindow()
                } else {
                    slyLog("adopting \(existing.count) live chat(s): \(existing.joined(separator: ", "))")
                    for name in existing { self.adopt(name) }
                }
                self.startSupervisor()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            slyLog("wake")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.superviseTick() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
    }

    // MARK: - tmux supervisor (every 3s): reattach dead tabs, adopt orphans

    private func startSupervisor() {
        supervisor = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.superviseTick()
        }
    }

    private var allPanes: [TermPane] { windows.flatMap { $0.split.panes } }

    private func superviseTick() {
        guard !terminating else { return }
        tmuxQueue.async { [weak self] in
            guard let self else { return }
            guard let names = Tmux.windows() else { return }   // tmux gone: nothing to do
            let attached = Tmux.attachedWindows()
            DispatchQueue.main.async { self.reconcile(windows: Set(names), attached: attached) }
        }
    }

    private func reconcile(windows names: Set<String>, attached: Set<String>) {
        guard !terminating else { return }
        var owned = Set<String>()
        for pane in allPanes {
            owned.insert(pane.name)
            if names.contains(pane.name) {
                pane.sawWindow = true
                // Window alive but no client on it and our page has had time
                // to connect → the websocket died (sleep, ttyd restart, …).
                if pane.loaded, pane.secondsSinceLoad > 10, !attached.contains(pane.name) {
                    slyLog("pane \(pane.name): window alive but detached — reattaching")
                    pane.load(reason: "detached")
                }
            } else if pane.sawWindow, pane.secondsSinceLoad > 10 {
                // The chat ended (claude exited, or it was closed from the
                // watch / another terminal): the tab follows it. tmux is the
                // source of truth, so a tab never outlives its chat.
                slyLog("pane \(pane.name): window gone — closing tab")
                closeTab(of: pane)
            }
        }
        // Orphan = a chat window nobody is attached to (started from the
        // watch, or left behind by a quit/crash). A window some other client
        // is viewing — Terminal.app via `ccw`, a phone ssh — is theirs.
        let orphans = names.subtracting(owned).subtracting(attached)
        for name in orphans where orphanSeen.contains(name) {
            slyLog("adopting orphan chat \(name)")
            adopt(name)
        }
        orphanSeen = orphans
    }

    private func closeTab(of pane: TermPane) {
        guard let entry = windows.first(where: { $0.split.panes.contains { $0 === pane } }) else { return }
        if entry.split.panes.count > 1 {
            entry.split.removePane(pane, killChat: false)
        } else {
            entry.window.performClose(nil)   // its chat is already gone
        }
    }

    /// Give a tmux window a tab: fill the key window's split first (max 4),
    /// otherwise open a new window for it.
    private func adopt(_ name: String) {
        if allPanes.contains(where: { $0.name == name }) { return }
        if let split = activeSplit, split.panes.count < 4, split.addPane(name: name) != nil { return }
        openNewWindow(initialPane: name)
    }

    func openNewWindow(initialPane: String? = nil) {
        let split = SplitContainer(frame: .zero, initialPane: initialPane)
        split.translatesAutoresizingMaskIntoConstraints = false

        let win = AppWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "slyTerm"
        win.backgroundColor = .black
        // A window created in code defaults to isReleasedWhenClosed = true,
        // so AppKit released it on close while ARC still owned it through
        // `windows` — the double release surfaced later as
        // -[_NSWindowTransformAnimation dealloc] → objc_release SIGSEGV
        // during the close animation's CA transaction. ARC is the only owner.
        win.isReleasedWhenClosed = false
        win.contentView?.addSubview(split)
        if let cv = win.contentView {
            NSLayoutConstraint.activate([
                split.topAnchor.constraint(equalTo: cv.topAnchor),
                split.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
                split.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            ])
        }

        // Offset from existing windows, clamped so the cascade can never
        // walk a new window off the visible screen.
        if let last = windows.last(where: { $0.window.isVisible })?.window {
            var origin = NSPoint(x: last.frame.origin.x + 30, y: last.frame.origin.y - 30)
            if let vis = (last.screen ?? NSScreen.main)?.visibleFrame {
                if origin.y < vis.minY || origin.x + win.frame.width > vis.maxX {
                    origin = NSPoint(x: vis.minX + 40, y: vis.maxY - win.frame.height - 40)
                }
            }
            win.setFrameOrigin(origin)
        } else {
            win.center()
        }

        // Prune the tracking array when a window closes by ANY path (red
        // button included). Without this, activeSplit could target a dead
        // window and Cmd+T would spawn panes — and Claude chats — invisibly.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] note in
            guard let self, let closed = note.object as? NSWindow else { return }
            if let entry = self.windows.first(where: { $0.window === closed }), !self.terminating {
                // Red button / Cmd+W on the last split: end every chat in it.
                let names = entry.split.panes.map { $0.name }
                self.tmuxQueue.async { names.forEach(Tmux.killWindow) }
            }
            self.windows.removeAll { $0.window === closed }
        }

        win.makeKeyAndOrderFront(nil)
        windows.append((window: win, split: split))
    }

    var activeSplit: SplitContainer? {
        if let keyWindow = NSApp.keyWindow,
           let entry = windows.first(where: { $0.window === keyWindow }) {
            return entry.split
        }
        if let mainWindow = NSApp.mainWindow,
           let entry = windows.first(where: { $0.window === mainWindow }) {
            return entry.split
        }
        return windows.last(where: { $0.window.isVisible })?.split
    }

    func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About slyTerm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide slyTerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit slyTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Shell menu
        let shellMenuItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        shellMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        shellMenu.addItem(withTitle: "New Split", action: #selector(newSplit), keyEquivalent: "t")
        shellMenu.addItem(withTitle: "Close Split", action: #selector(closeSplit), keyEquivalent: "w")
        shellMenuItem.submenu = shellMenu
        mainMenu.addItem(shellMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewMenu.items.last?.keyEquivalentModifierMask = [.command, .control]
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func newWindow() {
        openNewWindow()
    }

    @objc func newSplit() {
        guard let split = activeSplit else {
            // No visible window to split — give the user a fresh one instead
            // of silently doing nothing (or worse, feeding a dead window).
            openNewWindow()
            return
        }
        let before = split.panes.count
        split.addPane()
        if split.panes.count == before { NSSound.beep() }  // at the 4-pane cap
    }

    @objc func closeSplit() {
        guard let split = activeSplit,
              let entry = windows.first(where: { $0.split === split }) else { return }
        if split.panes.count <= 1 {
            entry.window.performClose(nil)   // willClose prunes + kills the chat
        } else {
            split.removeActivePane()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay running — dock click reopens a window (see reopen handler).
        // Now that `windows` is pruned correctly, returning isEmpty here
        // would quit the app on last close, which the old (buggy) behavior
        // never did.
        return false
    }

    // Clicking the dock icon when no windows are visible should open one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openNewWindow() }
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
