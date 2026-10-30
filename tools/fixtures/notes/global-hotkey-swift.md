# global hotkey in swift

carbon API is ancient but still the only thing that works w/o accessibility perms

```swift
import Carbon.HIToolbox

var hotKeyRef: EventHotKeyRef?
let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F5445), id: 1) // 'NOTE'

var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
    NotificationCenter.default.post(name: .toggleNotes, object: nil)
    return noErr
}, 1, &spec, nil, nil)

RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
```

- ⌥Space conflicts w/ raycast default for some ppl, make it configurable
- or just use the KeyboardShortcuts package by sindresorhus, it wraps this
- `UnregisterEventHotKey(hotKeyRef)` on change
