import AppKit
import ObjectiveC
import WebKit

/// WKWebView with native image paste: ⌘V with an image (or image files) on the pasteboard saves to assets/
/// and inserts a Markdown link instead of letting WebKit paste a filename/icon.
final class EditorWebView: WKWebView {
    var onPasteImages: (([PastedImage]) -> Void)?
    /// Text pasted natively (inline, replacing the selection): Finder-copied non-image files (inserted as paths).
    var onPasteText: ((String) -> Void)?
    /// Our own ⌘⇧C copy: its original Markdown (not the base64 export), plus where its images live.
    var onPasteOwnCopy: ((ClipboardExport.OwnCopy) -> Void)?
    /// The ⌘P search field is open (reported by the page): pastes go to its input, never into the note behind it.
    var searchOpen = false
    /// Text for the search input (our own copy, reduced to its first readable line).
    var onPasteSearchText: ((String) -> Void)?

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if searchOpen {
            // Our own copy's plain-text flavor is the self-contained export (megabytes of base64): use its first line.
            if let copy = ClipboardExport.ownCopy(pb) {
                let line = copy.markdown.split(whereSeparator: \.isNewline).lazy.compactMap { NoteTitle.text(ofLine: $0) }.first { !$0.isEmpty }
                if let line, let onPasteSearchText { onPasteSearchText(String(line.prefix(200))) } else { NSSound.beep() }
                return
            }
            // Images and files have no search-field form.
            if ImagePaste.images(from: pb)?.isEmpty == false || ImagePaste.nonImageFilePaths(from: pb) != nil { return NSSound.beep() }
            return callSuper(#selector(paste(_:)), sender)
        }
        if let onPasteOwnCopy, let copy = ClipboardExport.ownCopy(pb) {
            onPasteOwnCopy(copy)
            return
        }
        if let onPasteImages, let images = ImagePaste.images(from: pb), !images.isEmpty {
            onPasteImages(images)
            return
        }
        if let onPasteText, let paths = ImagePaste.nonImageFilePaths(from: pb) {
            onPasteText(paths.joined(separator: "\n"))
            return
        }
        callSuper(#selector(paste(_:)), sender)
    }

    /// Automation: WebKit's own paste (no native image/text interception) — to measure what pages receive.
    func pasteThroughWebKit() { callSuper(#selector(paste(_:)), nil) }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), ImagePaste.mightHaveImage(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// A click on the (non-key) floating panel should both focus it and act (checkboxes, cursor placement).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ⌘= / ⌘- zoom levels (pageZoom).
    static let zoomLevels: [CGFloat] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    /// The level one step (+1 / -1) from `zoom`; step 0 resets to 100%.
    static func zoom(_ zoom: CGFloat, step: Int) -> CGFloat {
        switch step {
        case 0: 1
        case 1...: zoomLevels.first { $0 > zoom + 0.01 } ?? 2
        default: zoomLevels.last { $0 < zoom - 0.01 } ?? 0.8
        }
    }

    /// WebKit implements the edit actions but doesn't expose them to Swift; call WKWebView's IMP directly.
    private func callSuper(_ selector: Selector, _ sender: Any?) {
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let imp = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        imp(self, selector, sender as AnyObject?)
    }
}
