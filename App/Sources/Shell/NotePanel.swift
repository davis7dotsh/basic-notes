import AppKit

/// Borderless, non-activating floating panel that can still become key (typing works without stealing activation).
final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Automation only: when the window server won't grant key status (screen locked / display asleep),
    /// pretend to be key so WebKit treats the page as focused and synthesized input is routed here.
    var forceKey = false
    override var isKeyWindow: Bool { super.isKeyWindow || (forceKey && isVisible) }
    var isReallyKey: Bool { super.isKeyWindow }
    override var canBecomeMain: Bool { true }
    /// Each key press for the panel, before it's handled (the coordinator refreshes vim's clipboard mirror first).
    var onKeyDown: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown { onKeyDown?() }
        super.sendEvent(event)
    }

    /// Esc is handled by the editor (it sends `hide`); never let AppKit close/beep on its own.
    override func cancelOperation(_ sender: Any?) {}

    /// Fallback for standard edit shortcuts when the main menu isn't consulted (non-activated app).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let action: Selector? = switch (flags, key) {
        case ([.command], "x"): #selector(NSText.cut(_:))
        case ([.command], "c"): #selector(NSText.copy(_:))
        case ([.command], "v"): #selector(NSText.paste(_:))
        case ([.command], "a"): #selector(NSText.selectAll(_:))
        case ([.command], "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        default: nil
        }
        guard let action else { return false }
        return firstResponder?.tryToPerform(action, with: self) ?? false
    }
}

/// One frosted writing surface behind the native header and transparent editor.
final class PanelRootView: NSView {
    static let radius: CGFloat = 19

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        let backdrop = NSVisualEffectView(frame: bounds)
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        for view in [backdrop, MoonstoneCanvas(frame: bounds)] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.panelBorder.cgColor }
    }
}

/// The header transmits more of the desktop than the writing area below it.
final class MoonstoneCanvas: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(redraw), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func redraw() { needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Self.paint(in: bounds, appearance: effectiveAppearance, opaque: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }

    static func paint(in rect: NSRect, appearance: NSAppearance, opaque: Bool) {
        guard rect.height > 0 else { return }
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let body = dark
            ? NSColor(srgbRed: 25/255, green: 27/255, blue: 32/255, alpha: opaque ? 1 : 0.81)
            : NSColor(srgbRed: 244/255, green: 245/255, blue: 249/255, alpha: opaque ? 1 : 0.81)
        let header = dark
            ? NSColor(srgbRed: 45/255, green: 48/255, blue: 56/255, alpha: opaque ? 1 : 0.53)
            : NSColor(srgbRed: 220/255, green: 227/255, blue: 239/255, alpha: opaque ? 1 : 0.53)
        let headerStart = max(0.52, 1 - 100 / rect.height)
        NSGradient(colors: [body, body, header], atLocations: [0, headerStart, 1], colorSpace: .sRGB)?
            .draw(in: rect, angle: 90)
    }
}

/// A layer filled with a (dynamic) color.
final class FillView: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }
}

