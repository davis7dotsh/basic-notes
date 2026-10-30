import Foundation

/// BERT uncased tokenizer (BasicTokenizer + WordPiece), matching HF `BertTokenizer(do_lower_case=True)`.
nonisolated struct WordPieceTokenizer: Sendable {
    let vocab: [String: Int32]
    let cls: Int32, sep: Int32, unk: Int32

    init(vocabURL: URL) throws {
        let text = try String(contentsOf: vocabURL, encoding: .utf8)
        var v: [String: Int32] = [:]
        v.reserveCapacity(32_000)
        var i: Int32 = 0
        text.enumerateLines { line, _ in
            if v[line] == nil { v[line] = i }
            i += 1
        }
        guard let cls = v["[CLS]"], let sep = v["[SEP]"], let unk = v["[UNK]"] else {
            throw SafeTensors.LoadError.format("vocab missing special tokens")
        }
        self.vocab = v
        self.cls = cls; self.sep = sep; self.unk = unk
    }

    /// Token ids including [CLS] ... [SEP], truncated to `maxTokens`.
    func encode(_ text: String, maxTokens: Int) -> [Int32] {
        var ids: [Int32] = [cls]
        let budget = max(2, maxTokens) - 1
        for word in basicTokens(text) {
            for id in wordPiece(word) {
                if ids.count >= budget { ids.append(sep); return ids }
                ids.append(id)
            }
        }
        ids.append(sep)
        return ids
    }

    /// Number of word pieces (without specials). Cheap enough for chunking decisions.
    func count(_ text: String) -> Int { basicTokens(text).reduce(0) { $0 + wordPiece($1).count } }

    // MARK: BasicTokenizer

    func basicTokens(_ text: String) -> [String] {
        var words: [String] = []
        var cur = String.UnicodeScalarView()
        func flush() { if !cur.isEmpty { words.append(String(cur)); cur.removeAll(keepingCapacity: true) } }
        // Lowercase + NFD + strip combining marks (HF strip_accents default when lowercasing).
        let normalized = text.lowercased().decomposedStringWithCanonicalMapping
        for s in normalized.unicodeScalars {
            let v = s.value
            if v == 0 || v == 0xFFFD { continue }
            let props = s.properties
            if props.generalCategory == .nonspacingMark { continue }
            if s == " " || s == "\t" || s == "\n" || s == "\r" || props.generalCategory == .spaceSeparator { flush(); continue }
            if props.generalCategory == .control || props.generalCategory == .format { continue }
            if Self.isPunctuation(s) || Self.isCJK(v) {
                flush()
                words.append(String(s))
                continue
            }
            cur.append(s)
        }
        flush()
        return words
    }

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    private static func isCJK(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
            || (0x2A700...0x2B73F).contains(v) || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }

    // MARK: WordPiece

    func wordPiece(_ word: String) -> [Int32] {
        let chars = Array(word.unicodeScalars)
        if chars.count > 100 { return [unk] }
        if let id = vocab[word] { return [id] }
        var out: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: Int32?
            while start < end {
                var piece = String(String.UnicodeScalarView(chars[start..<end]))
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [unk] }
            out.append(id)
            start = end
        }
        return out
    }
}
