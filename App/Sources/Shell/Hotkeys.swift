import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
final class Hotkeys {
    static let shared = Hotkeys()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var bindings: [(KeyCombo, () -> Void)] = []
    private var handlerInstalled = false
    private var suspended = false
    private static let signature: OSType = 0x4E42_4D48  // 'NBMH'
    /// Combos from the last registration that won't fire: Carbon refused them or the system owns them
    /// (Spotlight, screenshots, Mission Control… — RegisterEventHotKey "succeeds" for those but never fires).
    private(set) var unavailable: Set<KeyCombo> = []
    var onAvailabilityChange: ((Set<KeyCombo>) -> Void)?

    /// Replace all registrations.
    func set(_ bindings: [(KeyCombo, () -> Void)]) {
        self.bindings = bindings
        if !suspended { registerAll() }
    }

    /// While recording a new shortcut in Settings, release our hotkeys so the recorder sees the keystroke.
    func suspend() { suspended = true; unregisterAll() }
    func resume() { suspended = false; registerAll() }

    private func registerAll() {
        unregisterAll()
        installHandler()
        var failed = Set<KeyCombo>()
        let system = Self.systemHotkeys()
        for (index, (combo, action)) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(combo.keyCode), combo.carbonModifiers, EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = action
            } else {
                failed.insert(combo)
                Log.warn("hotkey \(combo.display) unavailable (status \(status))")
            }
            if system.contains(SystemHotkey(code: combo.keyCode, modifiers: combo.carbonModifiers)) {
                failed.insert(combo)
                Log.warn("hotkey \(combo.display) is a system shortcut")
            }
        }
        if failed != unavailable {
            unavailable = failed
            onAvailabilityChange?(failed)
        }
    }

    private struct SystemHotkey: Hashable { var code: UInt16; var modifiers: UInt32 }

    /// Enabled system-wide shortcuts (System Settings › Keyboard › Shortcuts).
    private static func systemHotkeys() -> Set<SystemHotkey> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let relevant = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return Set(array.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint16Value,
                  let mods = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return nil }
            return SystemHotkey(code: code, modifiers: mods & relevant)
        })
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            MainActor.assumeIsolated { Hotkeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) { actions[id]?() }
}
