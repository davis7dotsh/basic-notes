import Darwin
import Foundation

// Search evaluation harness. Builds an index over tools/fixtures/notes, runs the tuning (queries.json), held-out
// (queries-holdout.json) and edge (queries-edge.json: code literals, CRLF, a 435k-char note, and negatives that must
// return nothing / must not rank a note) sets; prints R@1/R@3/MRR per category, the false-positive rate, latencies,
// incremental re-embed work, idle CPU, and 5k-note latency.
//
//   SearchEval [--fixtures DIR] [--model DIR] [--queries FILE] [--q "query" [--edge]] [--scale N] [--verbose] [--raw]
//              [--calib] [--floor X [--bump Y]] [--no-incremental] [--fuzz] [--store] [--probe FILE] [--explain]
//              [--lines "query" --ids a,b]

let args = CommandLine.arguments
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fixtures = URL(fileURLWithPath: arg("--fixtures") ?? "tools/fixtures", relativeTo: root)
let modelDir: URL? = {
    if args.contains("--no-model") { return nil }
    let base = URL(fileURLWithPath: arg("--model") ?? "App/Resources/Models", relativeTo: root)
    return Embedder.firstModel(in: base)
}()
let verbose = args.contains("--verbose")

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func loadNotes(_ dir: URL) -> [IndexedNote] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }.compactMap { url in
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        // Deterministic pseudo-random age (0-180 days) so recency is realistic noise, not a hint.
        var h: UInt64 = 1469598103934665603
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return IndexedNote(id: id, content: content, modified: Date().addingTimeInterval(-Double(h % 180) * 86_400 - Double(h % 86_400)))
    }
}

struct Query: Decodable { var q: String; var expect: String?; var category: String; var reject: String?; var top: Int?; var allow: [String]?; var max: Int? }

extension SearchService {
    /// Eval-only: fill every note with random unit vectors to measure brute-force semantic cost at scale.
    func injectRandomVectors(dim: Int, chunksPerNote: Int) {
        for id in docs.keys {
            var v = (0..<(dim * chunksPerNote)).map { _ in Float.random(in: -1...1) }
            for c in 0..<chunksPerNote {
                var n: Float = 0
                for i in 0..<dim { n += v[c * dim + i] * v[c * dim + i] }
                for i in 0..<dim { v[c * dim + i] /= n.squareRoot() }
            }
            docs[id]?.vectors = v
            docs[id]?.chunks = (0..<chunksPerNote).flatMap { _ in [Int32(0), Int32(1)] }
        }
        pending.removeAll()
    }
    func forceEmbedder(_ e: Embedder) { embedder = e }
    func setEmbedDebounce(_ d: Duration) { embedDebounce = d }
    func setFloor(_ base: Double, _ bump: Double) { floorOverride = (base, bump) }
    func setExplain(_ on: Bool) { explain = on }
    /// Raw best-chunk cosine view of a query: `expect`'s rank/similarity/z (if given) and the top note's.
    func rawSemantic(_ q: String, expect: NoteID?) -> (rank: Int, sim: Float, z: Float, top: Float, topZ: Float, topID: String)? {
        guard let embedder else { return nil }
        let qv = embedder.embedQuery(q)
        let dim = qv.count
        var sims: [(NoteID, Float)] = []
        for (id, d) in docs where !d.vectors.isEmpty {
            var best: Float = -1
            for c in 0..<(d.vectors.count / dim) {
                var s: Float = 0
                for i in 0..<dim { s += d.vectors[c * dim + i] * qv[i] }
                best = max(best, s)
            }
            sims.append((id, best))
        }
        sims.sort { $0.1 > $1.1 }
        guard !sims.isEmpty else { return nil }
        let vals = sims.map { Double($0.1) }
        let mean = vals.reduce(0, +) / Double(vals.count)
        let sd = (vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(vals.count)).squareRoot()
        let z = { (x: Float) in Float((Double(x) - mean) / sd) }
        let r = expect.flatMap { e in sims.firstIndex { $0.0 == e } } ?? 0
        return (r + 1, sims[r].1, z(sims[r].1), sims[0].1, z(sims[0].1), sims[0].0)
    }
}

