import Cocoa
import WebKit

// MARK: - DropForwardingWebView
// WKWebView intercepts drags from Finder before its parent NSView ever sees
// them (it tries to navigate to the file URL). Subclass and forward drops
// up to the host TermPane so we can paste the path into the terminal instead.

final class DropForwardingWebView: WKWebView {
    weak var dropTarget: TermPane?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let t = dropTarget { return t.draggingEntered(sender) }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let t = dropTarget { return t.performDragOperation(sender) }
        return super.performDragOperation(sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }
}

// MARK: - TermPane (WKWebView host with drag-drop)

final class TermPane: NSView, WKNavigationDelegate, WKUIDelegate {
    let webView: DropForwardingWebView

    override init(frame frameRect: NSRect) {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        cfg.applicationNameForUserAgent = "slyTerm/2.0"
        if #available(macOS 11.0, *) {
            cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        webView = DropForwardingWebView(frame: frameRect, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(webView)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.dropTarget = self
        // Register BOTH the WKWebView and the host view. The WKWebView is on
        // top in the hit-test chain, so it must accept drops first; it then
        // forwards them here via DropForwardingWebView.
        webView.registerForDraggedTypes([.fileURL, .string, .URL])
        registerForDraggedTypes([.fileURL, .string, .URL])
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    func load() {
        if let url = URL(string: "http://localhost:7681") {
            webView.load(URLRequest(url: url))
        }
    }

    func reload() { webView.reload() }

    // Become first responder so Edit menu actions reach the WebView
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(webView)
        return true
    }

    // MARK: - Drag and drop -> paste into terminal

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var text: String? = nil

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            // Quote paths with spaces, join with spaces — terminal-friendly
            text = urls.map { url -> String in
                let path = url.isFileURL ? url.path : url.absoluteString
                return path.contains(" ") ? "\"\(path)\"" : path
            }.joined(separator: " ")
        } else if let str = pb.string(forType: .string) {
            text = str
        }

        guard let payload = text else { return false }
        injectIntoTerminal(payload)
        return true
    }

    private func injectIntoTerminal(_ text: String) {
        // ttyd's xterm.js exposes window.term — paste via term.paste(...)
        // Fallback: dispatch a paste InputEvent on the active textarea.
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
            if (window.term && typeof window.term.paste === 'function') { window.term.paste(s); return 'term.paste'; }
            if (window.term && window.term._core && window.term._core.coreService) {
              window.term._core.coreService.triggerDataEvent(s, true); return 'coreService';
            }
          } catch(e) {}
          var ta = document.querySelector('textarea.xterm-helper-textarea') || document.querySelector('textarea');
          if (ta) {
            ta.focus();
            var ev = new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: new DataTransfer() });
            try { ev.clipboardData.setData('text/plain', s); } catch(e) {}
            ta.dispatchEvent(ev);
            return 'textarea';
          }
          return 'noop';
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - SplitContainer

final class SplitContainer: NSView {
    let pane: TermPane
    override init(frame frameRect: NSRect) {
        pane = TermPane(frame: frameRect)
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        pane.frame = bounds
        addSubview(pane)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        pane.frame = bounds
    }
}

// MARK: - AppWindow

final class AppWindow: NSWindow {
    let container: SplitContainer

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        container = SplitContainer(frame: frame)
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Hide the title text from the title bar (keeps traffic-light buttons).
        title = ""
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        // Native macOS tab support — ⌘T merges new windows into a tab bar.
        tabbingMode = .preferred
        tabbingIdentifier = "com.sly.slyterm.main"
        contentView = container
        center()
        makeFirstResponder(container.pane)
    }
}

// MARK: - DockAnimator
//
// Two-frame dock tile: idle = >_< sticker, active = headphones DJ creature.
// Flips to active on any keystroke inside the app, returns to idle after a
// stretch of no input. Frames live in the app bundle's Resources.

final class DockAnimator {
    enum State { case idle, active }

    private let idleImage: NSImage?
    private let activeImage: NSImage?
    private(set) var state: State = .idle
    private var idleTimer: Timer?
    private let idleAfter: TimeInterval = 60

    init() {
        idleImage = Self.loadFrame("claude_eyes")
        activeImage = Self.loadFrame("claude_dj")
        apply(.idle, force: true)
    }

    private static func loadFrame(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }

