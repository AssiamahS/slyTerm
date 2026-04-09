import Cocoa
import WebKit

class TermPane: NSView {
    let webView: WKWebView

    init() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        self.webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) slyTerm/1.0"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderColor = NSColor.clear.cgColor
        layer?.borderWidth = 1
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        if let url = URL(string: "http://localhost:7681") {
            webView.load(URLRequest(url: url))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ active: Bool, paneCount: Int) {
        if paneCount > 1 && active {
            layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        } else {
            layer?.borderColor = NSColor.clear.cgColor
        }
    }
}

class SplitContainer: NSView {
    var panes: [TermPane] = []
    var activeIndex: Int = 0
    private var gridConstraints: [NSLayoutConstraint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addPane()
    }

    required init?(coder: NSCoder) { fatalError() }

    func addPane() {
        guard panes.count < 4 else { return }
        let pane = TermPane()
        pane.translatesAutoresizingMaskIntoConstraints = false
        let click = NSClickGestureRecognizer(target: self, action: #selector(paneClicked(_:)))
        pane.addGestureRecognizer(click)
        panes.append(pane)
        addSubview(pane)
        activeIndex = panes.count - 1
        relayout()
    }

    @objc func paneClicked(_ sender: NSClickGestureRecognizer) {
        guard let pane = sender.view as? TermPane,
              let idx = panes.firstIndex(where: { $0 === pane }) else { return }
        activeIndex = idx
        updateBorders()
    }

    func removeActivePane() {
        guard panes.count > 1 else { return }
        let pane = panes[activeIndex]
        pane.removeFromSuperview()
        panes.remove(at: activeIndex)
        activeIndex = max(0, activeIndex - 1)
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

// Intercept Cmd shortcuts before WebView can swallow them
func installKeyMonitor() {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.modifierFlags.contains(.command) {
            if let mainMenu = NSApp.mainMenu, mainMenu.performKeyEquivalent(with: event) {
                return nil // consumed
            }
        }
        return event
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [(window: NSWindow, split: SplitContainer)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        installKeyMonitor()
        openNewWindow()
    }

    func openNewWindow() {
        let split = SplitContainer(frame: .zero)
        split.translatesAutoresizingMaskIntoConstraints = false

        let win = AppWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "slyTerm"
        win.contentView?.addSubview(split)
        if let cv = win.contentView {
            NSLayoutConstraint.activate([
                split.topAnchor.constraint(equalTo: cv.topAnchor),
                split.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
                split.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            ])
        }

        // Offset from existing windows
        if let last = windows.last?.window {
            let origin = last.frame.origin
            win.setFrameOrigin(NSPoint(x: origin.x + 30, y: origin.y - 30))
        } else {
            win.center()
        }

        win.makeKeyAndOrderFront(nil)
        windows.append((window: win, split: split))
    }

    var activeSplit: SplitContainer? {
        if let keyWindow = NSApp.keyWindow {
            return windows.first(where: { $0.window === keyWindow })?.split
        }
        return windows.last?.split
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
        activeSplit?.addPane()
    }

    @objc func closeSplit() {
        guard let split = activeSplit,
              let entry = windows.first(where: { $0.split === split }) else { return }
        if split.panes.count <= 1 {
            entry.window.performClose(nil)
            windows.removeAll { $0.window === entry.window }
        } else {
            split.removeActivePane()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return windows.isEmpty
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
