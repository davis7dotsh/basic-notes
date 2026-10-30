import AppKit

/// Owns the floating panel: show/hide/focus, geometry (fixed default size, user-resizable, persisted), focus hand-back.
final class PanelController: NSObject, NSWindowDelegate {
    private(set) var panel: NotePanel
    let root: PanelRootView
    let strip: DragStrip
    private let prefs: Preferences
    private weak var content: NSView?
    /// App that was frontmost before we showed; focus goes back to it on hide.
    private var previousApp: NSRunningApplication?
    private var applyingFrame = false

    static let defaultSize = NSSize(width: 300, height: 700)
    static let minSize = NSSize(width: 300, height: 200)

    init(prefs: Preferences) {
        self.prefs = prefs
        panel = Self.makePanel()
        root = PanelRootView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        strip = DragStrip(frame: .zero)
        super.init()
        panel.delegate = self
        panel.contentView = root

        strip.frame = NSRect(x: 0, y: root.bounds.height - DragStrip.height, width: root.bounds.width, height: DragStrip.height)
        strip.autoresizingMask = [.width, .minYMargin]
        root.addSubview(strip)
        strip.onClose = { [weak self] in self?.onClose?() }
        strip.onAction = { [weak self] in self?.onHeaderAction?($0) }

        applyCaptureSetting()
        restoreGeometry()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Install the editor view below the strip.
    func setContent(_ view: NSView) {
        view.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: root.bounds.height - DragStrip.height)
        view.autoresizingMask = [.width, .height]
        root.addSubview(view, positioned: .below, relativeTo: strip)
        content = view
    }

    // MARK: Visibility

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    func show() {
        if !panel.isVisible {
            if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
            ensureOnScreen()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        if let content { panel.makeFirstResponder(content) }
        if automationMode, !panel.isReallyKey { forceKey(true) }
    }

    /// Automation mode: allow faking key status when the session can't grant it (see NotePanel.forceKey).
    var automationMode = false

    private func forceKey(_ on: Bool) {
        guard panel.forceKey != on else { return }
        panel.forceKey = on
        (NSApp as? NBMApplication)?.forcedKeyWindow = on ? panel : nil
        // WebKit recomputes its focus/active state from these notifications.
        NotificationCenter.default.post(name: on ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: panel)
        Log.debug("forced key \(on ? "on" : "off") (session can't make the panel key)")
    }

    func hide() {
        guard panel.isVisible else { return }
        forceKey(false)
        panel.orderOut(nil)
        // Non-activating panel: the previous app usually still owns activation. If we did get activated
        // (settings, clicks in other windows), hand activation back explicitly — unless another of our windows is up.
        let otherWindowsVisible = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.styleMask.contains(.titled) }
        guard NSApp.isActive, !otherWindowsVisible else { return }
        if let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        } else {
            NSApp.deactivate()
        }
    }

    // MARK: Strip

    /// Called when the panel becomes key (real or forced).
    var onBecameKey: (() -> Void)?
    /// Called for each key press the panel gets, before it's handled.
    var onKeyDown: (() -> Void)? { didSet { panel.onKeyDown = onKeyDown } }
    /// The header's close button (same as Esc / hide).
    var onClose: (() -> Void)?
    /// The header's icon buttons.
    var onHeaderAction: ((HeaderAction) -> Void)?

    func setStrip(content: String, pinned: Bool? = nil) {
        let title = NoteTitle.firstTitle(in: content)
        strip.update(title: title?.text ?? (content.isBlank ? "" : "Untitled"), titleLine: title?.line)
        if let pinned { strip.setPinned(pinned) }
    }

    func applyCaptureSetting() {
        let wanted: NSWindow.SharingType = prefs.hideFromCapture ? .none : .readOnly
        panel.sharingType = wanted
        // Once excluded from capture, a live window can't be made shareable again: move the content to a fresh panel.
        if panel.sharingType != wanted { replacePanel() }
    }

    private func replacePanel() {
        let old = panel
        let wasVisible = old.isVisible
        let frame = old.frame
        forceKey(false)
        old.delegate = nil
        old.contentView = NSView()
        let fresh = Self.makePanel()
        fresh.setFrame(frame, display: false)
        fresh.contentView = root
        fresh.delegate = self
        fresh.onKeyDown = onKeyDown
        panel = fresh
        old.orderOut(nil)
        old.close()
        if wasVisible { show() }
        Log.info("panel recreated (capture sharing re-enabled)")
    }

    private static func makePanel() -> NotePanel {
        let panel = NotePanel(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.minSize = minSize
        panel.title = "Basic Notes"
        return panel
    }

    // MARK: Geometry

    /// Automation: explicit resize (top-anchored), kept like a manual one.
    func resize(width: CGFloat?, height: CGFloat?) {
        let f = panel.frame
        let size = NSSize(width: width ?? f.width, height: height ?? f.height)
        setFrame(fitted(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height)))
        saveGeometry()
    }

    private func restoreGeometry() {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let g = prefs.panelGeometry
        let width = g.map { CGFloat($0.width) } ?? Self.defaultSize.width
        let height = g?.height.map { CGFloat($0) } ?? Self.defaultSize.height
        let top = g.map { CGFloat($0.top) } ?? (visible.maxY - visible.height * 0.12)
        let x = g.map { CGFloat($0.x) } ?? (visible.midX - width / 2)
        setFrame(fitted(NSRect(x: x, y: top - height, width: width, height: height)))  // not persisted
    }

    private func saveGeometry() {
        let f = panel.frame
        prefs.panelGeometry = PanelGeometry(x: f.minX, top: f.maxY, width: f.width, height: f.height)
    }

    /// `frame` within the visible area of the screen it's (mostly) on: at least the minimum size, at most the screen,
    /// moved (not shrunk) back inside. Off every screen (display unplugged): onto the main screen, near the top.
    private func fitted(_ frame: NSRect) -> NSRect {
        let grip = NSPoint(x: frame.midX, y: frame.maxY - DragStrip.height / 2)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(grip) }
        guard let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return frame }
        var f = frame
        f.size.width = min(max(f.width, Self.minSize.width), visible.width)
        f.size.height = min(max(f.height, Self.minSize.height), visible.height)
        if screen == nil {
            f.origin = NSPoint(x: visible.midX - f.width / 2, y: visible.maxY - visible.height * 0.12 - f.height)
        }
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    private func setFrame(_ frame: NSRect) {
        guard frame != panel.frame else { return }
        applyingFrame = true
        panel.setFrame(frame, display: true)
        applyingFrame = false
    }

    /// Pull the panel back inside its screen (display unplugged, resolution change, dragged half off).
    func ensureOnScreen() {
        let f = fitted(panel.frame)
        guard f != panel.frame else { return }
        setFrame(f)
        saveGeometry()
    }

    @objc private func screensChanged() { ensureOnScreen() }

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        saveGeometry()
        panel.invalidateShadow()
    }

    func windowDidMove(_ notification: Notification) {
        guard !applyingFrame else { return }
        saveGeometry()
    }

    func windowDidResize(_ notification: Notification) { panel.invalidateShadow() }

    func windowDidBecomeKey(_ notification: Notification) { onBecameKey?() }
}