    func noteActivity() {
        if state != .active { apply(.active) }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleAfter, repeats: false) { [weak self] _ in
            self?.apply(.idle)
        }
    }

    private func apply(_ s: State, force: Bool = false) {
        if !force && state == s { return }
        state = s
        let img = (s == .idle) ? idleImage : activeImage
        guard let img = img else { return }
        let iv = NSImageView(image: img)
        iv.imageScaling = .scaleProportionallyUpOrDown
        NSApp.dockTile.contentView = iv
        NSApp.dockTile.display()
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [AppWindow] = []
    let dockAnimator = DockAnimator()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        spawnWindow()
        NSApp.activate(ignoringOtherApps: true)
        // Any keystroke in the app marks "active" for the dock tile.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.dockAnimator.noteActivity()
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @discardableResult
    private func spawnWindow() -> AppWindow {
        let w = AppWindow()
        windows.append(w)
        w.makeKeyAndOrderFront(nil)
        return w
    }

    // MARK: - File menu actions

    @objc func newWindow(_ sender: Any?) {
        spawnWindow()
    }

    @objc func newTab(_ sender: Any?) {
        let w = AppWindow()
        windows.append(w)
        if let cur = NSApp.keyWindow {
            cur.addTabbedWindow(w, ordered: .above)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - View menu: font size (xterm.js fontSize)

    @objc func biggerFont(_ sender: Any?)  { adjustFont(delta: +1) }
    @objc func smallerFont(_ sender: Any?) { adjustFont(delta: -1) }
    @objc func actualFont(_ sender: Any?)  { adjustFont(delta: 0, absolute: 14) }

    private func adjustFont(delta: Int, absolute: Int? = nil) {
        guard let win = NSApp.keyWindow as? AppWindow else { return }
        let js: String
        if let abs = absolute {
            js = """
            (function(){
              if (!window.term) return;
              window.term.options.fontSize = \(abs);
              if (window.term.fit) try { window.term.fit(); } catch(e) {}
            })();
            """
        } else {
            js = """
            (function(){
              if (!window.term) return;
              var s = (window.term.options && window.term.options.fontSize) || 14;
              s = Math.max(8, Math.min(40, s + (\(delta))));
              window.term.options.fontSize = s;
              if (window.term.fit) try { window.term.fit(); } catch(e) {}
            })();
            """
        }
        win.container.pane.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About slyTerm",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide slyTerm",
                                   action: #selector(NSApplication.hide(_:)),
                                   keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit slyTerm",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        // File menu — restores ⌘N (New Window) and ⌘T (New Tab)
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let newWin = NSMenuItem(title: "New Window",
                                action: #selector(newWindow(_:)),
                                keyEquivalent: "n")
        newWin.target = self
        fileMenu.addItem(newWin)
        let newTabItem = NSMenuItem(title: "New Tab",
                                    action: #selector(newTab(_:)),
                                    keyEquivalent: "t")
        newTabItem.target = self
        fileMenu.addItem(newTabItem)
        fileMenu.addItem(.separator())
        let closeWin = NSMenuItem(title: "Close Window",
                                  action: #selector(NSWindow.performClose(_:)),
                                  keyEquivalent: "w")
        fileMenu.addItem(closeWin)
        fileMenuItem.submenu = fileMenu

        // Edit menu — THIS is what makes ⌘V work
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo",
                                    action: Selector(("undo:")),
                                    keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo",
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",
                                    action: #selector(NSText.cut(_:)),
                                    keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",
                                    action: #selector(NSText.copy(_:)),
                                    keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",
                                    action: #selector(NSText.paste(_:)),
                                    keyEquivalent: "v"))
        let pasteAndMatch = NSMenuItem(title: "Paste and Match Style",
                                       action: Selector(("pasteAsPlainText:")),
                                       keyEquivalent: "v")
        pasteAndMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(pasteAndMatch)
        editMenu.addItem(NSMenuItem(title: "Delete",
                                    action: #selector(NSText.delete(_:)),
                                    keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Select All",
                                    action: #selector(NSText.selectAll(_:)),
                                    keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        // View menu — Reload
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let reload = NSMenuItem(title: "Reload",
                                action: #selector(reloadActive),
                                keyEquivalent: "r")
        reload.target = self
        viewMenu.addItem(reload)
        let toggleFullScreen = NSMenuItem(title: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)),
                                          keyEquivalent: "f")
        toggleFullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleFullScreen)

        // Font size — ⌘+ / ⌘- / ⌘0
        viewMenu.addItem(.separator())
        let bigger = NSMenuItem(title: "Bigger",
                                action: #selector(biggerFont(_:)),
                                keyEquivalent: "+")
        bigger.target = self
        viewMenu.addItem(bigger)
        let smaller = NSMenuItem(title: "Smaller",
                                 action: #selector(smallerFont(_:)),
                                 keyEquivalent: "-")
        smaller.target = self
        viewMenu.addItem(smaller)
        let actual = NSMenuItem(title: "Actual Size",
                                action: #selector(actualFont(_:)),
                                keyEquivalent: "0")
        actual.target = self
        viewMenu.addItem(actual)

        viewMenuItem.submenu = viewMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom",
                                      action: #selector(NSWindow.performZoom(_:)),
                                      keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func reloadActive() {
        let target = (NSApp.keyWindow as? AppWindow) ?? windows.first
        target?.container.pane.reload()
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
