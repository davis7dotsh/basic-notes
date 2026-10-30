import Foundation

// CONTRACT (owned by the Store/Search agent; public API must stay as-is, internals are free).
// Hybrid local search: fuzzy title + full-text BM25 + on-device semantic embeddings + recency/frecency + pins.
// Index lives in `indexDirectory` (Application Support) and is fully rebuildable from the .md files.
//
// Layout: SQLite (FTS5 porter + trigram tables, per-note content hash, chunk vectors) in `indexDirectory/search.sqlite`;
// an in-memory mirror (folded text, title words, vectors) serves queries. Embeddings are computed off the actor in a
// background worker (debounced on edits); search always answers from whatever is indexed so far.

nonisolated struct IndexedNote: Sendable {
    var id: NoteID
    var content: String
    var modified: Date
}

/// Ranking inputs that live in AppState, passed in per query.
nonisolated struct RankingContext: Sendable {
    var pins: [NoteID]
    var frecency: [NoteID: Double]
    /// When each note was last opened/edited in the app (AppState). Recents order by max(this, file mtime).
    var lastOpened: [NoteID: Date] = [:]
}

/// Index progress, for diagnostics/UI.
nonisolated struct SearchIndexStatus: Sendable {
    var notes: Int
    var embedded: Int
    var pendingEmbeddings: Int
    var modelLoaded: Bool
    var modelID: String?
}

