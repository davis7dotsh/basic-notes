import CoreServices
import Foundation
import UniformTypeIdentifiers
import Synchronization

// Folder of `<id>.md` files (source of truth) + `assets/`. Metadata is cached in memory (`list()` is cheap) and kept
// in sync by an FSEvents watcher that reports external changes only (our own writes never echo back).
// Saves never clobber unseen disk content: every note remembers the disk revision we last read or wrote
// ("acknowledged"); a write that finds something else on disk keeps that version as a `-conflict-` copy first.

nonisolated struct NoteMeta: Sendable, Equatable {
    var id: NoteID
    var title: String
    var modified: Date
}

nonisolated enum StoreError: Error, Sendable {
    case notFound(NoteID)
    /// Not a single file-name component inside the notes folder (`../x`, `a/b`, `.hidden`, NUL…): never touched.
    case invalidID(NoteID)
    case io(String)
    /// The notes folder itself is gone (moved, deleted, unmounted).
    case folderMissing
    /// An exclusive create found a file already there (it appeared after we checked): nothing was written.
    case appeared
}

nonisolated enum StoreEvent: Sendable {
    /// Existing note's file content changed on disk by someone other than us.
    case changed(id: NoteID, content: String)
    case added(id: NoteID)
    case removed(id: NoteID)
    case renamed(from: NoteID, to: NoteID)
    /// A note file that can't be read (not UTF-8, oversized, permissions): "<file name>: <why>". Left untouched.
    case unreadable(String)
    /// The notes folder disappeared (false) or came back (true). No `.removed` events are sent while it's missing.
    case folderAvailable(Bool)
    /// Image files in the folder (assets/…) were created, replaced, deleted or renamed by someone else: paths relative
    /// to the folder, sorted. A renamed/removed directory's path stands for everything under it; `""` for the whole folder.
    case assetsChanged([String])
}

nonisolated struct WriteResult: Sendable {
    var meta: NoteMeta
    /// The file had changed on disk since we last read/wrote it; that version was kept as this note before writing ours.
    var conflictCopy: NoteMeta?
}

/// A note file loaded for indexing.
nonisolated struct LoadedNote: Sendable {
    var id: NoteID
    var content: String
    var modified: Date
}

final class NoteStore {
    /// Warnings (skipped files). The app routes these to its log; the store has no logging dependency.
    static var warn: (String) -> Void = { print("warning: \($0)") }

    private(set) var folder: URL
    /// Files skipped by the last full scan (see `StoreEvent.unreadable` for the format).
    private(set) var skipped: [String] = []
    /// External-change events, delivered on the main actor.
    var onEvent: ((StoreEvent) -> Void)?
    /// A read found a disk revision the watcher hadn't reported yet (it never will): whatever mirrors note contents
    /// (search) must take it from here.
    var onRevisionRead: ((LoadedNote) -> Void)?

    private let registry = NoteRegistry()
    private var watcher: FolderWatcher?
    private var generation = 0
    /// Renames a save found before the watcher reported them (see `adoptRename`) → when. The watcher's own report of one
    /// (the rename, or the old name's removal) is dropped when it comes.
    private var adopted: [NoteID: (to: NoteID, at: Date)] = [:]

    init(folder: URL) {
        self.folder = folder
        open(folder)
    }

    deinit { watcher?.stop() }

    func setFolder(_ url: URL) {
        watcher?.stop()
        watcher = nil
        folder = url
        adopted = [:]
        open(url)
    }

