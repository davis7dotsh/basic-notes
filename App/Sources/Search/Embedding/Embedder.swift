import Foundation
import Synchronization

/// On-device sentence embedder: WordPiece tokenizer + BERT encoder + pooling, configured by `manifest.json`
/// (written by scripts/fetch-model.sh) next to `config.json`, `vocab.txt`, `model.safetensors`.
nonisolated final class Embedder: Sendable {
    struct Manifest: Codable, Sendable {
        var id: String
        var pooling: String  // "cls" | "mean"
        var queryPrefix: String
        var documentPrefix: String
        /// Typical cosine of an unrelated / a clearly related query-passage pair; used to calibrate
        /// semantic relevance when the corpus is too small for per-query statistics.
        var simLow: Double?
        var simHigh: Double?
        /// Raw cosine below which a query-passage pair is not semantic evidence (calibrated with SearchEval --calib).
        var simFloor: Double?
    }

    let manifest: Manifest
    let tokenizer: WordPieceTokenizer
    let encoder: BertEncoder
    var dimension: Int { encoder.config.hidden }
    /// Max tokens per document chunk (incl. specials).
    let chunkTokens = 256
    let queryTokens = 64

    init(directory: URL) throws {
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        tokenizer = try WordPieceTokenizer(vocabURL: directory.appendingPathComponent("vocab.txt"))
        encoder = try BertEncoder(directory: directory)
    }

    /// Loaded models by directory, kept for the process: the model is the same for every notes folder, so a folder
    /// switch (a new SearchService) reuses it instead of reloading.
    private static let loaded = Mutex<[String: Embedder]>([:])

    /// The model in `directory`, if already loaded by any service.
    static func cached(_ directory: URL) -> Embedder? { loaded.withLock { $0[directory.standardizedFileURL.path] } }

    /// The shared model in `directory`, loading it on first use (blocking; call off the main thread). nil if it can't load.
    static func shared(_ directory: URL) -> Embedder? {
        if let e = cached(directory) { return e }
        guard let e = try? Embedder(directory: directory) else { return nil }
        return loaded.withLock { $0[directory.standardizedFileURL.path, default: e] }
    }

    /// First model directory (containing manifest.json) inside the app bundle's Models folder.
    static func bundledModelDirectory(bundle: Bundle = .main) -> URL? {
        guard let models = bundle.resourceURL?.appendingPathComponent("Models") else { return nil }
        return firstModel(in: models)
    }

    static func firstModel(in dir: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) { return dir }
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return subs.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }

    private var pooling: BertEncoder.Pooling { manifest.pooling == "mean" ? .mean : .cls }

    func embedQuery(_ text: String) -> [Float] {
        return encoder.embed([tokenizer.encode(manifest.queryPrefix + text, maxTokens: queryTokens)], pooling: pooling)[0]
    }

    /// Embeds document chunks in packed batches (~2k tokens per forward pass).
    func embedDocuments(_ texts: [String]) -> [[Float]] {
        let seqs = texts.map { tokenizer.encode(manifest.documentPrefix + $0, maxTokens: chunkTokens) }
        var out: [[Float]] = []
        out.reserveCapacity(seqs.count)
        var batch: [[Int32]] = []
        var tokens = 0
        for s in seqs {
            if tokens + s.count > 2048, !batch.isEmpty {
                out += encoder.embed(batch, pooling: pooling)
                batch.removeAll(keepingCapacity: true); tokens = 0
            }
            batch.append(s); tokens += s.count
        }
        if !batch.isEmpty { out += encoder.embed(batch, pooling: pooling) }
        return out
    }
}