actor SearchService {
    nonisolated static let schemaVersion = "1"
    /// Quiet period after an edit before a note is (re)embedded.
    var embedDebounce: Duration = .seconds(2)
    /// Keyword re-index of a large note waits for a pause in its saves (or `upsertMaxWait` of continuous typing):
    /// re-tokenizing a long note on every autosave burns CPU. A search query flushes whatever is waiting first.
    var upsertDebounce: Duration = .milliseconds(1500)
    var upsertMaxWait: Duration = .seconds(5)
    /// Notes smaller than this (UTF-8 bytes) are re-indexed on every save.
    nonisolated static let immediateUpsertBytes = 20_000

    nonisolated struct Doc: Sendable {
        var id: NoteID
        var rowid: Int64
        var content: String
        var title: String
        var folded: [UInt8]
        var titleFolded: [UInt8]
        var titleWords: [Fuzzy.Word]
        /// Byte offsets (into `folded`) where each line starts, for same-line proximity.
        var lineStarts: [Int32] = [0]
        var modified: Date
        var hash: String
        /// UTF-16 [start, end) per chunk; vectors are `chunks.count * dim`, empty until embedded.
        var chunks: [Int32] = []
        var vectors: [Float] = []
        /// Letters of readable text, capped at `Tune.shortProseLetters` (markup and link targets excluded).
        var prose = 0
        var embedKey: String?
        /// Vectors of the previous version's chunks by chunk-text hash, so a re-embed after an edit only computes
        /// chunks whose text changed. Cleared once the new embedding is stored.
        var reuse: [UInt64: [Float]] = [:]
    }

    let db: SQLiteDB
    let modelDirectory: URL?
    let modelID: String?
    var embedder: Embedder?
    var embedderUnavailable = false
    var embedderLoading = false
    var idByRow: [Int64: NoteID] = [:]
    var df: [String: Int] = [:]
    var vocabCache: [(word: [UInt8], df: Int)]?
    var pending: [NoteID: ContinuousClock.Instant] = [:]
    /// Large-note upserts waiting for a pause: latest version + when the first/last unindexed save arrived.
    var deferred: [NoteID: (note: IndexedNote, first: ContinuousClock.Instant, last: ContinuousClock.Instant)] = [:]
    var deferredTimer: Task<Void, Never>?
    var workerRunning = false
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var queryVectorCache: [String: [Float]] = [:]
    var lineVectorCache: [UInt64: [Float]] = [:]
    var docs: [NoteID: Doc] = [:] { didSet { packedDirty = true } }
    /// Chunks actually run through the model (not reused). Diagnostics/eval.
    var chunksEmbedded = 0
    /// Eval/tuning override for the semantic floor (base cosine, unknown-word bump); nil => manifest + Tune.
    var floorOverride: (base: Double, bump: Double)?
    /// Eval/diagnostics: print each candidate's signal breakdown (tools/SearchEval --q "…" --explain).
    var explain = false
    var packed: [Float] = []
    /// Chunk rows per note, with the cosine penalty for notes with little prose (see `Tune.shortProseLetters`).
    var packedRows: [(id: NoteID, start: Int, count: Int, penalty: Float)] = []
    var packedDim = 0
    var packedDirty = true

    init(indexDirectory: URL, modelDirectory: URL? = Embedder.bundledModelDirectory()) {
        self.modelDirectory = modelDirectory
        modelID = modelDirectory.flatMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("manifest.json")))
                .flatMap { try? JSONDecoder().decode(Embedder.Manifest.self, from: $0) }?.id
        }
        db = Self.openDatabase(in: indexDirectory)
        embedder = modelDirectory.flatMap(Embedder.cached)
    }

    private static func openDatabase(in dir: URL) -> SQLiteDB {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("search.sqlite").path
        for attempt in 0..<2 {
            if let db = try? SQLiteDB(path: path), (try? prepareSchema(db)) != nil { return db }
            // Corrupt or incompatible: the index is derived data, so drop it and rebuild.
            if attempt == 0 { for s in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: path + s) } }
        }
        let mem = try! SQLiteDB(path: ":memory:")
        try? prepareSchema(mem)
        return mem
    }

    private static func prepareSchema(_ db: SQLiteDB) throws(SQLiteDB.Failure) {
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try db.exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        var version: String?
        db.run("SELECT value FROM meta WHERE key='schema'") { version = $0.text(0) }
        if version != schemaVersion {
            try db.exec("""
                DROP TABLE IF EXISTS notes; DROP TABLE IF EXISTS fts; DROP TABLE IF EXISTS tri;
                CREATE TABLE notes(rowid INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, hash TEXT NOT NULL,
                    embed_key TEXT, chunks BLOB, vectors BLOB);
                CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='porter unicode61 remove_diacritics 2');
                CREATE VIRTUAL TABLE tri USING fts5(title, body, tokenize='trigram remove_diacritics 1');
                INSERT OR REPLACE INTO meta(key, value) VALUES('schema', '\(schemaVersion)');
                """)
        }
        try db.exec("SELECT count(*) FROM notes; SELECT count(*) FROM fts; SELECT count(*) FROM tri;")
    }

    // MARK: Indexing

    /// Full (re)build from the current notes on disk. Safe to call at launch and after folder changes.
    func reindexAll(_ all: [IndexedNote]) async {
        struct Stored { var rowid: Int64; var hash: String; var embedKey: String?; var chunks: Data?; var vectors: Data? }
        var stored: [NoteID: Stored] = [:]
        db.run("SELECT rowid, id, hash, embed_key, chunks, vectors FROM notes") { r in
            guard let id = r.text(1), let hash = r.text(2) else { return }
            stored[id] = Stored(rowid: r.int(0), hash: hash, embedKey: r.text(3), chunks: r.blob(4), vectors: r.blob(5))
        }
        docs.removeAll(keepingCapacity: true)
        idByRow.removeAll(keepingCapacity: true)
        df.removeAll(keepingCapacity: true)
        vocabCache = nil
        pending.removeAll()
        let now = ContinuousClock.now
        var seen = Set<NoteID>()
        db.transaction {
            for note in all where seen.insert(note.id).inserted {
                var doc = Self.makeDoc(note)
                if let s = stored[note.id], s.hash == doc.hash {
                    doc.rowid = s.rowid
                    if let key = s.embedKey, key == embedKey(doc.hash) {
                        let c = s.chunks ?? Data(), v = s.vectors ?? Data()
                        doc.chunks = c.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
                        doc.vectors = v.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                        doc.embedKey = key
                    }
                } else {
                    if let s = stored[note.id] { deleteRows(s.rowid) }
                    doc.rowid = insertRows(doc)
                }
                if doc.embedKey == nil { pending[doc.id] = now }
                addToVocabulary(doc.content)
                idByRow[doc.rowid] = doc.id
                docs[doc.id] = doc
            }
            for (id, s) in stored where docs[id] == nil { deleteRows(s.rowid) }
        }
        ensureEmbedderLoaded()
        kickWorker()
    }

    /// Note created/edited (ours or external). Embedding is debounced; the keyword index updates immediately for small
    /// notes and after a pause in saves for large ones (see `upsertDebounce`).
    func upsert(_ note: IndexedNote) async {
        guard note.content.utf8.count >= Self.immediateUpsertBytes else {
            deferred[note.id] = nil
            return apply(note)
        }
        let now = ContinuousClock.now
        deferred[note.id] = (note, deferred[note.id]?.first ?? now, now)
        if deferredTimer == nil { deferredTimer = Task { await self.runDeferred() } }
    }

    /// Indexes every waiting large-note upsert now (search queries, tools).
    func flushDeferredUpserts() {
        let all = deferred.values.map(\.note)
        deferred.removeAll()
        all.forEach(apply)
    }

    private func due(_ d: (note: IndexedNote, first: ContinuousClock.Instant, last: ContinuousClock.Instant)) -> ContinuousClock.Instant {
        min(d.last + upsertDebounce, d.first + upsertMaxWait)
    }

    private func runDeferred() async {
        while let next = deferred.values.map(due).min() {
            if next > .now { try? await Task.sleep(until: next); continue }
            let now = ContinuousClock.now
            for (id, d) in deferred where due(d) <= now {
                deferred[id] = nil
                apply(d.note)
            }
        }
        deferredTimer = nil
    }

    private func apply(_ note: IndexedNote) {
        var doc = Self.makeDoc(note)
        if let old = docs[note.id] {
            if old.hash == doc.hash { docs[note.id]?.modified = note.modified; return }
            doc.reuse = Self.reusableVectors(old)
            removeFromVocabulary(old.content)
            db.transaction {
                deleteRows(old.rowid)
                idByRow[old.rowid] = nil
                doc.rowid = insertRows(doc)
            }
        } else {
            doc.rowid = insertRows(doc)
        }
        addToVocabulary(doc.content)
        idByRow[doc.rowid] = doc.id
        docs[doc.id] = doc
        pending[doc.id] = .now + embedDebounce
        kickWorker()
    }

    func remove(_ id: NoteID) async {
        deferred[id] = nil
        guard let old = docs.removeValue(forKey: id) else { return }
        removeFromVocabulary(old.content)
        idByRow[old.rowid] = nil
        pending[id] = nil
        deleteRows(old.rowid)
    }

    func rename(from: NoteID, to: NoteID) async {
        guard from != to else { return }
        let waiting = deferred.removeValue(forKey: from)
        defer { if var d = waiting { d.note.id = to; deferred[to] = d } }
        guard var doc = docs.removeValue(forKey: from) else { return }
        if let existing = docs[to] { await remove(existing.id) }
        doc.id = to
        docs[to] = doc
        idByRow[doc.rowid] = to
        if let p = pending.removeValue(forKey: from) { pending[to] = p }
        db.run("UPDATE notes SET id=? WHERE rowid=?", [.text(to), .int(doc.rowid)])
    }

    var status: SearchIndexStatus {
        SearchIndexStatus(
            notes: docs.count, embedded: docs.values.filter { $0.embedKey != nil }.count,
            pendingEmbeddings: pending.count, modelLoaded: embedder != nil, modelID: modelID)
    }

    /// Resolves once every pending embedding has been computed (or embedding is unavailable). For tools/tests.
    func waitUntilIdle() async {
        flushDeferredUpserts()
        if (pending.isEmpty && !embedderLoading) || embedderUnavailable || modelDirectory == nil { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// The whole note is indexed for keyword/substring search (no truncation); embedding work is bounded separately
    /// by the Chunker.
    static func makeDoc(_ note: IndexedNote) -> Doc {
        let content = note.content
        let title = NoteTitle.from(content)
        let folded = Text.foldUTF8(content)
        var lineStarts: [Int32] = [0]
        for (i, b) in folded.enumerated() where b == 10 { lineStarts.append(Int32(i + 1)) }
        return Doc(
            id: note.id, rowid: 0, content: content, title: title, folded: folded, titleFolded: Text.foldUTF8(title),
            titleWords: Fuzzy.words(of: title), lineStarts: lineStarts, modified: note.modified, hash: Text.hash(content),
            prose: Text.proseLetters(content, cap: Tune.shortProseLetters))
    }

    func embedKey(_ hash: String) -> String? { modelID.map { "\($0)|\(hash)" } }

    /// Chunk-text hash -> vector for an embedded doc (or the reuse map it still carries if not yet re-embedded).
    private static func reusableVectors(_ old: Doc) -> [UInt64: [Float]] {
        let n = old.chunks.count / 2
        guard n > 0, !old.vectors.isEmpty, old.vectors.count % n == 0 else { return old.reuse }
        let dim = old.vectors.count / n
        var out: [UInt64: [Float]] = [:]
        for i in 0..<n {
            guard let text = Chunker.chunkText(content: old.content, title: old.title, start: Int(old.chunks[2 * i]), end: Int(old.chunks[2 * i + 1]))
            else { continue }
            out[Text.hash64(text)] = Array(old.vectors[(i * dim)..<((i + 1) * dim)])
        }
        return out
    }

    private func insertRows(_ doc: Doc) -> Int64 {
        var rowid: Int64 = 0
        db.run("INSERT INTO notes(id, hash) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET hash=excluded.hash, embed_key=NULL, chunks=NULL, vectors=NULL RETURNING rowid",
               [.text(doc.id), .text(doc.hash)]) { rowid = $0.int(0) }
        db.run("DELETE FROM fts WHERE rowid=?", [.int(rowid)])
        db.run("DELETE FROM tri WHERE rowid=?", [.int(rowid)])
        db.run("INSERT INTO fts(rowid, title, body) VALUES(?, ?, ?)", [.int(rowid), .text(doc.title), .text(doc.content)])
        db.run("INSERT INTO tri(rowid, title, body) VALUES(?, ?, ?)", [.int(rowid), .text(doc.title), .text(doc.content)])
        return rowid
    }

    private func deleteRows(_ rowid: Int64) {
        db.run("DELETE FROM notes WHERE rowid=?", [.int(rowid)])
        db.run("DELETE FROM fts WHERE rowid=?", [.int(rowid)])
        db.run("DELETE FROM tri WHERE rowid=?", [.int(rowid)])
    }

    private func addToVocabulary(_ content: String) {
        for w in Set(Text.words(content)) where w.utf8.count >= 3 && w.utf8.count <= 24 { df[w, default: 0] += 1 }
        vocabCache = nil
    }

    private func removeFromVocabulary(_ content: String) {
        for w in Set(Text.words(content)) where w.utf8.count >= 3 && w.utf8.count <= 24 {
            if let n = df[w] { df[w] = n > 1 ? n - 1 : nil }
        }
        vocabCache = nil
    }

    // MARK: Embedding worker

    nonisolated private struct Job: Sendable {
        var id: NoteID
        var hash: String
        var content: String
        var title: String
        var reuse: [UInt64: [Float]]
    }

    nonisolated private struct Embedded: Sendable {
        var id: NoteID
        var hash: String
        var chunks: [Int32]
        var vectors: [Float]
        var computed: Int
    }

    nonisolated private enum Next: Sendable { case work([Job]), wait(Duration), done }

    /// Loads the model off the actor (once). Search works without it; semantic results appear once loaded.
    func ensureEmbedderLoaded() {
        guard embedder == nil, !embedderUnavailable, !embedderLoading, let dir = modelDirectory else { return }
        if let e = Embedder.cached(dir) { return didLoadEmbedder(e) }
        embedderLoading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let e = Embedder.shared(dir)
            await self?.didLoadEmbedder(e)
        }
    }

    private func didLoadEmbedder(_ e: Embedder?) {
        embedderLoading = false
        if let e {
            embedder = e
            kickWorker()
        } else {
            embedderUnavailable = true
            resumeIdleWaiters()
        }
    }

    private func kickWorker() {
        if pending.isEmpty || embedderUnavailable || modelDirectory == nil { resumeIdleWaiters(); return }
        guard let embedder else { ensureEmbedderLoaded(); return }
        guard !workerRunning else { return }
        workerRunning = true
        let ref = WeakService(value: self)
        // Bulk indexing (launch, folder change) at utility; re-embedding a few edited notes stays out of the way.
        Task.detached(priority: pending.count > 8 ? .utility : .background) {
            await Self.workLoop(ref, embedder: embedder)
        }
    }

    nonisolated private struct WeakService: Sendable { weak var value: SearchService? }

    /// Background embedding loop. Holds the service only weakly between batches, so a replaced service (folder change)
    /// is released and its loop ends.
    @concurrent
    private static func workLoop(_ ref: WeakService, embedder: Embedder) async {
        while true {
            guard let service = ref.value else { return }
            switch await service.nextJobs() {
            case .done: return
            case .wait(let d): try? await Task.sleep(for: d)
            case .work(let jobs):
                var results: [Embedded] = []
                for job in jobs {
                    let chunks = Chunker.chunks(content: job.content, title: job.title, tokenizer: embedder.tokenizer)
                    let keys = chunks.map { Text.hash64($0.text) }
                    let todo = keys.indices.filter { job.reuse[keys[$0]] == nil }
                    var fresh = [Int: [Float]]()
                    for (i, v) in zip(todo, embedder.embedDocuments(todo.map { chunks[$0].text })) { fresh[i] = v }
                    let vectors = keys.indices.flatMap { fresh[$0] ?? job.reuse[keys[$0]] ?? [] }
                    results.append(Embedded(id: job.id, hash: job.hash, chunks: chunks.flatMap { [Int32($0.start), Int32($0.end)] },
                                            vectors: vectors, computed: todo.count))
                }
                await service.storeEmbeddings(results)
            }
        }
    }

    private func nextJobs() -> Next {
        let now = ContinuousClock.now
        var due: [NoteID] = []
        var soonest: ContinuousClock.Instant?
        for (id, t) in pending {
            // Newer saves are still waiting to be indexed: embed once they land, not the stale version.
            let at = deferred[id] == nil ? t : max(t, now + upsertDebounce)
            if at <= now { due.append(id) } else { soonest = min(soonest ?? at, at) }
        }
        if due.isEmpty {
            if let soonest { return .wait(max(.milliseconds(50), soonest - now)) }
            workerRunning = false
            resumeIdleWaiters()
            return .done
        }
        // Batch by size so results land (and become searchable) incrementally.
        var jobs: [Job] = []
        var chars = 0
        for id in due.sorted(by: { (docs[$0]?.modified ?? .distantPast) > (docs[$1]?.modified ?? .distantPast) }) {
            guard let d = docs[id] else { pending[id] = nil; continue }
            jobs.append(Job(id: id, hash: d.hash, content: d.content, title: d.title, reuse: d.reuse))
            chars += min(d.content.utf16.count, Chunker.maxInputChars)
            if chars > 12_000 || jobs.count >= 16 { break }
        }
        if jobs.isEmpty { return nextJobs() }
        for j in jobs { pending[j.id] = .now + .seconds(3600) }  // in flight; re-queued by edits
        return .work(jobs)
    }

    private func storeEmbeddings(_ results: [Embedded]) {
        db.transaction {
            for r in results {
                let (id, hash, chunks, vectors) = (r.id, r.hash, r.chunks, r.vectors)
                chunksEmbedded += r.computed
                guard var doc = docs[id] else { continue }
                if doc.hash != hash { continue }  // edited meanwhile; its pending entry was refreshed by upsert
                pending[id] = nil
                doc.chunks = chunks
                doc.vectors = vectors
                doc.reuse = [:]
                doc.embedKey = embedKey(hash)
                docs[id] = doc
                db.run("UPDATE notes SET embed_key=?, chunks=?, vectors=? WHERE rowid=? AND hash=?", [
                    doc.embedKey.map { .text($0) } ?? .null,
                    .blob(chunks.withUnsafeBufferPointer { Data(buffer: $0) }),
                    .blob(vectors.withUnsafeBufferPointer { Data(buffer: $0) }),
                    .int(doc.rowid), .text(hash),
                ])
            }
        }
    }

    private func resumeIdleWaiters() {
        let w = idleWaiters
        idleWaiters.removeAll()
        w.forEach { $0.resume() }
    }
}
