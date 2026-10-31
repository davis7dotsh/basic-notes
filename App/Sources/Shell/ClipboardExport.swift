import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// ⌘⇧C: the whole note as self-contained Markdown (images → data URIs) + HTML with embedded images, in one pasteboard
/// write. A note with images also gets a PNG of the whole rendered note as a second item (`snapshot`), so apps that take
/// only an image (chat apps) get all of it; if that render fails, each image (local file, or already a
/// `data:image/…;base64,` URI) is added as its own item carrying the image data (original type) instead. Not
/// file URLs: WebKit (Safari pages, e.g. Google Docs) hides the text/HTML whenever file URLs are on the pasteboard.
enum ClipboardExport {
    /// Image bytes for an image-data pasteboard item.
    nonisolated struct Attachment: Equatable, Sendable {
        var data: Data
        var type: UTType
    }

    struct Output {
        var markdown: String
        var html: String
        /// The note as written (relative image paths) — what pasting our own copy back into the editor inserts.
        var original: String
        var inlinedImages: Int
        /// Every image in the note (deduplicated by bytes, in order of first use) — attached as image-data items.
        var attachments: [Attachment]
        /// Parser image refs into `original`, and the folder its relative paths resolve in (for pasting elsewhere).
        var images: [ImageRef]
        var folder: URL?
        /// PNG of the whole rendered note (`NoteSnapshot`): written instead of the separate image items when set.
        var snapshot: Data? = nil
    }

    /// Our own copy as read back from the pasteboard.
    nonisolated struct OwnCopy: Sendable {
        /// The note's original Markdown (relative image paths).
        var markdown: String
        /// Notes folder the copy came from (nil: unknown — older copy).
        var folder: URL?
        /// Image destination ranges into `markdown` (empty when unknown).
        var images: [ImageRef]
        /// The self-contained export (images as data URIs) written next to it — bytes for images whose file is gone.
        var exported: String?
    }

    /// Marks our own note copies; its data is the original Markdown (pasting it back must not write base64 into a note).
    static let marker = NSPasteboard.PasteboardType("sh.davis7.basicnotes.note")
    /// Next to `marker`: JSON `Source` — where the copy's relative image paths live, so a paste into another folder can
    /// bring the images along.
    static let sourceType = NSPasteboard.PasteboardType("sh.davis7.basicnotes.source")

    private struct Source: Codable {
        var folder: String
        var images: [ImageRef]
    }

    /// `images` are the parser's real image nodes (never code, never escaped); only those destinations are rewritten
    /// and attached. `resolve` maps a relative path ("assets/x.png") to a file inside the notes folder (nil if it escapes).
    static func build(markdown: String, html: String, images: [ImageRef], folder: URL? = nil, resolve: (String) -> URL?) -> Output {
        var cache: [String: (uri: String, attachment: Attachment)?] = [:]
        var count = 0
        // A local file that really is an image (`isImage`): its data URI + attachment. Anything else (missing, not an
        // image, undecodable) is nil — its reference stays as written in the text/HTML and nothing is attached.
        func image(_ src: String) -> (uri: String, attachment: Attachment)? {
            guard let path = localPath(src) else { return nil }
            if let hit = cache[path] { return hit }
            let hit = resolve(path).flatMap { file -> (uri: String, attachment: Attachment)? in
                guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
                      let data = try? Data(contentsOf: file), isImage(data, type: type) else { return nil }
                return ("data:\(SchemeHandler.mimeType(file.pathExtension).split(separator: ";")[0]);base64,\(data.base64EncodedString())",
                        Attachment(data: data, type: type))
            }
            cache[path] = .some(hit)
            return hit
        }

        // Markdown: replace exactly the destination ranges (UTF-16), last first so earlier offsets stay valid.
        let md = NSMutableString(string: markdown)
        var found: [(order: Int, attachment: Attachment)] = []
        var floor = md.length
        for ref in images.sorted(by: { $0.from > $1.from }) {
            guard ref.from >= 0, ref.from <= ref.to, ref.to <= floor else { continue }
            if let embedded = dataURIImage(ref.src) {
                found.append((ref.order, embedded))
                floor = ref.from
                continue
            }
            guard let hit = image(ref.src) else { continue }
            md.replaceCharacters(in: NSRange(location: ref.from, length: ref.to - ref.from), with: hit.uri)
            floor = ref.from
            count += 1
            found.append((ref.order, hit.attachment))
        }
        // Order of first use in the document (a reference image counts where it's used, not where it's defined), each
        // image once.
        var attachments: [Attachment] = []
        for (_, a) in found.sorted(by: { $0.order < $1.order }) where !attachments.contains(a) { attachments.append(a) }

        // <img ... src="..."> / src='...' (code in the HTML is already entity-escaped, so this only hits real images)
        let body = replace(in: html, regex: imgTag) { groups in
            let src = groups[2].isEmpty ? groups[3] : groups[2]
            guard let hit = image(decodeEntities(src)) else { return nil }
            return groups[1] + "\"" + hit.uri + "\""
        }
        let doc = html.range(of: "<html", options: .caseInsensitive) != nil
            ? body
            : "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
        return Output(markdown: md as String, html: doc, original: markdown, inlinedImages: count, attachments: attachments,
                      images: images, folder: folder)
    }

