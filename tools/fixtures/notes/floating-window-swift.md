# floating window w/ swift

for the notes app — want a raycast-style window that floats over everything incl fullscreen apps and doesn't steal focus from the current app

```swift
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        // close on click-outside, like spotlight
        orderOut(nil)
    }
}
```

notes
- `.nonactivatingPanel` must be in the init styleMask, setting it after doesn't fully work (known bug)
- need `canBecomeKey` true or text fields won't take input
- host SwiftUI w/ `NSHostingView(rootView:)` as contentView
- LSUIElement = YES in Info.plist so no dock icon
- remember frame: `setFrameAutosaveName("notes-window")`