/// The native header above the web view, Raycast-style: traffic lights, the note title (+ pin) centered, and a pill of
/// icon buttons (actions, copy, new). Everything that isn't a button drags the panel.
final class DragStrip: NSView {
    static let height: CGFloat = 46
    var onClose: (() -> Void)?
    var onAction: ((HeaderAction) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    private let lights = TrafficLights()
    private(set) var title = ""
    private var titleLine: Int?
    private var visibleHeadingEndLine = 0
    private var titleFaded = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        lights.close.target = self
        lights.close.action = #selector(closeClicked)

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?.withSymbolConfiguration(config)
        pin.contentTintColor = .tertiaryLabelColor
        pin.isHidden = true
        let titleStack = NSStackView(views: [pin, label])
        titleStack.orientation = .horizontal
        titleStack.spacing = 4

        let buttons: [(String, String, HeaderAction)] = [
            ("command", "Actions ⌘K", .actions),
            ("square.on.square", "Copy Note ⌘⇧C", .copyNote),
            ("plus", "New Note ⌘N", .newNote),
        ]
        let buttonStack = NSStackView(views: buttons.map { symbol, tip, action in
            HeaderButton(symbol: symbol, toolTip: tip) { [weak self] in self?.onAction?(action) }
        })
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 0
        buttonStack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        let pill = Self.pill(around: buttonStack)

        for view in [lights, titleStack, pill] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let centered = titleStack.centerXAnchor.constraint(equalTo: centerXAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            lights.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            lights.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 28),
            pill.widthAnchor.constraint(equalToConstant: 96),
            centered,
            titleStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: lights.trailingAnchor, constant: 8),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -8),
        ])
        update(title: "", titleLine: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Rounded glass capsule (a light fill before macOS 26).
    private static func pill(around content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 14
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            #endif
            glass.contentView = content
            return glass
        }
        let pill = FillView(color: .pillFill)
        pill.layer?.cornerRadius = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            content.topAnchor.constraint(equalTo: pill.topAnchor),
            content.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
        return pill
    }

    func setPinned(_ pinned: Bool) { pin.isHidden = !pinned }

    func update(title: String, titleLine: Int?) {
        self.title = title
        self.titleLine = titleLine
        label.stringValue = title.isEmpty ? "Untitled" : title
        updateTitleVisibility()
    }

    func resetHeadingVisibility() {
        visibleHeadingEndLine = 0
        titleFaded = false
        label.alphaValue = 1
    }

    func setVisibleHeading(through endLine: Int) {
        visibleHeadingEndLine = endLine
        updateTitleVisibility()
    }

    private func updateTitleVisibility() {
        // An empty or image-only heading can precede the actual title elsewhere in the note.
        let fade = titleLine.map { $0 <= visibleHeadingEndLine } ?? false
        guard fade != titleFaded else { return }
        titleFaded = fade
        let alpha: CGFloat = fade ? 0 : 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            label.animator().alphaValue = alpha
        }
    }

    var isPinned: Bool { !pin.isHidden }

    @objc private func closeClicked() { onClose?() }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Only real presses start a drag loop (synthesized automation clicks must not block).
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        window?.performDrag(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Buttons get their clicks; the title, pill background and gaps drag.
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }
}

/// The standard close / minimize / zoom buttons. Close hides the panel; the other two are shown disabled (like Raycast).
/// Answering `_mouseInGroup:` is how AppKit's own titlebar shows the ×/–/+ glyphs while the pointer is over the group.
final class TrafficLights: NSView {
    let close: NSButton
    private let buttons: [NSButton]
    private var mouseInside = false

    init() {
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { NSWindow.standardWindowButton($0, for: mask) }
        close = buttons.first ?? NSButton()
        super.init(frame: .zero)
        var x: CGFloat = 0
        for (i, button) in buttons.enumerated() {
            button.isEnabled = i == 0
            button.setFrameOrigin(NSPoint(x: x, y: 0))
            addSubview(button)
            x += button.frame.width + 6
        }
        let size = NSSize(width: max(0, x - 6), height: buttons.map(\.frame.height).max() ?? 0)
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc func _mouseInGroup(_ button: NSButton) -> Bool { mouseInside }

    override func mouseEntered(with event: NSEvent) { setMouseInside(true) }
    override func mouseExited(with event: NSEvent) { setMouseInside(false) }

    private func setMouseInside(_ inside: Bool) {
        mouseInside = inside
        buttons.forEach { $0.needsDisplay = true }
    }
}

/// Borderless SF Symbol button for the header pill; acts on the first click even while the panel isn't key.
final class HeaderButton: NSButton {
    private let handler: () -> Void

    init(symbol: String, toolTip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .labelColor
        refusesFirstResponder = true  // the editor keeps focus (and its keys) after a click
        self.toolTip = toolTip
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func clicked() { handler() }
}

extension NSColor {
    static let pillFill = NSColor(name: "pillFill") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(white: 0, alpha: 0.04)
    }

    static let panelBorder = NSColor(name: "panelBorder") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.10)
    }
}