let clock = ContinuousClock()
let ctx = RankingContext(pins: [], frecency: [:])

if args.contains("--store") {
    await StoreCheck.run()
    exit(0)
}

let notes = loadNotes(fixtures.appendingPathComponent("notes"))
let fuzzQueries = (try? JSONDecoder().decode([Query].self, from: Data(contentsOf: fixtures.appendingPathComponent(arg("--queries") ?? "queries.json")))) ?? []

if args.contains("--fuzz") {
    // Robustness: weird notes + hostile queries + typing simulation + searching while embeddings are still running.
    var weird = notes
    let huge = String(repeating: "lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 90_000)
    let extras: [(String, String)] = [
        ("w-empty", ""), ("w-space", "   \n\n\t "), ("w-huge", "# Huge note\n" + huge),
        ("w-ctrl", "# ctrl\u{0}\u{1}\u{7}\u{1B}[31m\u{0}\u{FEFF}text"), ("w-emoji", "🙂🙃🔥\n🚀 launch"),
        ("w-cjk", "# 中文笔记\n今天学习了很多东西"), ("w-rtl", "# مرحبا\nملاحظات عربية"),
        ("w-longline", String(repeating: "x", count: 300_000)), ("w-combining", "# cafe\u{301} nai\u{308}ve"),
        ("w-title", String(repeating: "Very long title ", count: 500)), ("w-fts", "# \"quotes\" AND OR NOT NEAR(a b) * ^ -x col:val"),
    ]
    for (id, c) in extras { weird.append(IndexedNote(id: id, content: c, modified: Date())) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nbm-fuzz-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let svc = SearchService(indexDirectory: dir, modelDirectory: modelDir)
    var t = clock.now
    await svc.reindexAll(weird)
    print(String(format: "indexed %d notes (incl. weird) keyword-ready in %.0f ms", weird.count, ms(clock.now - t)))
    // Search immediately, while embeddings are being computed in the background.
    var during: [Double] = []
    var titleHits = 0
    for q in fuzzQueries where q.category == "exact_title" {
        let t0 = clock.now
        let h = await svc.search(q.q, context: ctx)
        during.append(ms(clock.now - t0))
        if h.first?.id == q.expect { titleHits += 1 }
    }
    let mid = await svc.status
    print(String(format: "during embedding (%d/%d embedded): exact-title #1 %d/%d, max latency %.2f ms",
                 mid.embedded, mid.notes, titleHits, fuzzQueries.filter { $0.category == "exact_title" }.count, during.max() ?? 0))
    t = clock.now
    await svc.waitUntilIdle()
    print(String(format: "embeddings finished after %.0f ms more", ms(clock.now - t)))
    let hostile = ["", " ", "\"", "*", "(", ")", "NEAR(", "AND", "OR", "NOT", "-", ":", "^", "\"unbalanced", "a", "é", "🙂", "中文", "مرحبا",
                   String(repeating: "x", count: 10_000), String(repeating: "word ", count: 2_000), "' OR 1=1 --", "title:foo", "{title}: x",
                   "\\", "\u{0}", "\n\t", "ab\"cd*ef(gh", "cafe", "naive", "lorem", "Huge", "*:-^\"()"]
    var maxLat = 0.0
    for q in hostile {
        let t0 = clock.now
        let h = await svc.search(q, context: RankingContext(pins: ["w-emoji", "missing-id"], frecency: ["w-cjk": 3]))
        maxLat = max(maxLat, ms(clock.now - t0)); if ms(clock.now - t0) > 20 { print(String(format: "  slow %.1f ms: %@ (%d hits)", ms(clock.now - t0), String(q.prefix(30)), h.count)) }
        for hit in h {  // highlight ranges must be valid UTF-16 ranges
            let n16 = hit.snippet.utf16.count, t16 = hit.title.utf16.count
            if !hit.snippetHighlights.allSatisfy({ $0.count == 2 && $0[0] >= 0 && $0[0] < $0[1] && $0[1] <= n16 }) ||
               !hit.titleHighlights.allSatisfy({ $0.count == 2 && $0[0] >= 0 && $0[0] < $0[1] && $0[1] <= t16 }) {
                print("  BAD highlight range for query \(q.prefix(20)) hit \(hit.id)")
            }
        }
    }
    print(String(format: "hostile queries: %d ran, max latency %.2f ms", hostile.count, maxLat))
    // Typing simulation: every prefix of every query.
    var typing: [Double] = []
    for q in fuzzQueries {
        var prefix = ""
        for ch in q.q {
            prefix.append(ch)
            let t0 = clock.now
            _ = await svc.search(prefix, context: ctx)
            typing.append(ms(clock.now - t0))
        }
    }
    typing.sort()
    print(String(format: "typing simulation: %d keystrokes, p50 %.2f ms, p95 %.2f ms, max %.2f ms",
                 typing.count, typing[typing.count / 2], typing[typing.count * 95 / 100], typing.last!))
    // Edits: upsert/rename/remove churn then search.
    for i in 0..<50 { await svc.upsert(IndexedNote(id: "churn-\(i % 5)", content: "# churn \(i)\nedit number \(i)", modified: Date())) }
    await svc.rename(from: "churn-1", to: "churn-renamed")
    await svc.remove("churn-2")
    await svc.rename(from: "nope", to: "nope2")
    let ch = await svc.search("churn", context: ctx).map(\.id)
    print("churn results: \(ch.sorted())")
    print("fuzz done")
    exit(0)
}
let indexDir = FileManager.default.temporaryDirectory.appendingPathComponent("nbm-eval-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: indexDir) }

print("notes: \(notes.count)  model: \(modelDir?.lastPathComponent ?? "none")")
let mem0 = footprintMB()

// Cold build.
var service = SearchService(indexDirectory: indexDir, modelDirectory: modelDir)
var t0 = clock.now
await service.reindexAll(notes)
let keywordReady = clock.now - t0
await service.waitUntilIdle()
let fullReady = clock.now - t0
let st = await service.status
print(String(format: "cold index: keyword-ready %.0f ms, embeddings done %.0f ms (%d/%d notes embedded)", ms(keywordReady), ms(fullReady), st.embedded, st.notes))
print(String(format: "memory footprint: before %.0f MB, after model+index %.0f MB", mem0, footprintMB()))

if let dir = modelDir, let e = { () -> Embedder? in try? Embedder(directory: dir) }() {
    let t = clock.now
    _ = try? Embedder(directory: dir)
    let loadT = clock.now - t
    let samples = ["that thing about fixing my sleep", "grocery", "what to bring on the trip next month to portugal"]
    _ = e.embedQuery("warmup")
    let t2 = clock.now
    for _ in 0..<20 { for s in samples { _ = e.embedQuery(s) } }
    print(String(format: "model: load %.0f ms, query embedding %.2f ms avg", ms(loadT), ms(clock.now - t2) / 60))
}

// Warm relaunch: same index dir, unchanged notes => no re-embedding.
service = SearchService(indexDirectory: indexDir, modelDirectory: modelDir)
t0 = clock.now
await service.reindexAll(notes)
let warm = clock.now - t0
let st2 = await service.status
print(String(format: "warm relaunch reindex: %.0f ms (pending embeddings: %d)", ms(warm), st2.pendingEmbeddings))
await service.waitUntilIdle()

func loadQueries(_ file: String) -> [Query] {
    (try? JSONDecoder().decode([Query].self, from: Data(contentsOf: fixtures.appendingPathComponent(file)))) ?? []
}

// Edge notes: CRLF line endings, and a 435k-char note whose tail must stay findable (and must not drown out others).
let edgeNotes: [IndexedNote] = [
    IndexedNote(id: "edge-crlf", content: "# Café ünïcode note\r\nline with crlf\r\nsecond crlf line about zanzibar ferries\r\n",
                modified: Date().addingTimeInterval(-40 * 86_400)),
    IndexedNote(id: "edge-long", content: "# Long review\n\n" + (0..<5000).map {
        String(format: "Line %04d: long note sample with **bold** text and an ordinary sentence for scrolling.\n", $0)
    }.joined() + "\nthe marmalade epilogue finale\nNBM_END_SENTINEL_8429\n", modified: Date().addingTimeInterval(-3 * 86_400)),
    // A pasted screenshot and nothing else: no prose to match, so it must never ride along as a semantic extra.
    IndexedNote(id: "edge-image-only", content: "![](assets/paste-20261026-021500.png)\n", modified: Date().addingTimeInterval(-1 * 86_400)),
    // The same, reference-style: the definition line is markup, not prose.
    IndexedNote(id: "edge-image-ref", content: "![][shot]\n\n[shot]: assets/paste-20261026-021501.png\n",
                modified: Date().addingTimeInterval(-1 * 86_400)),
]
var edgeAdded = false
func addEdgeNotes() async {
    guard !edgeAdded else { return }
    edgeAdded = true
    await service.setEmbedDebounce(.zero)
    let t = clock.now
    for n in edgeNotes { await service.upsert(n) }
    await service.waitUntilIdle()
    print(String(format: "edge notes indexed + embedded in %.0f ms", ms(clock.now - t)))
}
if let f = arg("--floor").flatMap(Double.init) { await service.setFloor(f, arg("--bump").flatMap(Double.init) ?? 1.0 / 3) }
if args.contains("--edge-notes") { await addEdgeNotes() }

if args.contains("--calib") {
    // Calibration for the absolute semantic floor: raw best-chunk cosine of every semantic target (tuning + holdout)
    // vs the best cosine any note gets for a query that should match nothing.
    var pos: [Double] = [], negTop: [Double] = []
    for file in ["queries.json", "queries-holdout.json"] {
        for q in loadQueries(file) where q.category == "semantic" {
            guard let expect = q.expect, let r = await service.rawSemantic(q.q, expect: expect) else { continue }
            pos.append(Double(r.sim))
            print(String(format: "pos sim %.4f z %5.2f rank %2d | top %.4f %@ | \"%@\"", r.sim, r.z, r.rank, r.top, r.topID, q.q))
        }
    }
    for q in loadQueries("queries-edge.json") where q.category == "none" {
        guard let r = await service.rawSemantic(q.q, expect: nil) else { continue }
        negTop.append(Double(r.top))
        print(String(format: "neg top %.4f z %5.2f %@ | \"%@\"", r.top, r.topZ, r.topID, q.q))
    }
    pos.sort(); negTop.sort()
    func pct(_ a: [Double], _ p: Double) -> Double { a[min(a.count - 1, Int(Double(a.count - 1) * p))] }
    print(String(format: "targets: min %.4f p5 %.4f p10 %.4f median %.4f | no-match tops: median %.4f p90 %.4f max %.4f",
                 pos[0], pct(pos, 0.05), pct(pos, 0.1), pct(pos, 0.5), pct(negTop, 0.5), pct(negTop, 0.9), negTop.last!))
    // Pick the highest floor that keeps (nearly) every target; the unknown-word bump handles most gibberish above it.
    for f in stride(from: pos[0] - 0.01, through: pos[min(pos.count - 1, pos.count / 4)], by: 0.0025) {
        print(String(format: "floor %.4f: keeps %d/%d targets, %d/%d no-match queries still above", f,
                     pos.filter { $0 >= f }.count, pos.count, negTop.filter { $0 >= f }.count, negTop.count))
    }
    exit(0)
}

if let file = arg("--probe"), let text = try? String(contentsOfFile: file, encoding: .utf8) {
    // One query per line: hit count and top hits (e.g. gibberish that should mostly return nothing).
    var withHits = 0
    let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    if args.contains("--explain") { await service.setExplain(true) }
    for q in lines {
        if args.contains("--explain") { print("=== \(q)") }
        let hits = await service.search(q, context: ctx)
        if !hits.isEmpty { withHits += 1 }
        print("\(hits.count)\t\(q)\t" + hits.prefix(3).map { "\($0.id)[\($0.matchKind.rawValue) \(String(format: "%.2f", $0.score))]" }.joined(separator: ", "))
    }
    print("\(withHits)/\(lines.count) queries returned hits")
    exit(0)
}

if let one = arg("--lines"), let ids = arg("--ids") {
    // Per-line and per-chunk raw cosine of a query against the given notes (comma-separated ids).
    if let dir = modelDir, let e = try? Embedder(directory: dir) {
        let qv = e.embedQuery(one)
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        for id in ids.split(separator: ",").map(String.init) {
            guard let d = await service.docs[id] else { continue }
            let dim = qv.count
            let chunkSims = (0..<(d.vectors.count / dim)).map { c in dot(Array(d.vectors[c * dim..<(c + 1) * dim]), qv) }
            print("== \(id) chunks: " + chunkSims.map { String(format: "%.4f", $0) }.joined(separator: " "))
            let lines = d.content.split(whereSeparator: \.isNewline).map(String.init).filter { $0.count > 3 }
            for (l, v) in zip(lines, e.embedDocuments(lines)) { print(String(format: "  %.4f  %@", dot(v, qv), String(l.prefix(100)))) }
        }
    }
    exit(0)
}

if let one = arg("--q") {
    if args.contains("--edge") { await addEdgeNotes() }
    if args.contains("--explain") {
        await service.setExplain(true)
        _ = await service.search(one, context: ctx)
        await service.setExplain(false)
    }
    let t = clock.now
    let hits = await service.search(one, context: ctx)
    print(String(format: "%.2f ms", ms(clock.now - t)))
    for (i, h) in hits.prefix(10).enumerated() {
        print(String(format: "%2d. %.3f [%@] %@ — %@  (%@)", i + 1, h.score, h.matchKind.rawValue, h.title, h.snippet, h.id))
    }
    if let r = await service.rawSemantic(one, expect: nil) { print(String(format: "raw top cosine %.4f (%@)", r.top, r.topID)) }
    exit(0)
}

/// Runs one query file. Positives (expect) count toward R@1/R@3/MRR; negatives ("none": must return nothing,
/// "reject": `reject` must not be in the top `top`, `allow`: every hit must be one of these) count toward the
/// false-positive rate.
func runSet(_ file: String) async -> [Double] {
    let set = loadQueries(file)
    guard !set.isEmpty else { return [] }
    if set.contains(where: { $0.expect?.hasPrefix("edge-") == true }) { await addEdgeNotes() }
    print("\n== \(file) (\(set.count) queries)")
    var byCat: [String: (n: Int, r1: Int, r3: Int, rr: Double)] = [:]
    var failures: [String] = []
    var latencies: [Double] = []
    var neg = (n: 0, fp: 0)
    for q in set {
        let t = clock.now
        let hits = await service.search(q.q, context: ctx)
        latencies.append(ms(clock.now - t))
        let top = hits.prefix(3).map { "\($0.id)[\($0.matchKind.rawValue) \(String(format: "%.2f", $0.score))]" }.joined(separator: ", ")
        if let expect = q.expect {
            let rank = (hits.firstIndex { $0.id == expect }).map { $0 + 1 }
            var c = byCat[q.category] ?? (0, 0, 0, 0)
            c.n += 1
            if rank == 1 { c.r1 += 1 }
            if let r = rank, r <= 3 { c.r3 += 1 }
            c.rr += rank.map { 1 / Double($0) } ?? 0
            byCat[q.category] = c
            if args.contains("--raw"), q.category == "semantic", let r = await service.rawSemantic(q.q, expect: expect) {
                print(String(format: "  raw-sem rank %2d  sim %.4f  z %.2f  top %.4f (%@)  \"%@\"", r.rank, r.sim, r.z, r.top, r.topID, q.q))
            }
            if rank != 1 {
                failures.append("  [\(q.category)] \"\(q.q)\" -> \(expect) rank \(rank.map(String.init) ?? "miss") | top: \(top)")
            } else if verbose {
                print("  ok [\(q.category)] \"\(q.q)\" | \(hits[0].matchKind.rawValue) | \(hits[0].snippet.prefix(90))")
            }
            if let h = hits.first(where: { $0.id == expect }), h.id == "edge-crlf",
               h.title != "Café ünïcode note" || h.snippet.contains(where: \.isNewline) || h.snippet.isEmpty {
                failures.append("  [crlf] bad title/snippet: \(h.title.debugDescription) / \(h.snippet.debugDescription)")
            }
        } else {
            neg.n += 1
            let n = q.top ?? 0
            let bad = q.reject.map { r in hits.prefix(n).contains { $0.id == r } }
                ?? q.allow.map { ok in hits.contains { !ok.contains($0.id) } } ?? q.max.map { hits.count > $0 } ?? !hits.isEmpty
            if bad {
                neg.fp += 1
                failures.append("  [\(q.category)] FALSE POSITIVE \"\(q.q)\" | top: \(top)")
            } else if verbose {
                print("  ok [\(q.category)] \"\(q.q)\" | \(hits.count) hits | top: \(top)")
            }
        }
    }
    print("category        n   R@1    R@3    MRR")
    var tot = (n: 0, r1: 0, r3: 0, rr: 0.0)
    for (cat, c) in byCat.sorted(by: { $0.key < $1.key }) {
        print(String(format: "%-14@ %3d  %5.1f%%  %5.1f%%  %.3f", cat as NSString, c.n, 100 * Double(c.r1) / Double(c.n), 100 * Double(c.r3) / Double(c.n), c.rr / Double(c.n)))
        tot = (tot.n + c.n, tot.r1 + c.r1, tot.r3 + c.r3, tot.rr + c.rr)
    }
    if tot.n > 0 {
        print(String(format: "%-14@ %3d  %5.1f%%  %5.1f%%  %.3f", "overall" as NSString, tot.n, 100 * Double(tot.r1) / Double(tot.n), 100 * Double(tot.r3) / Double(tot.n), tot.rr / Double(tot.n)))
    }
    if neg.n > 0 {
        print(String(format: "negatives      %3d  false positives %d (%.1f%%)", neg.n, neg.fp, 100 * Double(neg.fp) / Double(neg.n)))
    }
    let sorted = latencies.sorted()
    print(String(format: "query latency (incl. query embedding): p50 %.2f ms, p95 %.2f ms, max %.2f ms",
                 sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 95 / 100)], sorted.last!))
    if !failures.isEmpty { print("not #1 / failing:"); failures.forEach { print($0) } }
    return latencies
}

let sets = arg("--queries").map { [$0] } ?? ["queries.json", "queries-holdout.json", "queries-edge.json", "queries-negative-holdout.json",
                                              "queries-multiterm.json"]
var queries: [Query] = []
for file in sets {
    _ = await runSet(file)
    queries += loadQueries(file)
}

// Empty query = recents: pins in pin order, then last touched (max of file mtime and last opened) newest first;
// frecency only breaks near-ties.
do {
    let now = Date()
    let byAge = notes.sorted { $0.modified > $1.modified }.map(\.id)
    let (old1, old2, old3) = (byAge[byAge.count - 1], byAge[byAge.count - 2], byAge[byAge.count - 3])
    let (tieA, tieB) = (byAge[byAge.count - 4], byAge[byAge.count - 5])
    let rc = RankingContext(
        pins: [byAge[10], byAge[3]],
        frecency: [old2: 40, byAge[0]: 0, tieA: 0.2, tieB: 6],
        lastOpened: [old1: now.addingTimeInterval(-30), old2: now.addingTimeInterval(-12 * 60), old3: now.addingTimeInterval(-3600),
                     tieA: now.addingTimeInterval(-7200), tieB: now.addingTimeInterval(-7210)])
    let got = await service.search("", context: rc).map(\.id)
    let rest = byAge.filter { ![byAge[10], byAge[3], old1, old2, old3, tieA, tieB].contains($0) }
    // Everything opened in the last couple of hours comes before untouched notes (fixture mtimes are older).
    let want = [byAge[10], byAge[3], old1, old2, old3, tieB, tieA]
    let restSet = Set(rest)
    let ok = notes.allSatisfy({ now.timeIntervalSince($0.modified) > 7300 }) && Array(got.prefix(want.count)) == want
        && got.filter(restSet.contains) == Array(rest.prefix(got.filter(restSet.contains).count))
    print("\nrecents order (pins, then last touched, frecency only on near-ties): \(ok ? "ok" : "FAIL")")
    if !ok { print("  want \(want.prefix(9))\n  got  \(got.prefix(9))") }
}

// Titles and snippets: plain text the way the editor renders it; markup lines are never a title or snippet, and a
// formatted first line doesn't come back as the snippet.
do {
    let titles: [(String, String)] = [
        ("![onboarding flow diagram quokka][im]\n\n[im]: assets/lit.png", "Untitled"),
        ("![p][im]\n\n[im]: assets/lit.png\nreal text", "real text"),
        ("![shortcutalt] leading shortcut", "leading shortcut"),
        ("![a [b] c](assets/lit.png) nested alt", "nested alt"),
        ("Fish &amp; Chips &#38; more &#x26; done &bogus;", "Fish & Chips & more & done &bogus;"),
        ("*![p](assets/x.png) words end*", "words end"),
        ("**Bold** title with `code` and [a link](https://x.y)", "Bold title with code and a link"),
        ("~~struck~~ _em_ \\*literal\\* \\&amp;", "struck em *literal* &amp;"),
        ("* * *\n```\n# real", "real"),
        ("[^1]: a footnote is prose", "[^1]: a footnote is prose"),
        ("\n\n- \n#\n---\n> \nReal title here", "Real title here"),
        ("###\r\n> ##\n#hashtag title", "#hashtag title"),
        ("- #\n> - [ ]\n## #\n- *\n1. #\nReal title candidate", "Real title candidate"),
        ("**\n__\n~~\n`\nReal after emphasis-only lines", "Real after emphasis-only lines"),
        ("- ## Real in list", "Real in list"),
        ("1. # Numbered heading item\n", "Numbered heading item"),
        ("- [ ] Real task", "Real task"),
        ("- #hashtag in list", "#hashtag in list"),
    ]
    var bad = titles.filter { NoteTitle.from($0.0) != $0.1 }.map { "title \($0.0.debugDescription): \(NoteTitle.from($0.0).debugDescription)" }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nbm-titles-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let svc = SearchService(indexDirectory: dir, modelDirectory: nil)
    let snippets: [(String, String)] = [
        ("**Bold** title with `code` and [a link](https://x.y)\nsecond line", "second line"),
        ("1. numbered title\nbody line", "body line"),
        ("Title\n#\n######\nbody after empty headings", "body after empty headings"),
        ("~~struck~~ _em_ \\*literal\\*\nnext", "next"),
        ("# Title\n[im]: assets/lit.png\n![][im]\nafter the image", "after the image"),
    ]
    await svc.reindexAll(snippets.enumerated().map { IndexedNote(id: "s\($0.offset)", content: $0.element.0, modified: Date()) })
    for (i, (content, want)) in snippets.enumerated() {
        guard let doc = await svc.docs["s\(i)"] else { continue }
        let got = await svc.preview(doc)
        if got != want { bad.append("snippet \(content.debugDescription): \(got.debugDescription)") }
    }
    let prose = ["![](assets/x.png)\n", "![][im]\n\n[im]: assets/x.png\n"].map { Text.proseLetters($0, cap: 32) }
    if prose != [0, 0] { bad.append("image-only prose letters (inline, reference): \(prose)") }
    print("titles/snippets (plain text, markup lines skipped): \(bad.isEmpty ? "ok" : "FAIL")")
    bad.forEach { print("  \($0)") }
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

if modelDir != nil, !args.contains("--no-incremental") {
    // Re-embedding after edits: only chunks whose text changed may go through the model.
    await addEdgeNotes()
    await service.setEmbedDebounce(.zero)
    func edit(_ id: String, _ change: (String) -> String) async -> (Int, Double) {
        let before = await service.chunksEmbedded
        let content = await service.docs[id]!.content
        let t = clock.now
        await service.upsert(IndexedNote(id: id, content: change(content), modified: Date()))
        await service.flushDeferredUpserts()  // (a long note's keyword re-index otherwise waits for a pause in saves)
        if id == "edge-long" { print(String(format: "upsert (keyword index) of the 435k-char note: %.0f ms", ms(clock.now - t))) }
        await service.waitUntilIdle()
        return (await service.chunksEmbedded - before, ms(clock.now - t))
    }
    let tail = await edit("edge-long") { $0 + "typed at the end\n" }
    let head = await edit("edge-long") { $0.replacingOccurrences(of: "Line 0003:", with: "Line 0003 (edited):") }
    let small = await edit("lisbon-trip") { $0 + "\n- one more thing\n" }
    print(String(format: "\nincremental re-embed (chunks computed / ms): long note tail edit %d / %.0f, long note head edit %d / %.0f, small note edit %d / %.0f",
                 tail.0, tail.1, head.0, head.1, small.0, small.1))
    let c0 = cpuSeconds()
    try? await Task.sleep(for: .seconds(3))
    print(String(format: "idle after indexing: %.1f ms CPU over 3 s", (cpuSeconds() - c0) * 1000))
}
// Scale test: N synthetic notes built from fixture lines, random vectors (3 chunks each).
let scale = Int(arg("--scale") ?? "5000") ?? 5000
if scale > 0, !notes.isEmpty {
    var rng = SystemRandomNumberGenerator()
    let lines = notes.flatMap { $0.content.split(separator: "\n").map(String.init) }.filter { $0.count > 3 }
    let synth = (0..<scale).map { i in
        IndexedNote(id: "synth-\(i)", content: (0..<Int.random(in: 3...40, using: &rng)).map { _ in lines.randomElement(using: &rng)! }.joined(separator: "\n"),
                    modified: Date().addingTimeInterval(-Double.random(in: 0...(400 * 86_400), using: &rng)))
    }
    let bigDir = FileManager.default.temporaryDirectory.appendingPathComponent("nbm-eval-big-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: bigDir) }
    let big = SearchService(indexDirectory: bigDir, modelDirectory: nil)
    let tb = clock.now
    await big.reindexAll(synth + notes)
    print(String(format: "\nscale: %d notes keyword index build %.0f ms", synth.count + notes.count, ms(clock.now - tb)))
    var kw: [Double] = []
    for q in queries {
        let t = clock.now
        _ = await big.search(q.q, context: ctx)
        kw.append(ms(clock.now - t))
        if verbose, kw.last! > 12 { print(String(format: "  slow keyword query %.1f ms: %@", kw.last!, q.q)) }
    }
    kw.sort()
    print(String(format: "scale keyword-only latency: p50 %.2f ms, p95 %.2f ms, max %.2f ms", kw[kw.count / 2], kw[kw.count * 95 / 100], kw.last!))
    if let dir = modelDir, let e = try? Embedder(directory: dir) {
        await big.injectRandomVectors(dim: e.dimension, chunksPerNote: 3)
        await big.forceEmbedder(e)
        var all: [Double] = []
        for q in queries { let t = clock.now; _ = await big.search(q.q, context: ctx); all.append(ms(clock.now - t)) }
        all.sort()
        print(String(format: "scale hybrid latency (query embed + %d vectors): p50 %.2f ms, p95 %.2f ms, max %.2f ms",
                     (synth.count + notes.count) * 3, all[all.count / 2], all[all.count * 95 / 100], all.last!))
    }
}
