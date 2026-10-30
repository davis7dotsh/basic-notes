import Foundation

// Mirror of web/src/bridge/protocol.ts. Keep both in sync.
// JS -> Swift arrives via WKScriptMessageHandlerWithReply named "bridge".
// Swift -> JS is delivered by evaluating `window.__nbm.receive(<json>)`.
// Request/response calls into JS use callAsyncJavaScript: `await window.__nbm.flush()` and
// `return window.__nbm.applyExternal(id, content)` (Bool: true = applied, false = editor dirty, keep editor),
// `window.__nbm.discardPendingSaves()` (before swapping folders after carrying an unsaved buffer).

typealias NoteID = String

struct ViewState: Codable, Equatable, Sendable {
    var anchor: Int
    var head: Int
    var scrollTop: Double
}

struct NotePayload: Codable, Sendable {
    var id: NoteID
    var content: String
    var pinned: Bool
    var pinIndex: Int?
    var isNew: Bool
    var viewState: ViewState?
    var canGoBack: Bool
    var canGoForward: Bool
    /// Opaque key of the note's folder: JS namespaces relative image URLs/caches by it (see protocol.ts).
    var folder: String?
}

struct EditorSettings: Codable, Equatable, Sendable {
    var vimEnabled: Bool
}

enum MatchKind: String, Codable, Sendable {
    case recent, title, text, semantic
}

struct SearchHit: Codable, Sendable {
    var id: NoteID
    var title: String
    var snippet: String
    /// [start, end) UTF-16 offsets into snippet
    var snippetHighlights: [[Int]]
    /// [start, end) UTF-16 offsets into title
    var titleHighlights: [[Int]]
    /// ms since epoch
    var modified: Double
    var pinned: Bool
    var pinIndex: Int?
    var matchKind: MatchKind
    var score: Double
}

/// A real Markdown image node from the Lezer parse. from/to are UTF-16 offsets of the destination text in `markdown`.
nonisolated struct ImageRef: Codable, Sendable {
    var from: Int
    var to: Int
    var src: String
    /// Offset of the image's first use (reference images: the first `![…][ref]`, while from/to are the definition's
    /// destination). Orders attachments. nil = `from`.
    var at: Int?

    var order: Int { at ?? from }
}

/// JS -> Swift
enum ToSwift: Sendable {
    case ready
    case save(id: NoteID, content: String)
    case viewState(id: NoteID, viewState: ViewState)
    case saveImage(base64: String, mime: String, filename: String?)
    case search(query: String)
    case open(id: NoteID)
    case newNote
    case deleteNote(id: NoteID)
    case togglePin(id: NoteID)
    case openPin(index: Int)
    case back
    case forward
    case copyNote(id: NoteID, markdown: String, html: String, images: [ImageRef])
    case hide
    /// The ⌘P search overlay opened/closed: native ⌘V then pastes into its input instead of the note.
    case searchOpen(Bool)
    /// Answer to a tokened `insertText`: whether the reserved paste went in (false → remove the files written for it).
    case pasteResult(token: String, inserted: Bool)
    /// `replaced`: the text a Visual put replaced — written only if the pasteboard hasn't moved on since the editor last
    /// heard of it (a put from a stale view must not clobber a newer copy).
    case setClipboard(text: String, replaced: Bool)
    /// Vim `p` of our own copy into the paste the editor reserved under `token`. See protocol.ts.
    case pasteOwnCopy(token: String, text: String)
    case openURL(String)
    case openSettings
    /// ⌘= / ⌘- / reset: text zoom step (+1, -1, 0 = reset).
    case zoom(step: Int)
    case log(level: String, message: String)
}

extension ToSwift: Decodable {
    private enum K: String, CodingKey {
        case type, id, content, viewState, base64, mime, filename, query, index, markdown, html, url, level, message, text, images, open, token, inserted, replaced, step
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "ready": self = .ready
        case "save": self = .save(id: try c.decode(String.self, forKey: .id), content: try c.decode(String.self, forKey: .content))
        case "viewState": self = .viewState(id: try c.decode(String.self, forKey: .id), viewState: try c.decode(ViewState.self, forKey: .viewState))
        case "saveImage":
            self = .saveImage(
                base64: try c.decode(String.self, forKey: .base64),
                mime: try c.decode(String.self, forKey: .mime),
                filename: try c.decodeIfPresent(String.self, forKey: .filename))
        case "search": self = .search(query: try c.decode(String.self, forKey: .query))
        case "open": self = .open(id: try c.decode(String.self, forKey: .id))
        case "newNote": self = .newNote
        case "deleteNote": self = .deleteNote(id: try c.decode(String.self, forKey: .id))
        case "togglePin": self = .togglePin(id: try c.decode(String.self, forKey: .id))
        case "openPin": self = .openPin(index: try c.decode(Int.self, forKey: .index))
        case "back": self = .back
        case "forward": self = .forward
        case "copyNote":
            self = .copyNote(
                id: try c.decode(String.self, forKey: .id),
                markdown: try c.decode(String.self, forKey: .markdown),
                html: try c.decode(String.self, forKey: .html),
                images: try c.decodeIfPresent([ImageRef].self, forKey: .images) ?? [])
        case "hide": self = .hide
        case "searchOpen": self = .searchOpen(try c.decode(Bool.self, forKey: .open))
        case "pasteResult": self = .pasteResult(token: try c.decode(String.self, forKey: .token), inserted: try c.decode(Bool.self, forKey: .inserted))
        case "setClipboard": self = .setClipboard(text: try c.decode(String.self, forKey: .text), replaced: try c.decodeIfPresent(Bool.self, forKey: .replaced) ?? false)
        case "pasteOwnCopy": self = .pasteOwnCopy(token: try c.decode(String.self, forKey: .token), text: try c.decode(String.self, forKey: .text))
        case "openURL": self = .openURL(try c.decode(String.self, forKey: .url))
        case "openSettings": self = .openSettings
        case "zoom": self = .zoom(step: try c.decode(Int.self, forKey: .step))
        case "log": self = .log(level: try c.decode(String.self, forKey: .level), message: try c.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown bridge message type \(type)")
        }
    }
}