    private func open(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        skipped = registry.scan(url).sorted()
        skipped.forEach { Self.warn("skipping note file \($0)") }
        generation += 1
        let gen = generation
        let registry = registry
        watcher = FolderWatcher(folder: url, registry: registry) { [weak self] events in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    for event in events where !self.adoptedEarlier(event) {
                        if case .renamed(let from, let to) = event { registry.moveAcknowledged(from: from, to: to) }
                        self.onEvent?(event)
                    }
                }
            }
        }
    }

    /// The watcher reporting a rename `adoptRename` already took (or the old name's removal): nothing new.
    private func adoptedEarlier(_ event: StoreEvent) -> Bool {
        guard !adopted.isEmpty else { return false }
        adopted = adopted.filter { Date().timeIntervalSince($0.value.at) < 5 }
        switch event {
        case .renamed(let from, let to) where adopted[from]?.to == to:
            adopted[from] = nil
            return true
        case .removed(let id) where adopted[id] != nil:
            adopted[id] = nil
            return true
        case .added(let id), .changed(let id, _):
            adopted[id] = nil  // a file at the old name again is another story
            return false
        default:
            return false
        }
    }

    /// `id`'s file is gone, and the same file (inode) is in the folder under another note name: renamed elsewhere a moment
    /// ago, before the watcher said so. The store moves the note to its new name now (cached revision and acknowledged
    /// content go with it, so a save there doesn't take the renamed file for an unseen edit) and returns that id; the
    /// watcher's report, when it comes, is dropped. nil when it isn't a rename that can be told apart from a removal.
    func adoptRename(of id: NoteID) -> NoteID? {
        guard fileURL(id) != nil, let to = registry.adoptRename(of: id, folder: folder) else { return nil }
        adopted[id] = (to, Date())
        return to
    }

    /// `<folder>/<id>.md`, or nil when `id` isn't a valid note id (see `isValidID`) or the result would leave the folder.
    func fileURL(_ id: NoteID) -> URL? {
        guard Self.isValidID(id) else { return nil }
        let url = folder.appendingPathComponent("\(id).md")
        guard url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else { return nil }
        return url
    }

    /// A note id is exactly what the store lists: `<id>.md` passes `NoteRegistry.isNoteFile` (one file-name component,
    /// no `/` or NUL, no leading `.` so never `.`/`..`, fits in 255 bytes). `\` and `:` are legal macOS file-name characters.
    nonisolated static func isValidID(_ id: String) -> Bool { NoteRegistry.isNoteFile("\(id).md") }

    var folderExists: Bool { NoteRegistry.isDirectory(folder.path) }

    /// Cached metadata for every note, newest first.
    func list() -> [NoteMeta] { registry.metas().sorted { $0.modified > $1.modified } }

    func meta(_ id: NoteID) -> NoteMeta? {
        if let m = registry.meta(id) { return m }
        guard case .success(let content) = peek(id) else { return nil }
        return NoteMeta(id: id, title: NoteTitle.from(content), modified: registry.meta(id)?.modified ?? Date())
    }

    func exists(_ id: NoteID) -> Bool { fileURL(id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// `exists`, but not when `<id>.md` only finds the file under another case of its name (case-insensitive volume).
    func existsExactly(_ id: NoteID) -> Bool { fileURL(id).map { NoteRegistry.existsExactly($0.path) } ?? false }

    /// Reads a note for the editor (LF line endings) and acknowledges that disk revision.
    func read(_ id: NoteID) -> Result<String, StoreError> { read(id, acknowledge: true) }

    /// Reads without acknowledging (indexing, previews).
    func peek(_ id: NoteID) -> Result<String, StoreError> { read(id, acknowledge: false) }

    private func read(_ id: NoteID, acknowledge: Bool) -> Result<String, StoreError> {
        guard let url = fileURL(id) else { return .failure(.invalidID(id)) }
        return registry.read(id, url: url, acknowledge: acknowledge).map { read in
            // Read ahead of the watcher: its event for this revision won't come (already seen) — report it here.
            if let e = read.surfaced { onRevisionRead?(LoadedNote(id: id, content: read.content, modified: e.modified)) }
            return read.content
        }
    }

    /// Atomic, fsynced write; creates the file if needed. Keeps the file's line endings/encoding. If the disk content
    /// changed since we last read/wrote it, that version is saved as a conflict copy first (see `WriteResult`).
    func write(_ id: NoteID, content: String) -> Result<WriteResult, StoreError> {
        guard fileURL(id) != nil else { return .failure(.invalidID(id)) }
        guard folderExists else { return .failure(.folderMissing) }
        return registry.write(id, content: content, folder: folder)
    }

    /// Disk content of `id` when it differs from the revision we last read or wrote (an external edit nobody has
    /// handled yet), else nil.
    func unacknowledgedChange(_ id: NoteID) -> String? { fileURL(id).flatMap { registry.unacknowledgedChange(id, url: $0) } }

    /// The editor has seen/handled this disk content (external change applied, or kept as a copy).
    func acknowledge(_ id: NoteID, content: String) { registry.acknowledge(id, content: content) }

    /// Keep `content` as its own note next to `id`: `<id>-conflict-HHmmss.md`.
    func saveConflictCopy(of id: NoteID, content: String) -> Result<NoteMeta, StoreError> {
        guard fileURL(id) != nil else { return .failure(.invalidID(id)) }
        guard folderExists else { return .failure(.folderMissing) }
        return registry.writeConflictCopy(of: id, data: Data(content.utf8), folder: folder)
    }

    /// Date-based, collision-safe: "2026-10-25-2130-a1b2"
    func makeNewID() -> NoteID {
        while true {
            let id = Self.candidateID()
            if !exists(id) && registry.meta(id) == nil { return id }
        }
    }

    private static func candidateID() -> NoteID {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(f.string(from: Date()))-\(randomSuffix())"
    }

    /// A brand-new note in another folder (not the open one), durably written (atomic + fsync). Used to move an
    /// unsaved buffer into a folder before switching to it.
    static func createNote(in folder: URL, content: String) -> Result<NoteID, StoreError> {
        guard NoteRegistry.isDirectory(folder.path) else { return .failure(.folderMissing) }
        var id = candidateID()
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(id).md").path) { id = candidateID() }
        return NoteRegistry.atomicWrite(TextFormat().encode(content), to: folder.appendingPathComponent("\(id).md"), mode: 0o644).map { _ in id }
    }

    /// Moves the note to the macOS Trash (no `.removed` event is emitted for it).
    /// Success carries where it landed in the Trash (when the system reports it).
    func trash(_ id: NoteID) -> Result<URL?, StoreError> {
        guard let url = fileURL(id) else { return .failure(.invalidID(id)) }
        guard folderExists else { return .failure(.folderMissing) }
        let entry = registry.forget(id)
        do {
            var landed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
            return .success(landed as URL?)
        } catch {
            if let entry { registry.restore(entry) }
            return .failure(.io(error.localizedDescription))
        }
    }

    /// Removes an empty note's file for good (no Trash, no event).
    func removeEmpty(_ id: NoteID) -> Result<Void, StoreError> {
        guard let url = fileURL(id) else { return .failure(.invalidID(id)) }
        let entry = registry.forget(id)
        do {
            try FileManager.default.removeItem(at: url)
            return .success(())
        } catch {
            if let entry { registry.restore(entry) }
            return .failure(.io(error.localizedDescription))
        }
    }

    /// Saves into `<folder>/assets/`. Returns the relative Markdown path, e.g. "assets/pasted-20261025-2130-zzzz.png".
    func saveAsset(_ data: Data, ext: String) -> Result<String, StoreError> {
        guard folderExists else { return .failure(.folderMissing) }
        let dir = folder.appendingPathComponent("assets")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let clean = String(ext.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.prefix(8))
        let safeExt = clean.isEmpty ? "png" : clean
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var name: String
            repeat {
                name = "pasted-\(f.string(from: Date()))-\(Self.randomSuffix()).\(safeExt)"
            } while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            acknowledgeAssetWrites([dir.appendingPathComponent(name)])
            return .success("assets/\(name)")
        } catch {
            return .failure(.io(error.localizedDescription))
        }
    }

    /// Files the app itself just wrote into the folder (pasted images): the watcher doesn't report them as changed.
    func acknowledgeAssetWrites(_ files: [URL]) {
        registry.acknowledgeAssets(files.compactMap { url in
            let path = Self.realPath(url.path)
            return NoteRegistry.fileStat(path).map { (path, $0) }
        })
    }

    /// Resolves a Markdown destination (e.g. "assets/x.png") to a file URL inside the notes folder (or reached through a
    /// symlink inside it), or nil if the path itself escapes it (absolute paths, `..`). Tries the path as written, then
    /// percent-decoded (`lit%20(v2).png`), then without a `?query`/`#fragment` suffix (plain and decoded); the first
    /// candidate that exists wins, else the as-written one.
    func resolve(relativePath: String) -> URL? { Self.resolve(relativePath: relativePath, in: folder) }

    /// `resolve(relativePath:)` against any notes folder.
    nonisolated static func resolve(relativePath: String, in folder: URL) -> URL? {
        var candidates = [relativePath]
        if let decoded = relativePath.removingPercentEncoding { candidates.append(decoded) }
        if let q = relativePath.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            let base = String(relativePath[..<q])
            candidates.append(base)
            if let decoded = base.removingPercentEncoding { candidates.append(decoded) }
        }
        let inside = candidates.compactMap { contained($0, in: folder) }
        return inside.first { FileManager.default.fileExists(atPath: $0.path) } ?? inside.first
    }

    private nonisolated static func contained(_ rel: String, in folder: URL) -> URL? {
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.hasPrefix("~"), !rel.contains("\0") else { return nil }
        let root = realPath(folder.path)
        let candidate = realPath(folder.appendingPathComponent(rel).path)
        if candidate.hasPrefix(root + "/") { return URL(fileURLWithPath: candidate) }
        // Outside only through a symlink inside the folder (a linked `assets/`, a linked image): the user's choice, like a
        // symlinked note. Only for a path that can't climb out by itself (no `..`), to a file that's there.
        guard !rel.split(separator: "/").contains(".."), candidate != root, FileManager.default.fileExists(atPath: candidate) else { return nil }
        return URL(fileURLWithPath: candidate)
    }

    /// Every note file in `folder` (same candidate/decoding policy as the store), for indexing.
    nonisolated static func loadAll(_ folder: URL) -> [LoadedNote] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter(NoteRegistry.isNoteFile)
        return names.compactMap { name in
            guard case .ok(let disk) = NoteRegistry.load(folder.appendingPathComponent(name).path) else { return nil }
            return LoadedNote(id: String(name.dropLast(3)), content: disk.content, modified: Date(timeIntervalSince1970: disk.stat.mtime))
        }
    }

    /// realpath(3) for existing paths; standardized path otherwise (still rejects `..` escapes).
    nonisolated static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(p) }
        return String(cString: p)
    }

    nonisolated static func randomSuffix(_ length: Int = 4) -> String {
        String((0..<length).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    /// `<id><suffix>` as a note id whose `.md` file name fits in 255 bytes with `reserve` bytes to spare (for a later
    /// `-2`…): a long id is cut on a character boundary and tagged with a hash of the whole id, so different long ids
    /// don't collide.
    nonisolated static func fittedID(_ id: String, suffix: String, reserve: Int = 0) -> String {
        let room = 255 - ".md".utf8.count - suffix.utf8.count - reserve
        if id.utf8.count <= room { return id + suffix }
        let tag = "-" + String(Text.hash64(id), radix: 36)
        var cut = ""
        for ch in id {
            if cut.utf8.count + String(ch).utf8.count + tag.utf8.count > room { break }
            cut.append(ch)
        }
        return cut + tag + suffix
    }
}

// MARK: - Text format

/// How a note file is stored on disk. The editor always works in LF/UTF-8; writes convert back.
nonisolated struct TextFormat: Sendable, Equatable {
    enum Encoding: Sendable { case utf8, utf8BOM }
    var encoding: Encoding = .utf8
    var crlf = false

    /// Decodes UTF-8 (optionally with a BOM, kept on write). Returns LF-normalized text. Anything else (UTF-16,
    /// Latin-1, binary) is rejected rather than guessed at — a wrong guess would be rewritten on the next save.
    static func decode(_ data: Data) -> (String, TextFormat)? {
        let decoded: (String?, Encoding) = data.starts(with: [0xEF, 0xBB, 0xBF])
            ? (String(data: data.dropFirst(3), encoding: .utf8), .utf8BOM)
            : (String(data: data, encoding: .utf8), .utf8)
        guard let text = decoded.0 else { return nil }
        let crlf = text.contains("\r\n")
        return (crlf ? text.replacingOccurrences(of: "\r\n", with: "\n") : text, TextFormat(encoding: decoded.1, crlf: crlf))
    }

    func encode(_ content: String) -> Data {
        let text = crlf ? content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : content
        switch encoding {
        case .utf8: return Data(text.utf8)
        case .utf8BOM: return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        }
    }
}

// MARK: - Registry

/// Thread-safe cache of what's on disk for each note, shared by the store (main actor) and the watcher queue.
/// `entries` = the disk revision the watcher (or our last read/write) saw — drives change detection.
/// `acknowledged` = content hash of the revision the editor is based on (last read/written by us) — guards writes.
/// The lock also serializes our writes with the watcher's reconcile so our own writes are never reported as external.
nonisolated final class NoteRegistry: Sendable {
    struct Entry: Sendable {
        var id: NoteID
        var title: String
        var modified: Date
        var hash: String
        var inode: UInt64
        var size: Int64
        var mtime: Double
        var format: TextFormat

        func matches(_ st: FileStat) -> Bool { inode == st.inode && size == st.size && mtime == st.mtime }
    }

    struct FileStat: Equatable {
        var inode: UInt64, size: Int64, mtime: Double, isFile: Bool, mode: mode_t
    }

    struct DiskNote {
        var content: String
        var format: TextFormat
        var stat: FileStat
    }

    enum Loaded {
        case ok(DiskNote)
        case missing
        case unreadable(String)
    }

    private struct State {
        var entries: [NoteID: Entry] = [:]
        var acknowledged: [NoteID: String] = [:]
        /// The last revision of each note file the watcher saw vanish (by its inode a save can still find it, renamed).
        var gone: [NoteID: Entry] = [:]
        /// Non-note files we wrote (real path → stat right after the write): their FSEvents aren't external changes.
        var ownAssets: [String: FileStat] = [:]
    }

    static let maxFileSize: Int64 = 20 * 1024 * 1024

    func acknowledgeAssets(_ files: [(String, FileStat)]) {
        state.withLock { s in
            for (path, stat) in files { s.ownAssets[path] = stat }
            if s.ownAssets.count > 500 { s.ownAssets.removeAll() }  // only recent writes matter (events arrive within ms)
        }
    }

    /// Whether `path` is exactly as we last wrote it (an echo of our own write, not an external change).
    func isOwnAssetWrite(_ path: String, stat: FileStat?) -> Bool {
        guard let stat else { return false }
        return state.withLock { $0.ownAssets[path] == stat }
    }

    private let state = Mutex(State())

    static func fileStat(_ path: String) -> FileStat? {
        var st = Darwin.stat()
        guard stat(path, &st) == 0 else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return FileStat(inode: UInt64(st.st_ino), size: Int64(st.st_size), mtime: mtime, isFile: (st.st_mode & S_IFMT) == S_IFREG, mode: st.st_mode)
    }

    /// The name `path`'s last component has on disk (not following a symlink), or nil when that can't be read. On a
    /// case-insensitive volume `one.md` also finds `One.md`, so after a case-only rename the old name still stats fine.
    static func diskName(_ path: String) -> String? {
        var req = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_NAME),
                           volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var buf = [UInt8](repeating: 0, count: 4 + MemoryLayout<attrreference_t>.size + 1024)
        return buf.withUnsafeMutableBytes { raw -> String? in
            guard let base = raw.baseAddress, getattrlist(path, &req, base, raw.count, UInt32(FSOPT_NOFOLLOW)) == 0 else { return nil }
            let ref = raw.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
            let start = 4 + Int(ref.attr_dataoffset), length = Int(ref.attr_length)
            guard length > 0, start >= 4, start + length <= raw.count else { return nil }
            // `attr_length` counts the trailing NUL. Compared as Swift strings, so Unicode normalization doesn't matter.
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<(start + length - 1)]), as: UTF8.self)
        }
    }

    /// Whether `path` is there under exactly that name, not just as another case of an existing name (see `diskName`).
    static func existsExactly(_ path: String) -> Bool {
        guard fileStat(path) != nil else { return false }
        return diskName(path).map { $0 == (path as NSString).lastPathComponent } ?? true
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = Darwin.stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Reads + decodes a note file. Oversized / binary files are `.unreadable` (with a reason worth logging).
    static func load(_ path: String) -> Loaded {
        guard let st = fileStat(path) else { return .missing }
        let name = (path as NSString).lastPathComponent
        guard st.isFile else { return .unreadable("\(name): not a regular file") }
        guard st.size <= maxFileSize else { return .unreadable("\(name): \(String(format: "%.1f", Double(st.size) / 1_048_576))MB is over the 20MB limit") }
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable("\(name): can't read (permissions?)") }
        guard let (content, format) = TextFormat.decode(data) else { return .unreadable("\(name): not UTF-8 text") }
        return .ok(DiskNote(content: content, format: format, stat: st))
    }

    static func entry(_ id: NoteID, _ disk: DiskNote) -> Entry {
        Entry(id: id, title: NoteTitle.from(disk.content), modified: Date(timeIntervalSince1970: disk.stat.mtime),
              hash: Text.hash(disk.content), inode: disk.stat.inode, size: disk.stat.size, mtime: disk.stat.mtime, format: disk.format)
    }

    /// The one candidate-file policy (listing, opening, watching, indexing): `*.md`, minus dotfiles (vim swap files,
    /// our temp files, `.#` lock files), `#…` (emacs autosave) and `~$…` (Office owner files). Backups like `foo.md~`
    /// don't end in `.md` and are excluded by that alone; a `~` inside a name (`tilde~draft.md`) is a normal note.
    static func isNoteFile(_ name: String) -> Bool {
        name.hasSuffix(".md") && name.count > 3 && name.utf8.count <= 255 && !name.hasPrefix(".") && !name.hasPrefix("#")
            && !name.hasPrefix("~$") && !name.contains("/") && !name.contains("\0")
    }

    /// Full scan of the folder (parallel reads). Returns skipped (unreadable) files with reasons.
    func scan(_ folder: URL) -> [String] {
        let (entries, skipped) = Self.scanEntries(folder)
        state.withLock {
            $0.entries = entries
            $0.acknowledged = entries.mapValues(\.hash)
            $0.gone = [:]
        }
        return skipped
    }

    static func scanEntries(_ folder: URL) -> ([NoteID: Entry], [String]) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter(isNoteFile)
        let results = Mutex<([Entry], [String])>(([], []))
        DispatchQueue.concurrentPerform(iterations: names.count) { i in
            let name = names[i]
            switch load(folder.appendingPathComponent(name).path) {
            case .ok(let disk):
                let e = entry(String(name.dropLast(3)), disk)
                results.withLock { $0.0.append(e) }
            case .unreadable(let reason): results.withLock { $0.1.append(reason) }
            case .missing: break
            }
        }
        let (entries, skipped) = results.withLock { $0 }
        return (Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }), skipped)
    }

    func metas() -> [NoteMeta] {
        state.withLock { $0.entries.values.map { NoteMeta(id: $0.id, title: $0.title, modified: $0.modified) } }
    }

    func meta(_ id: NoteID) -> NoteMeta? {
        state.withLock { $0.entries[id].map { NoteMeta(id: $0.id, title: $0.title, modified: $0.modified) } }
    }

    func snapshot() -> [NoteID: Entry] { state.withLock { $0.entries } }

    /// `surfaced`: the read found a revision the registry hadn't seen (a new file, or content the watcher hasn't
    /// reported yet). The registry now holds it, so the watcher will treat that revision as already seen.
    func read(_ id: NoteID, url: URL, acknowledge: Bool) -> Result<(content: String, surfaced: Entry?), StoreError> {
        state.withLock { s in
            switch Self.load(url.path) {
            case .ok(let disk):
                let e = Self.entry(id, disk)
                let old = s.entries[id]
                s.entries[id] = e
                if acknowledge { s.acknowledged[id] = e.hash }
                return .success((disk.content, old?.hash == e.hash ? nil : e))
            case .missing: return .failure(.notFound(id))
            case .unreadable(let reason): return .failure(.io("unreadable: \(reason)"))
            }
        }
    }

    func unacknowledgedChange(_ id: NoteID, url: URL) -> String? {
        state.withLock { s in
            guard case .ok(let disk) = Self.load(url.path) else { return nil }
            let hash = Text.hash(disk.content)
            return hash == s.acknowledged[id] ? nil : disk.content
        }
    }

    func acknowledge(_ id: NoteID, content: String) {
        state.withLock { $0.acknowledged[id] = Text.hash(content) }
    }

    /// A rename's file is the one that was at `from`: what we acknowledged there holds at `to` (anything acknowledged for
    /// `to` before was about a file that's gone — a stale value would make the next save keep the renamed file as a copy).
    func moveAcknowledged(from: NoteID, to: NoteID) {
        state.withLock { s in
            if let h = s.acknowledged.removeValue(forKey: from) { s.acknowledged[to] = h }
        }
    }

    /// See `NoteStore.adoptRename`: the note file now holding `id`'s last-known inode (only when `id.md` is gone).
    func adoptRename(of id: NoteID, folder: URL) -> NoteID? {
        state.withLock { s in
            guard let old = s.entries[id] ?? s.gone[id], old.inode != 0,
                  !Self.existsExactly(folder.appendingPathComponent("\(id).md").path) else { return nil }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter(Self.isNoteFile)
            let same = names.first { name in
                name != "\(id).md" && Self.fileStat(folder.appendingPathComponent(name).path).map { $0.isFile && $0.inode == old.inode } == true
            }
            guard let name = same, case .ok(let disk) = Self.load(folder.appendingPathComponent(name).path) else { return nil }
            let to = String(name.dropLast(3))
            s.entries[id] = nil
            s.gone[id] = nil
            s.entries[to] = Self.entry(to, disk)
            if let h = s.acknowledged.removeValue(forKey: id) { s.acknowledged[to] = h }
            return to
        }
    }

    func write(_ id: NoteID, content: String, folder: URL) -> Result<WriteResult, StoreError> {
        state.withLock { s in
            // A file that appears between the stat and the rename (a folder restored with `cp -R`, a sync client) is a
            // disk revision we haven't seen: the rename refuses to replace it, and the next round preserves it first.
            var result = Self.write(id, content: content, folder: folder, into: &s)
            for _ in 0..<3 {
                guard case .failure(.appeared) = result else { break }
                result = Self.write(id, content: content, folder: folder, into: &s)
            }
            if case .failure(.appeared) = result { return .failure(.io("\(id).md keeps changing on disk")) }
            return result
        }
    }

    private static func write(_ id: NoteID, content: String, folder: URL, into s: inout State) -> Result<WriteResult, StoreError> {
        // A symlinked note is saved through the link into its target (the link stays a link) — also when the target
        // was deleted: it's recreated where the link points, if that directory is still there and writable.
        let link = folder.appendingPathComponent("\(id).md")
        let dangling = Self.symlinkTarget(link) == nil ? Self.danglingLinkTarget(link) : nil
        let url = Self.symlinkTarget(link) ?? dangling ?? link
        let ours = Text.hash(content)
        var format = s.entries[id]?.format ?? TextFormat()
        var conflict: NoteMeta?
        var mode: mode_t = 0o644
        // Never replace a disk revision we haven't seen: keep it as a conflict copy first.
        let found = Self.fileStat(url.path)
        if let st = found, st.isFile {
            mode = st.mode & 0o7777
            let known = s.entries[id].flatMap { $0.matches(st) ? $0 : nil }
            if let known { format = known.format }
            var diskHash = known?.hash
            var raw: Data?
            if diskHash == nil {
                raw = FileManager.default.contents(atPath: url.path)
                if let raw, let (text, fmt) = TextFormat.decode(raw) {
                    diskHash = Text.hash(text)
                    format = fmt
                }
            }
            // Unreadable disk content (diskHash nil) is never overwritten unseen either.
            if diskHash == nil || (diskHash != ours && diskHash != s.acknowledged[id]) {
                if raw == nil { raw = FileManager.default.contents(atPath: url.path) }
                // Can't get the bytes to keep a copy (permissions, vanished mid-read): fail rather than replace.
                guard let raw else { return .failure(.io("can't read \(id).md on disk to preserve it")) }
                if !Self.isBlank(raw) {
                    switch Self.conflictCopy(of: id, data: raw, folder: folder, into: &s) {
                    case .success(let meta): conflict = meta
                    case .failure(let error): return .failure(error)  // couldn't preserve it: don't overwrite either
                    }
                }
            }
        }
        let data = format.encode(content)
        // Nothing there when we looked: only create it, never replace what turned up since (see `appeared`).
        let exclusive = found == nil
        var written = url == link ? Self.atomicWrite(data, to: url, mode: mode, exclusive: exclusive) : Self.writeThroughLink(data, to: url, mode: mode, exclusive: exclusive)
        if case .failure(.appeared) = written { return .failure(.appeared) }
        // Couldn't recreate a dangling link's target: the note becomes a regular file at the link (content kept).
        if case .failure = written, dangling != nil { written = Self.atomicWrite(data, to: link, mode: mode) }
        switch written {
        case .failure(let error): return .failure(error)
        case .success(let st):
            let e = Self.entry(id, DiskNote(content: content, format: format, stat: st))
            s.entries[id] = e
            s.acknowledged[id] = ours
            return .success(WriteResult(meta: NoteMeta(id: id, title: e.title, modified: e.modified), conflictCopy: conflict))
        }
    }

    func writeConflictCopy(of id: NoteID, data: Data, folder: URL) -> Result<NoteMeta, StoreError> {
        state.withLock { Self.conflictCopy(of: id, data: data, folder: folder, into: &$0) }
    }

    /// Writes `data` unchanged as `<id>-conflict-HHmmss[-n].md` and registers it (so the watcher doesn't report it).
    private static func conflictCopy(of id: NoteID, data: Data, folder: URL, into s: inout State) -> Result<NoteMeta, StoreError> {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        let base = NoteStore.fittedID(id, suffix: "-conflict-\(f.string(from: Date()))", reserve: 4)
        var copyID = base
        var n = 2
        while s.entries[copyID] != nil || FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(copyID).md").path) {
            copyID = "\(base)-\(n)"
            n += 1
        }
        let url = folder.appendingPathComponent("\(copyID).md")
        switch atomicWrite(data, to: url, mode: 0o644) {
        case .failure(let error): return .failure(error)
        case .success(let st):
            let (text, format) = TextFormat.decode(data) ?? (String(decoding: data, as: UTF8.self), TextFormat())
            let e = entry(copyID, DiskNote(content: text, format: format, stat: st))
            s.entries[copyID] = e
            s.acknowledged[copyID] = e.hash
            return .success(NoteMeta(id: copyID, title: e.title, modified: e.modified))
        }
    }

    private static func isBlank(_ data: Data) -> Bool {
        TextFormat.decode(data).map { $0.0.allSatisfy(\.isWhitespace) } ?? data.isEmpty
    }

    /// Where a symlinked note file really lives (fully resolved), or nil when `url` isn't a symlink (or doesn't resolve).
    static func symlinkTarget(_ url: URL) -> URL? {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { return nil }
        let real = NoteStore.realPath(url.path)
        return real == url.path ? nil : URL(fileURLWithPath: real)
    }

    /// Where a dangling symlinked note's deleted target belongs: the end of its link chain (relative links resolved
    /// against their own directory), when nothing is there and its directory exists and is writable. nil otherwise.
    static func danglingLinkTarget(_ url: URL) -> URL? {
        var path = url.path
        for _ in 0..<32 {
            var st = Darwin.stat()
            if lstat(path, &st) != 0 {
                guard errno == ENOENT, path != url.path else { return nil }
                let dir = NoteStore.realPath((path as NSString).deletingLastPathComponent)
                guard NoteRegistry.isDirectory(dir), access(dir, W_OK) == 0 else { return nil }
                return URL(fileURLWithPath: dir).appendingPathComponent((path as NSString).lastPathComponent)
            }
            guard (st.st_mode & S_IFMT) == S_IFLNK, let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
            path = dest.hasPrefix("/") ? dest : (NoteStore.realPath((path as NSString).deletingLastPathComponent) as NSString).appendingPathComponent(dest)
        }
        return nil
    }

    /// A symlinked note's target: atomically in its own directory when we can create files there, else in place.
    private static func writeThroughLink(_ data: Data, to target: URL, mode: mode_t, exclusive: Bool) -> Result<FileStat, StoreError> {
        let atomic = atomicWrite(data, to: target, mode: mode, exclusive: exclusive)
        if case .failure(.appeared) = atomic { return atomic }
        guard case .failure = atomic, access(target.deletingLastPathComponent().path, W_OK) != 0,
              access(target.path, W_OK) == 0 else { return atomic }
        let fd = Darwin.open(target.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.io(String(cString: strerror(errno)))) }
        var failure: String?
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = String(cString: strerror(errno))
                    return
                }
                offset += n
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = String(cString: strerror(errno)) }
        if close(fd) != 0, failure == nil { failure = String(cString: strerror(errno)) }
        if let failure { return .failure(.io(failure)) }
        return .success(fileStat(target.path) ?? FileStat(inode: 0, size: Int64(data.count), mtime: Date().timeIntervalSince1970, isFile: true, mode: mode))
    }

    /// Temp dotfile in the same directory (ignored by the watcher) → write → fsync → rename over the target → fsync dir.
    /// The temp name is short and independent of the target's, so any legal file name (up to 255 bytes) can be saved.
    /// `exclusive`: only create the file — `.appeared` (nothing written) when one is there by the time of the rename.
    static func atomicWrite(_ data: Data, to url: URL, mode: mode_t, exclusive: Bool = false) -> Result<FileStat, StoreError> {
        let dir = url.deletingLastPathComponent()
        let errno_ = { String(cString: strerror(errno)) }
        var tmp = ""
        var fd: Int32 = -1
        for _ in 0..<8 {
            tmp = dir.appendingPathComponent(".nbm-\(NoteStore.randomSuffix(10)).tmp").path
            fd = Darwin.open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
            if fd >= 0 || errno != EEXIST { break }
        }
        guard fd >= 0 else { return .failure(errno == ENOENT ? .folderMissing : .io(errno_())) }
        var failure: String?
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno_()
                    return
                }
                offset += n
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = errno_() }
        if close(fd) != 0, failure == nil { failure = errno_() }
        if failure == nil, (exclusive ? renamex_np(tmp, url.path, UInt32(RENAME_EXCL)) : rename(tmp, url.path)) != 0 {
            if exclusive && errno == EEXIST {
                unlink(tmp)
                return .failure(.appeared)
            }
            failure = errno_()
        }
        if let failure {
            unlink(tmp)
            return .failure(.io(failure))
        }
        let dfd = Darwin.open(dir.path, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 { fsync(dfd); close(dfd) }
        return .success(fileStat(url.path) ?? FileStat(inode: 0, size: Int64(data.count), mtime: Date().timeIntervalSince1970, isFile: true, mode: mode))
    }

    @discardableResult
    func forget(_ id: NoteID) -> Entry? { state.withLock { $0.entries.removeValue(forKey: id) } }

    func restore(_ e: Entry) { state.withLock { $0.entries[e.id] = e } }

    enum Change: Sendable {
        case unchanged
        case changed(String)
        case appeared(Entry, String)
        case vanished(Entry)
        case unreadable(String)
    }

    /// Compares disk with the registry for one note and updates the registry (not the acknowledged revision).
    func reconcile(_ id: NoteID, path: String) -> Change {
        state.withLock { s in
            let old = s.entries[id]
            // A name that only stats as another case of the file's real name (a case-only rename on a case-insensitive
            // volume) is gone: the watcher pairs it with the real name by inode, as with any rename.
            guard let st = Self.fileStat(path), st.isFile, Self.diskName(path).map({ $0 == (path as NSString).lastPathComponent }) ?? true else {
                guard let old else { return .unchanged }
                s.entries[id] = nil
                s.gone[id] = old
                return .vanished(old)
            }
            if let old, old.matches(st) { return .unchanged }
            let disk: DiskNote
            switch Self.load(path) {
            case .ok(let d): disk = d
            case .missing: return .unchanged
            case .unreadable(let reason): return .unreadable(reason)
            }
            let e = Self.entry(id, disk)
            s.entries[id] = e
            guard let old else { return .appeared(e, disk.content) }
            return old.hash == e.hash ? .unchanged : .changed(disk.content)
        }
    }
}

