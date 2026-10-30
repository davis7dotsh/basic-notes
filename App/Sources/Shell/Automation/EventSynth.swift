import AppKit

/// Synthesizes real NSEvents (keyboard + mouse) and dispatches them through NSApp.sendEvent, so key equivalents,
/// the main menu (⌘V paste path) and WKWebView text input behave like real input.
enum EventSynth {
    struct Stroke {
        var key: KeyCodes.Key
        var flags: NSEvent.ModifierFlags
    }

    /// "cmd+shift+c", "esc", "ctrl+d", "A", "?", "shift+tab", "plus".
    static func parse(_ combo: String) -> Result<Stroke, BridgeError> {
        let raw = combo.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return .failure(BridgeError("empty key")) }
        var tokens = raw.count > 1 && raw.hasSuffix("++") ? raw.dropLast(2).split(separator: "+").map(String.init) + ["+"]
            : raw == "+" ? ["+"] : raw.split(separator: "+").map(String.init)
        guard let keyToken = tokens.popLast() else { return .failure(BridgeError("bad combo \(combo)")) }
        var flags: NSEvent.ModifierFlags = []
        for token in tokens {
            switch token.lowercased() {
            case "cmd", "command", "meta", "⌘", "mod": flags.insert(.command)
            case "shift", "⇧": flags.insert(.shift)
            case "alt", "opt", "option", "⌥": flags.insert(.option)
            case "ctrl", "control", "⌃": flags.insert(.control)
            case "fn": flags.insert(.function)
            default: return .failure(BridgeError("unknown modifier \(token) in \(combo)"))
            }
        }
        let name = keyToken.lowercased()
        if let key = KeyCodes.named[name == "plus" ? "=" : name], keyToken.count > 1 || keyToken == name || keyToken == " " {
            if name == "plus" { flags.insert(.shift) }
            return .success(Stroke(key: key, flags: flags))
        }
        if keyToken.count == 1, let ch = keyToken.first, let (key, shift) = KeyCodes.forCharacter(ch) {
            return .success(Stroke(key: key, flags: shift ? flags.union(.shift) : flags))
        }
        return .failure(BridgeError("unknown key \(keyToken)"))
    }

    static func stroke(for ch: Character) -> Stroke? {
        KeyCodes.forCharacter(ch).map { Stroke(key: $0.0, flags: $0.1 ? .shift : []) }
    }

    static func send(_ stroke: Stroke, to window: NSWindow) {
        let shift = stroke.flags.contains(.shift)
        let ignoring = shift ? stroke.key.shifted : stroke.key.chars
        var chars = ignoring
        if stroke.flags.contains(.control), let scalar = stroke.key.chars.unicodeScalars.first, scalar.properties.isAlphabetic,
           let control = UnicodeScalar(scalar.value & 0x1F) {
            chars = String(Character(control))
        }
        var flags = stroke.flags
        if stroke.key.isFunction {
            flags.insert(.function)
            if (123...126).contains(stroke.key.code) { flags.insert(.numericPad) }
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: ignoring,
                isARepeat: false, keyCode: stroke.key.code)
            else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// Click at a point in the window's content (top-left origin, points).
    static func click(x: CGFloat, y: CGFloat, right: Bool, clickCount: Int, in window: NSWindow) -> Result<Void, BridgeError> {
        guard let content = window.contentView else { return .failure(BridgeError("no content view")) }
        let location = NSPoint(x: x, y: content.bounds.height - y)
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for count in 1...max(1, clickCount) {
            for type in [down, up] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == down ? 1 : 0)
                else { return .failure(BridgeError("could not create mouse event")) }
                window.sendEvent(event)
            }
        }
        return .success(())
    }
}