extension ToSwift {
    /// The note id a message addresses, if any (validated at the bridge boundary).
    var noteID: NoteID? {
        switch self {
        case .save(let id, _), .viewState(let id, _), .open(let id), .deleteNote(let id), .togglePin(let id), .copyNote(let id, _, _, _): id
        default: nil
        }
    }
}

/// Swift -> JS
enum FromSwift: Sendable {
    case `init`(settings: EditorSettings)
    case loadNote(NotePayload)
    /// `token`: a paste reserved by `beginPaste` (see protocol.ts) — inserted where it was invoked, not at the live selection.
    /// The page answers every tokened one with `pasteResult`.
    case insertText(String, block: Bool, token: String? = nil)
    /// A native paste whose text comes later (own copy with images): reserve the current selection. See protocol.ts.
    case beginPaste(token: String)
    /// The reserved paste failed or was cancelled.
    case cancelPaste(token: String)
    case settings(EditorSettings)
    case openSearch
    case pinState(id: NoteID, pinned: Bool, pinIndex: Int?)
    case navState(canGoBack: Bool, canGoForward: Bool)
    case focus
    case toast(message: String, tone: ToastTone)
    /// Vim's unnamed register text. For our own ⌘⇧C copy: the note's original Markdown, never the base64 export.
    /// `ownCopy`: our own copy of a note with images (vim's `p` then asks for `pasteOwnCopy`).
    case systemClipboard(text: String, ownCopy: Bool = false)
    /// Non-note files in the notes folder changed externally (paths relative to the folder). See protocol.ts.
    case assetsChanged(paths: [String])
    /// A native paste while the search overlay is open: insert into its input (replacing the input's selection).
    case searchText(String)
    /// The open note's text isn't in the notes folder (`unsaved`: a re-save into the restored folder failed) or now is.
    case unsavedText(id: NoteID, unsaved: Bool)
    /// A note's file was renamed elsewhere: the editor's session for `from` (if open) goes on as `to`. See protocol.ts.
    case retarget(from: NoteID, to: NoteID)
    /// A native header button: open the ⌘K action menu, copy the note, or start a new note.
    case runAction(HeaderAction)
}

enum HeaderAction: String, Codable, Sendable { case actions, copyNote, newNote }

enum ToastTone: String, Codable, Sendable { case info, error }

extension FromSwift: Encodable {
    private enum K: String, CodingKey {
        case type, settings, note, id, text, block, token, pinned, pinIndex, canGoBack, canGoForward, message, tone, paths, ownCopy, unsaved, from, to, action
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .`init`(let settings):
            try c.encode("init", forKey: .type)
            try c.encode(settings, forKey: .settings)
        case .loadNote(let note):
            try c.encode("loadNote", forKey: .type)
            try c.encode(note, forKey: .note)
        case .insertText(let text, let block, let token):
            try c.encode("insertText", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(block, forKey: .block)
            try c.encodeIfPresent(token, forKey: .token)
        case .beginPaste(let token):
            try c.encode("beginPaste", forKey: .type)
            try c.encode(token, forKey: .token)
        case .cancelPaste(let token):
            try c.encode("cancelPaste", forKey: .type)
            try c.encode(token, forKey: .token)
        case .settings(let settings):
            try c.encode("settings", forKey: .type)
            try c.encode(settings, forKey: .settings)
        case .openSearch:
            try c.encode("openSearch", forKey: .type)
        case .pinState(let id, let pinned, let pinIndex):
            try c.encode("pinState", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(pinned, forKey: .pinned)
            try c.encode(pinIndex, forKey: .pinIndex)
        case .navState(let back, let forward):
            try c.encode("navState", forKey: .type)
            try c.encode(back, forKey: .canGoBack)
            try c.encode(forward, forKey: .canGoForward)
        case .focus:
            try c.encode("focus", forKey: .type)
        case .toast(let message, let tone):
            try c.encode("toast", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encode(tone, forKey: .tone)
        case .systemClipboard(let text, let ownCopy):
            try c.encode("systemClipboard", forKey: .type)
            try c.encode(text, forKey: .text)
            if ownCopy { try c.encode(true, forKey: .ownCopy) }
        case .assetsChanged(let paths):
            try c.encode("assetsChanged", forKey: .type)
            try c.encode(paths, forKey: .paths)
        case .searchText(let text):
            try c.encode("searchText", forKey: .type)
            try c.encode(text, forKey: .text)
        case .unsavedText(let id, let unsaved):
            try c.encode("unsavedText", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(unsaved, forKey: .unsaved)
        case .retarget(let from, let to):
            try c.encode("retarget", forKey: .type)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case .runAction(let action):
            try c.encode("runAction", forKey: .type)
            try c.encode(action, forKey: .action)
        }
    }
}
