import AppKit
import Carbon.HIToolbox

/// US-ANSI key table shared by hotkey display/recording and the automation key synthesizer.
enum KeyCodes {
    struct Key {
        var code: UInt16
        var chars: String
        var shifted: String
        /// NSEvent function-key flags (arrows, F-keys, etc).
        var isFunction = false
    }

    private static let printable: [(UInt16, String, String)] = [
        (0, "a", "A"), (1, "s", "S"), (2, "d", "D"), (3, "f", "F"), (4, "h", "H"), (5, "g", "G"), (6, "z", "Z"),
        (7, "x", "X"), (8, "c", "C"), (9, "v", "V"), (11, "b", "B"), (12, "q", "Q"), (13, "w", "W"), (14, "e", "E"),
        (15, "r", "R"), (16, "y", "Y"), (17, "t", "T"), (18, "1", "!"), (19, "2", "@"), (20, "3", "#"), (21, "4", "$"),
        (22, "6", "^"), (23, "5", "%"), (24, "=", "+"), (25, "9", "("), (26, "7", "&"), (27, "-", "_"), (28, "8", "*"),
        (29, "0", ")"), (30, "]", "}"), (31, "o", "O"), (32, "u", "U"), (33, "[", "{"), (34, "i", "I"), (35, "p", "P"),
        (37, "l", "L"), (38, "j", "J"), (39, "'", "\""), (40, "k", "K"), (41, ";", ":"), (42, "\\", "|"), (43, ",", "<"),
        (44, "/", "?"), (45, "n", "N"), (46, "m", "M"), (47, ".", ">"), (50, "`", "~"), (49, " ", " "),
    ]

    private static func fn(_ scalar: Int) -> String { UnicodeScalar(UInt32(scalar)).map { String(Character($0)) } ?? "" }

    /// Named keys (lowercase names accepted by the automation server).
    static let named: [String: Key] = {
        var m: [String: Key] = [
            "return": Key(code: 36, chars: "\r", shifted: "\r"),
            "enter": Key(code: 36, chars: "\r", shifted: "\r"),
            "tab": Key(code: 48, chars: "\t", shifted: "\u{19}"),
            "space": Key(code: 49, chars: " ", shifted: " "),
            "backspace": Key(code: 51, chars: "\u{7f}", shifted: "\u{7f}"),
            "delete": Key(code: 51, chars: "\u{7f}", shifted: "\u{7f}"),
            "esc": Key(code: 53, chars: "\u{1b}", shifted: "\u{1b}"),
            "escape": Key(code: 53, chars: "\u{1b}", shifted: "\u{1b}"),
            "forwarddelete": Key(code: 117, chars: fn(NSDeleteFunctionKey), shifted: fn(NSDeleteFunctionKey), isFunction: true),
            "left": Key(code: 123, chars: fn(NSLeftArrowFunctionKey), shifted: fn(NSLeftArrowFunctionKey), isFunction: true),
            "right": Key(code: 124, chars: fn(NSRightArrowFunctionKey), shifted: fn(NSRightArrowFunctionKey), isFunction: true),
            "down": Key(code: 125, chars: fn(NSDownArrowFunctionKey), shifted: fn(NSDownArrowFunctionKey), isFunction: true),
            "up": Key(code: 126, chars: fn(NSUpArrowFunctionKey), shifted: fn(NSUpArrowFunctionKey), isFunction: true),
            "home": Key(code: 115, chars: fn(NSHomeFunctionKey), shifted: fn(NSHomeFunctionKey), isFunction: true),
            "end": Key(code: 119, chars: fn(NSEndFunctionKey), shifted: fn(NSEndFunctionKey), isFunction: true),
            "pageup": Key(code: 116, chars: fn(NSPageUpFunctionKey), shifted: fn(NSPageUpFunctionKey), isFunction: true),
            "pagedown": Key(code: 121, chars: fn(NSPageDownFunctionKey), shifted: fn(NSPageDownFunctionKey), isFunction: true),
        ]
        let fCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fCodes.enumerated() {
            let s = fn(NSF1FunctionKey + i)
            m["f\(i + 1)"] = Key(code: code, chars: s, shifted: s, isFunction: true)
        }
        for (code, c, s) in printable { m[c] = Key(code: code, chars: c, shifted: s) }
        return m
    }()

    /// Typed character -> (key, needsShift). nil for characters not on a US keyboard.
    static func forCharacter(_ ch: Character) -> (Key, Bool)? {
        if ch == "\n" || ch == "\r" { return (named["return"]!, false) }
        if ch == "\t" { return (named["tab"]!, false) }
        let s = String(ch)
        for (code, c, sh) in printable {
            if c == s { return (Key(code: code, chars: c, shifted: sh), false) }
            if sh == s { return (Key(code: code, chars: c, shifted: sh), true) }
        }
        return nil
    }

    /// Display label for a key code, e.g. "N", "↩", "F5".
    static func label(for code: UInt16) -> String {
        switch code {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: break
        }
        if let (name, _) = named.first(where: { $0.value.code == code && $0.key.hasPrefix("f") && $0.key.count <= 3 && $0.value.isFunction }) {
            return name.uppercased()
        }
        if let (_, c, _) = printable.first(where: { $0.0 == code }) { return c.uppercased() }
        return "Key\(code)"
    }

    /// The character to use for an NSMenuItem keyEquivalent ("" if unrepresentable).
    static func menuEquivalent(for code: UInt16) -> String {
        switch code {
        case 36: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 51: return "\u{8}"
        case 53: return "\u{1b}"
        default: break
        }
        if let k = named.values.first(where: { $0.code == code }), k.isFunction { return k.chars }
        return printable.first(where: { $0.0 == code })?.1 ?? ""
    }
}

/// A global hotkey: virtual key code + Cocoa modifier flags.
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift]) }

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = flags.intersection([.command, .option, .control, .shift]).rawValue
    }

    /// Hotkeys need at least one of ⌘ ⌥ ⌃ (shift alone would eat typing).
    var isValidHotkey: Bool { !flags.intersection([.command, .option, .control]).isEmpty }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + KeyCodes.label(for: keyCode)
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static let defaultToggle = KeyCombo(keyCode: 45, flags: [.control, .option])  // ⌃⌥N
    static let defaultNew = KeyCombo(keyCode: 45, flags: [.control, .option, .shift])  // ⌃⌥⇧N
}
