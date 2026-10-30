import AppKit
import UniformTypeIdentifiers

/// Image content found on a pasteboard, ready to be saved into `assets/`.
struct PastedImage {
    var data: Data
    var ext: String
}

enum ImagePaste {
    /// Images to paste, or nil when this is a regular (text) paste.
    /// Image files (Finder copy) keep their original bytes/format; raw image data becomes PNG unless it's jpeg/gif/heic.
    static func images(from pb: NSPasteboard) -> [PastedImage]? {
        // Our own ⌘⇧C copy carries its images as file URLs too; pasting it back is a text paste.
        if pb.availableType(from: [ClipboardExport.marker]) != nil { return nil }
        let fileURLs = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            let images = fileURLs.compactMap { url -> PastedImage? in
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let data = try? Data(contentsOf: url) else { return nil }
                return PastedImage(data: data, ext: url.pathExtension.lowercased())
            }
            return images.isEmpty ? nil : images
        }
        // Real text wins over an accompanying image rendition (e.g. spreadsheet cells), but a bare URL doesn't.
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           !(text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("file://")) || text.contains(where: \.isWhitespace) {
            return nil
        }
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"), (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
            (NSPasteboard.PasteboardType(UTType.gif.identifier), "gif"), (NSPasteboard.PasteboardType(UTType.heic.identifier), "heic"),
        ]
        for (type, ext) in candidates {
            if let data = pb.data(forType: type), !data.isEmpty { return [PastedImage(data: data, ext: ext)] }
        }
        if let tiff = pb.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [PastedImage(data: png, ext: "png")]
        }
        return nil
    }

    /// Finder-copied files that aren't images (and no text on the pasteboard): their paths, to insert as text.
    static func nonImageFilePaths(from pb: NSPasteboard) -> [String]? {
        guard pb.availableType(from: [ClipboardExport.marker]) == nil else { return nil }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return nil }
        return urls.map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }

    /// Cheap type-only check (menu validation).
    static func mightHaveImage(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) || pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)]) != nil
    }

    /// File extension for a MIME type / filename coming from JS drag-drop.
    static func ext(mime: String, filename: String?) -> String {
        if let filename, let ext = filename.split(separator: ".").last.map(String.init), filename.contains("."),
           UTType(filenameExtension: ext)?.conforms(to: .image) == true {
            return ext.lowercased()
        }
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/svg+xml": return "svg"
        case "image/tiff": return "tiff"
        default: return UTType(mimeType: mime)?.preferredFilenameExtension ?? "png"
        }
    }
}