// MARK: - Watcher

/// FSEvents (file-level, ~50ms latency) watcher. Reconciles touched notes against the registry, pairs removals with
/// additions into renames (same inode or identical content within a short window), and survives atomic-save editors
/// (a file that vanishes and reappears is a content check, not remove+add). If the folder itself goes away it reports
/// `.folderAvailable(false)` once (instead of removing every note) and resumes when the folder is back.
nonisolated final class FolderWatcher: @unchecked Sendable {
    private let folder: URL
    private let root: String
    private let registry: NoteRegistry
    private let emit: @Sendable ([StoreEvent]) -> Void
    private let queue = DispatchQueue(label: "nbm.store.watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    // Queue-confined state.
    private var pendingRemovals: [NoteID: (entry: NoteRegistry.Entry, deadline: DispatchTime)] = [:]
    private var stopped = false
    private var rootMissing = false
    private var reportedUnreadable: [NoteID: String] = [:]

    static let renameWindow = 0.35

    init(folder: URL, registry: NoteRegistry, emit: @escaping @Sendable ([StoreEvent]) -> Void) {
        self.folder = folder
        self.root = NoteStore.realPath(folder.path)
        self.registry = registry
        self.emit = emit
        start()
    }

    private func start() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let fl = Array(UnsafeBufferPointer(start: flags, count: count))
            watcher.handle(paths: list, flags: fl)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        queue.sync { stopped = true }  // drain in-flight callbacks; no further events after this
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard !stopped else { return }
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        let rootFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        var ids = Set<NoteID>()
        var assets = Set<String>()
        var fullRescan = false
        var rootTouched = false
        var dropped = false
        let wasMissing = rootMissing
        for (i, path) in paths.enumerated() {
            let flag = i < flags.count ? flags[i] : 0
            if flag & rescanFlags != 0 { fullRescan = true; dropped = true }
            if flag & rootFlag != 0 || path == root { rootTouched = true; continue }
            let url = URL(fileURLWithPath: path)
            let parent = url.deletingLastPathComponent().path
            let name = url.lastPathComponent
            if parent == root || parent == root + "/", NoteRegistry.isNoteFile(name) {
                ids.insert(String(name.dropLast(3)))
            } else if let rel = assetPath(path) {
                // A directory matters when it was renamed/removed (everything under it moved); a new empty one doesn't.
                let isDir = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                let moved = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved) != 0
                if isDir && !moved { continue }
                // Only image files (not editors' temp/backup files: `x.png.sb-…`, `4913`, `note.md~`).
                if !isDir && !Self.isImageName(rel) { continue }
                if !isDir && registry.isOwnAssetWrite(path, stat: NoteRegistry.fileStat(path)) { continue }
                assets.insert(rel)
            }
        }
        if !assets.isEmpty { emit([.assetsChanged(assets.sorted())]) }
        if rootTouched || fullRescan || rootMissing {
            guard checkRoot() else { return }
            if rootTouched { fullRescan = true }
        }
        // The folder came back, or events were dropped: any image in it may be different now.
        if wasMissing || dropped { emit([.assetsChanged([""])]) }
        if fullRescan {
            let onDisk = Set(((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter(NoteRegistry.isNoteFile).map { String($0.dropLast(3)) })
            ids.formUnion(onDisk)
            ids.formUnion(registry.snapshot().keys)
        }
        process(ids)
    }

    private static func isImageName(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return !ext.isEmpty && UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }

    /// `path` relative to the folder if it's a non-note file or directory inside it that images could point at: not
    /// hidden (our temp files, `.DS_Store`, `.git/…`) at any level, not a root-level note-ish file.
    private func assetPath(_ path: String) -> String? {
        guard path.hasPrefix(root + "/") else { return nil }
        let rel = String(path.dropFirst(root.count + 1))
        let parts = rel.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0.hasPrefix(".") }) else { return nil }
        if parts.count == 1, rel.hasSuffix(".md") { return nil }  // note-ish file at the root (`#x.md`, `~$x.md`)
        return rel
    }

    /// false (and reports it once) while the folder is missing; reports its return.
    private func checkRoot() -> Bool {
        let exists = NoteRegistry.isDirectory(root)
        if exists == !rootMissing { return exists }
        rootMissing = !exists
        if rootMissing { pendingRemovals = [:] }
        emit([.folderAvailable(exists)])
        return exists
    }

    private func process(_ ids: Set<NoteID>) {
        var events: [StoreEvent] = []
        var appeared: [(NoteRegistry.Entry, String)] = []
        let now = DispatchTime.now()
        func reconcile(_ ids: some Sequence<NoteID>) {
            for id in ids {
                switch registry.reconcile(id, path: root + "/" + id + ".md") {
                case .unchanged: break
                case .changed(let content): events.append(.changed(id: id, content: content))
                case .vanished(let old): pendingRemovals[id] = (old, now + Self.renameWindow)
                case .appeared(let e, let content): appeared.append((e, content))
                case .unreadable(let reason):
                    if reportedUnreadable[id] != reason {
                        reportedUnreadable[id] = reason
                        events.append(.unreadable(reason))
                    }
                }
            }
        }
        reconcile(ids.sorted())
        // A new name holding the file a note we still list has (same inode): if that note's name is gone — or only finds
        // the file as another case of its name, which may be all a case-only rename reports — it's a rename (below).
        let inodes = Set(appeared.map(\.0.inode).filter { inode in inode != 0 && !pendingRemovals.values.contains { $0.entry.inode == inode } })
        if !inodes.isEmpty {
            reconcile(registry.snapshot().values.filter { !ids.contains($0.id) && inodes.contains($0.inode) }.map(\.id).sorted())
        }
        for (e, content) in appeared {
            reportedUnreadable[e.id] = nil
            if let back = pendingRemovals.removeValue(forKey: e.id) {
                // Atomic save (vim/VS Code): same name vanished and reappeared.
                if back.entry.hash != e.hash { events.append(.changed(id: e.id, content: content)) }
            } else if let from = pendingRemovals.first(where: { $0.value.entry.inode == e.inode && e.inode != 0 })?.key
                        ?? pendingRemovals.first(where: { $0.value.entry.hash == e.hash })?.key {
                pendingRemovals[from] = nil
                events.append(.renamed(from: from, to: e.id))
            } else {
                events.append(.added(id: e.id))
            }
        }
        if !events.isEmpty { emit(events) }
        if !pendingRemovals.isEmpty {
            queue.asyncAfter(deadline: now + Self.renameWindow + 0.02) { [weak self] in self?.flushRemovals() }
        }
    }

    private func flushRemovals() {
        guard !stopped, !pendingRemovals.isEmpty else { return }
        // Files vanishing because the whole folder went away aren't note deletions.
        guard checkRoot() else { return }
        let now = DispatchTime.now()
        var events: [StoreEvent] = []
        for (id, p) in pendingRemovals where p.deadline <= now {
            pendingRemovals[id] = nil
            // Reappeared without an event reaching us yet? Then it's a content check, not a removal.
            let path = root + "/" + id + ".md"
            switch registry.reconcile(id, path: path) {
            case .appeared(let e, let content):
                if e.hash != p.entry.hash { events.append(.changed(id: id, content: content)) }
            case .changed(let content):
                events.append(.changed(id: id, content: content))
            case .unchanged where NoteRegistry.existsExactly(path):
                break  // already back in the registry (we re-wrote it)
            default:
                events.append(.removed(id: id))
            }
        }
        if !events.isEmpty { emit(events) }
    }
}