    /// `data:image/<type>[;…];base64,<data>` → its decoded bytes and image type, else nil. NSString/Data operations only:
    /// a copied note's URIs run to megabytes, and per-Character Swift string work on them takes seconds.
    nonisolated static func dataURIImage(_ src: String) -> Attachment? {
        let ns = src as NSString
        let comma = ns.range(of: ",", options: .literal, range: NSRange(location: 0, length: min(ns.length, 256)))
        guard comma.location != NSNotFound else { return nil }
        let header = ns.substring(to: comma.location).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard header.hasPrefix("data:image/") else { return nil }
        let params = header.dropFirst(5).split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = params.first, params.contains("base64") else { return nil }
        let mime = first == "image/jpg" ? "image/jpeg" : first
        guard let type = UTType(mimeType: mime), type.conforms(to: .image) else { return nil }
        var payload = ns.substring(from: comma.location + 1) as NSString
        if payload.range(of: "%", options: .literal).location != NSNotFound, let decoded = payload.removingPercentEncoding {
            payload = decoded as NSString
        }
        guard let ascii = payload.data(using: String.Encoding.ascii.rawValue),
              let data = Data(base64Encoded: ascii, options: .ignoreUnknownCharacters), isImage(data, type: type) else { return nil }
        return Attachment(data: data, type: type)
    }

    /// Largest image file a paste brings along.
    nonisolated static let maxImageBytes = 50 * 1024 * 1024

