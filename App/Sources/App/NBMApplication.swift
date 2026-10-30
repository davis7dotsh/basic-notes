import AppKit

/// NSApplication subclass that makes ⌘-shortcuts work in our non-activating panel.
/// When the panel is key but the app isn't active (the normal state for a non-activating panel), AppKit skips
/// key-equivalent processing, so ⌘C/⌘V/⌘X would never reach the menu. We route them like an active app would.
/// Automation: `forcedKeyWindow` also routes input to the panel when the session can't grant key status
/// (screen locked / display asleep).
final class NBMApplication: NSApplication {
    weak var forcedKeyWindow: NSWindow?

    override func sendEvent(_ event: NSEvent) {
        guard [.keyDown, .keyUp, .flagsChanged].contains(event.type) else { return super.sendEvent(event) }
        let forced = forcedKeyWindow.flatMap { $0.isVisible ? $0 : nil }
        guard let window = forced ?? (isActive ? nil : keyWindow as? NotePanel) else { return super.sendEvent(event) }
        if event.type == .keyDown, event.modifierFlags.contains(.command) {
            if window.performKeyEquivalent(with: event) { return }
            if mainMenu?.performKeyEquivalent(with: event) == true { return }
        }
        if forced != nil { window.sendEvent(event) } else { super.sendEvent(event) }
    }
}