    /// Bytes that really are an image of `type` (not just a plausible extension or MIME type): ImageIO decodes them to at
    /// least its first frame (a truncated/corrupt file with a valid header doesn't), or for SVG (which ImageIO doesn't
    /// read) they're XML with an `<svg>` root.
    nonisolated static func isImage(_ data: Data, type: UTType) -> Bool {
        guard !data.isEmpty, data.count <= maxImageBytes else { return false }
        if type.conforms(to: .svg) { return SVGRoot.isSVG(data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func write(_ output: Output, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(output.markdown, forType: .string)  // public.utf8-plain-text
        item.setString(output.html, forType: .html)  // public.html
        item.setData(Data(output.original.utf8), forType: marker)
        if let folder = output.folder, let json = try? JSONEncoder().encode(Source(folder: folder.path, images: output.images)) {
            item.setData(json, forType: sourceType)
        }
        // Item 0 = the note; then the snapshot (public.png), else one item per image with its bytes under its own type
        // (public.png, public.jpeg…).
        let attachments = output.snapshot.map { [Attachment(data: $0, type: .png)] } ?? output.attachments
        let images = attachments.map { a -> NSPasteboardItem in
            let image = NSPasteboardItem()
            image.setData(a.data, forType: NSPasteboard.PasteboardType(a.type.identifier))
            return image
        }
        pasteboard.writeObjects([item] + images)
    }

    /// A single image from the editor's context menu. Only image bytes go on the clipboard, so pasting into the note
    /// or another app inserts the picture. Resolve local files through the same folder boundary as the renderer.
    static func copyImage(_ src: String, folder: URL, to pasteboard: NSPasteboard = .general) async -> Result<Void, BridgeError> {
        let data: Data
        if let embedded = dataURIImage(src) {
            data = embedded.data
        } else if let path = localPath(src), let file = NoteStore.resolve(relativePath: path, in: folder),
                  let stat = NoteRegistry.fileStat(file.path), stat.isFile, stat.size <= Int64(maxImageBytes),
                  let bytes = try? Data(contentsOf: file) {
            data = bytes
        } else if let url = URL(string: src), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) {
            do {
                let (bytes, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    return .failure(BridgeError("couldn’t load image"))
                }
                data = bytes
            } catch {
                return .failure(BridgeError("couldn’t load image: \(error.localizedDescription)"))
            }
        } else {
            return .failure(BridgeError("image is unavailable"))
        }
        guard !data.isEmpty, data.count <= maxImageBytes, let image = NSImage(data: data),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return .failure(BridgeError("couldn’t decode image"))
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return .failure(BridgeError("couldn’t write image to clipboard")) }
        return .success(())
    }

    /// Our own copy on the pasteboard (original Markdown + where it came from), else nil.
    static func ownCopy(_ pasteboard: NSPasteboard) -> OwnCopy? {
        guard pasteboard.availableType(from: [marker]) != nil else { return nil }
        if let data = pasteboard.data(forType: marker), !data.isEmpty, let text = String(data: data, encoding: .utf8) {
            let source = pasteboard.data(forType: sourceType).flatMap { try? JSONDecoder().decode(Source.self, from: $0) }
            return OwnCopy(markdown: text, folder: source.map { URL(fileURLWithPath: $0.folder, isDirectory: true) }, images: source?.images ?? [],
                           exported: pasteboard.string(forType: .string))
        }
        // Older copies carried an empty marker.
        return pasteboard.string(forType: .string).map { OwnCopy(markdown: $0, folder: nil, images: [], exported: nil) }
    }

    /// Why pasting our copy failed (nothing was inserted): `message` for the log, `user` for the toast.
    nonisolated struct TransferError: Error {
        var message: String
        var user = "Couldn’t paste — images can’t be saved to the notes folder"
    }

    /// Pasting our copy back (any notes folder, including the one it came from): images come from the copy itself — the
    /// self-contained export written next to it at copy time — never from whatever the source files are now, so a
    /// source asset deleted, replaced or moved since the copy doesn't change what pastes. A reference whose destination
    /// already holds those exact bytes is left as written; otherwise the bytes go into `destination/assets/` (reusing a
    /// file with identical bytes under any name; a name taken by different bytes gets a new unique name) and the
    /// reference is rewritten. Only real images (`isImage`, ≤ `maxImageBytes`) are written — the pasteboard can be written
    /// by any app. An image the copy carries no bytes for (older copy, file missing or undecodable at copy time) falls back
    /// to the source folder's file if that is a real image, else its reference is kept (it was already broken at copy
    /// time). Fails (insert nothing) when bytes the copy did carry can't be preserved — not an image of their type, or
    /// can't be written — rather than inserting a reference that doesn't resolve or resolves to a different file. `written`: new files. Runs off the main thread (megabytes of
    /// base64 and file reads); `warn` gets log lines.
    nonisolated static func transferAssets(_ copy: OwnCopy, to destination: URL, warn: @Sendable (String) -> Void)
        -> Result<(markdown: String, written: [URL]), TransferError> {
        guard NoteRegistry.isDirectory(destination.path) else { return .failure(TransferError(message: "notes folder is missing")) }
        let fm = FileManager.default
        let assets = destination.appendingPathComponent("assets", isDirectory: true)
        let embedded = copy.exported.map { exportedImages(original: copy.markdown, exported: $0, images: copy.images) } ?? [:]
        var placed: [String: (file: URL, rel: String)] = [:]  // bytes key → where they went
        var existing: [Int: [URL]]?  // assets/ files by size, for reuse by content
        var written: [URL] = []

        enum Placed { case placed(file: URL, rel: String), failed(TransferError) }

        func sameBytes(_ data: Data) -> URL? {
            if existing == nil {
                let names = (try? fm.contentsOfDirectory(atPath: assets.path)) ?? []
                existing = Dictionary(grouping: names.filter { !$0.hasPrefix(".") }.map { assets.appendingPathComponent($0) }
                    .compactMap { url in NoteRegistry.fileStat(url.path).flatMap { $0.isFile ? (Int($0.size), url) : nil } }, by: \.0)
                    .mapValues { $0.map(\.1) }
            }
            return existing?[data.count]?.first { fm.contents(atPath: $0.path) == data }
        }
        func validImage(_ data: Data, name: String) -> Bool {
            guard let type = UTType(filenameExtension: (name as NSString).pathExtension), type.conforms(to: .image) else { return false }
            return isImage(data, type: type)
        }
        func place(_ data: Data, name: String, key: String) -> Placed {
            if let hit = placed[key] { return .placed(file: hit.file, rel: hit.rel) }
            let ext = (name as NSString).pathExtension
            guard validImage(data, name: name) else {
                return .failed(TransferError(message: "\(name) in the copy isn’t an image", user: "Couldn’t paste — \(name) isn’t an image that can be copied"))
            }
            let stem = (name as NSString).deletingPathExtension, dotExt = ext.isEmpty ? "" : ".\(ext)"
            // File names are capped at 255 UTF-8 bytes: a long stem is cut (on a character boundary) to fit what follows it.
            func fitted(_ tail: String) -> String {
                var cut = ""
                for ch in stem {
                    if cut.utf8.count + String(ch).utf8.count + tail.utf8.count > 255 { break }
                    cut.append(ch)
                }
                return cut + tail
            }
            var candidate = name.utf8.count > 255 ? fitted(dotExt) : name
            let same = assets.appendingPathComponent(candidate)
            if fm.contents(atPath: same.path) != data, let reuse = sameBytes(data) { candidate = reuse.lastPathComponent }
            while true {
                let target = assets.appendingPathComponent(candidate)
                if !fm.fileExists(atPath: target.path) {
                    do {
                        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
                        try data.write(to: target, options: .withoutOverwriting)
                    } catch {
                        if fm.fileExists(atPath: target.path) { continue }  // lost a race: try again (identical bytes reuse it)
                        return .failed(TransferError(message: "can’t write assets/\(candidate): \(error.localizedDescription)"))
                    }
                    existing?[data.count, default: []].append(target)
                    written.append(target)
                } else if fm.contents(atPath: target.path) != data {
                    candidate = fitted("-\(NoteStore.randomSuffix())\(dotExt)")
                    continue
                }
                let hit = (target, "assets/\(candidate)")
                placed[key] = hit
                return .placed(file: hit.0, rel: hit.1)
            }
        }
        func sourceFile(_ path: String) -> (data: Data, name: String, key: String)? {
            guard let source = copy.folder, let file = NoteStore.resolve(relativePath: path, in: source),
                  let stat = NoteRegistry.fileStat(file.path), stat.isFile else { return nil }
            let key = NoteStore.realPath(file.path)
            guard stat.size <= Int64(maxImageBytes) else {
                warn("paste: skipped \(file.lastPathComponent) — over \(maxImageBytes / 1024 / 1024) MB")
                return nil
            }
            return fm.contents(atPath: key).map { ($0, file.lastPathComponent, key) }
        }
        func embeddedImage(_ ref: ImageRef, path: String) -> (data: Data, name: String, key: String)? {
            guard let uri = embedded[ref.from], let image = dataURIImage(uri) else { return nil }
            let file = (path.removingPercentEncoding ?? path).split(separator: "/").last.map(String.init) ?? ""
            let ext = image.type.preferredFilenameExtension ?? "png"
            let name = file.isEmpty || file.hasPrefix(".") || UTType(filenameExtension: (file as NSString).pathExtension) != image.type
                ? "image.\(ext)" : file
            return (image.data, name, SHA256.hash(data: image.data).description)
        }

        let md = NSMutableString(string: copy.markdown)
        var floor = md.length
        for ref in copy.images.sorted(by: { $0.from > $1.from }) {
            guard ref.from >= 0, ref.from <= ref.to, ref.to <= floor, let path = localPath(ref.src) else { continue }
            let bytes: (data: Data, name: String, key: String)
            if let fromCopy = embeddedImage(ref, path: path) {
                bytes = fromCopy
            } else if let source = sourceFile(path), validImage(source.data, name: source.name) {
                bytes = source
            } else {
                // Not in the copy (missing or undecodable at copy time) and no usable image at the source: it was already
                // broken when copied — the reference stays as written, nothing is copied.
                warn("paste: image \(path) isn’t in the copy and isn’t an image in its source folder — reference kept")
                continue
            }
            floor = ref.from
            // The reference already resolves to these exact bytes here (same folder, untouched asset): leave it as written.
            let there = NoteStore.resolve(relativePath: path, in: destination)
            if let there, let st = NoteRegistry.fileStat(there.path), st.isFile, st.size == Int64(bytes.data.count),
               fm.contents(atPath: there.path) == bytes.data { continue }
            switch place(bytes.data, name: bytes.name, key: bytes.key) {
            case .failed(let error):
                written.forEach { try? fm.removeItem(at: $0) }  // nothing is inserted: don't leave files behind
                return .failure(error)
            case .placed(let file, let rel):
                if let there, NoteStore.realPath(there.path) == NoteStore.realPath(file.path) { continue }
                md.replaceCharacters(in: NSRange(location: ref.from, length: ref.to - ref.from), with: escapeDestination(rel))
            }
        }
        return .success((md as String, written))
    }

    /// Lines the self-contained export up with the original Markdown: for each image ref the export replaced with a
    /// data URI, `ref.from` → that URI. Empty as soon as the two texts disagree outside the refs (not our export).
    nonisolated static func exportedImages(original: String, exported: String, images: [ImageRef]) -> [Int: String] {
        let o = original as NSString, e = exported as NSString
        var out: [Int: String] = [:]
        var oi = 0, ei = 0
        for ref in images.sorted(by: { $0.from < $1.from }) {
            guard ref.from >= oi, ref.to >= ref.from, ref.to <= o.length else { continue }
            let gap = ref.from - oi
            guard ei + gap <= e.length, o.substring(with: NSRange(location: oi, length: gap)) == e.substring(with: NSRange(location: ei, length: gap))
            else { return [:] }
            ei += gap
            if e.length - ei > 11, e.substring(with: NSRange(location: ei, length: 11)).lowercased() == "data:image/",
               !ref.src.lowercased().hasPrefix("data:") {
                let stop = e.rangeOfCharacter(from: uriStop, options: .literal, range: NSRange(location: ei, length: e.length - ei))
                let end = stop.location == NSNotFound ? e.length : stop.location
                out[ref.from] = e.substring(with: NSRange(location: ei, length: end - ei))
                ei = end
            } else {
                let len = ref.to - ref.from
                guard ei + len <= e.length, o.substring(with: NSRange(location: ref.from, length: len)) == e.substring(with: NSRange(location: ei, length: len))
                else { return [:] }
                ei += len
            }
            oi = ref.to
        }
        let tail = o.length - oi
        guard e.length - ei == tail, o.substring(from: oi) == e.substring(from: ei) else { return [:] }
        return out
    }

    /// Where a data URI in the export ends: the first character no URI we write contains.
    private nonisolated static let uriStop = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=:;,.-_%").inverted

    /// A relative path safe as a bare Markdown destination (no spaces, parens, brackets, escapes or references).
    private nonisolated static func escapeDestination(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    private static let imgTag = try! NSRegularExpression(pattern: #"(<img\b[^>]*?\bsrc\s*=\s*)(?:"([^"]*)"|'([^']*)')"#)

    // MARK: Helpers

    /// Relative destination inside the notes folder for an image src (as written), or nil for remote/data/absolute URLs.
    private nonisolated static func localPath(_ src: String) -> String? {
        var s = src.trimmingCharacters(in: .whitespaces)
        for prefix in ["nbm://notes/", "nbm://app/"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        if s.hasPrefix("./") { s = String(s.dropFirst(2)) }
        guard !s.isEmpty, !s.hasPrefix("/"), !s.contains(":") else { return nil }
        return s  // percent-decoding and `?query`/`#fragment` fallbacks happen in `resolve` (shared with nbm://notes/)
    }

    /// Character references in an HTML attribute value → text: `&#38;`, `&#x26;`, and named ones (`&amp;`, `&nbsp;`…).
    /// The renderer passes references from the Markdown source through as written; the editor decodes the same set
    /// (imageNodes.ts `decodeDestination`), so all three representations resolve the same file. Unknown names stay.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return replace(in: s, regex: entityRef) { g in
            if !g[2].isEmpty { return scalar(g[2], radix: 16) }
            if !g[3].isEmpty { return scalar(g[3], radix: 10) }
            return namedEntities[g[4]]
        }
    }

    private static func scalar(_ digits: String, radix: Int) -> String {
        guard let cp = UInt32(digits, radix: radix), cp != 0, let u = Unicode.Scalar(cp) else { return "\u{FFFD}" }
        return String(Character(u))
    }

    private static let entityRef = try! NSRegularExpression(pattern: #"&(?:#([xX])([0-9a-fA-F]{1,6})|#([0-9]{1,7})|([A-Za-z][A-Za-z0-9]{1,31}));"#)

    /// HTML's basic + Latin-1 + common typographic named references (paths with anything rarer are vanishingly rare).
    private static let namedEntities: [String: String] = {
        var map: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
            "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
            "hellip": "…", "bull": "•", "dagger": "†", "Dagger": "‡", "permil": "‰", "lsaquo": "‹", "rsaquo": "›",
            "euro": "€", "trade": "™", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
            "minus": "−", "ne": "≠", "le": "≤", "ge": "≥", "infin": "∞", "check": "✓", "star": "☆",
            "lpar": "(", "rpar": ")", "lsqb": "[", "rsqb": "]", "lbrack": "[", "rbrack": "]", "lcub": "{", "rcub": "}",
            "num": "#", "percnt": "%", "excl": "!", "quest": "?", "comma": ",", "period": ".", "colon": ":", "semi": ";",
            "sol": "/", "bsol": "\\", "ast": "*", "plus": "+", "equals": "=", "commat": "@", "dollar": "$", "lowbar": "_",
            "hyphen": "‐", "Hat": "^", "grave": "`", "verbar": "|", "vert": "|", "tilde": "˜", "Tab": "\t", "NewLine": "\n",
        ]
        // ISO-8859-1 (U+00A1…U+00FF), in code point order.
        let latin1 = """
        iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 acute micro para \
        middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave \
        Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute \
        Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave \
        iacute icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
        """.split(separator: " ")
        for (i, name) in latin1.enumerated() { map[String(name)] = String(Character(Unicode.Scalar(UInt32(0xA1 + i))!)) }
        return map
    }()

    /// Regex replace with a transform over capture groups (group 0 = whole match). nil keeps the match.
    private static func replace(in text: String, regex: NSRegularExpression, _ transform: ([String]) -> String?) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += transform(groups) ?? groups[0]
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

/// The root element of an SVG candidate (parsing stops there: no entity resolution, no full parse).
private nonisolated final class SVGRoot: NSObject, XMLParserDelegate {
    private var name: String?

    static func isSVG(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let root = SVGRoot()
        parser.delegate = root
        parser.parse()
        return root.name?.split(separator: ":").last.map(String.init)?.lowercased() == "svg"
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        name = elementName
        parser.abortParsing()
    }
}
