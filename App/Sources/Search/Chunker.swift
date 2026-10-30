import Foundation

/// Splits a note into embedding chunks along headings/paragraphs, each <= `maxTokens` word pieces.
nonisolated enum Chunker {
    struct Chunk: Sendable {
        /// UTF-16 range in the note content.
        var start: Int
        var end: Int
        /// Text to embed (the chunk, prefixed with the note title when the chunk doesn't contain it).
        var text: String
    }

    static let maxChunks = 48
    /// Only this much of a note (UTF-16 units) is chunked for embedding; `maxChunks` usually ends it sooner. Keyword
    /// search always covers the whole note, so this bounds semantic work, not findability.
    static let maxInputChars = 100_000

    /// Content chunks plus a title-only chunk (titles are how vague queries are often phrased).
    static func chunks(content full: String, title: String, tokenizer: WordPieceTokenizer, maxTokens: Int = 200) -> [Chunk] {
        let content = prefix(full)
        guard content.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        var r = contentChunks(content: content, title: title, tokenizer: tokenizer, maxTokens: maxTokens)
        if !r.isEmpty, title != "Untitled", title.count < content.count {
            r.append(Chunk(start: 0, end: 0, text: title))
        }
        return r
    }

    /// The text embedded for the chunk at UTF-16 [start, end): the title for the title chunk (0, 0), else the body,
    /// prefixed with the title when the chunk doesn't contain it. Lets callers recompute chunk texts from stored ranges.
    static func chunkText(content: String, title: String, start: Int, end: Int) -> String? {
        if start == 0 && end == 0 { return title }
        guard start >= 0, start < end, end <= content.utf16.count else { return nil }
        let a = String.Index(utf16Offset: start, in: content), b = String.Index(utf16Offset: end, in: content)
        let body = String(content[a..<b])
        return start == 0 || body.contains(title) ? body : "\(title)\n\(body)"
    }

    private static func prefix(_ s: String) -> String {
        guard s.utf16.count > maxInputChars else { return s }
        let u = s.unicodeScalars
        var i = u.startIndex, n = 0
        while i != u.endIndex, n + u[i].utf16.count <= maxInputChars { n += u[i].utf16.count; i = u.index(after: i) }
        return String(u[..<i])
    }

    private static func contentChunks(content: String, title: String, tokenizer: WordPieceTokenizer, maxTokens: Int) -> [Chunk] {
        let total = content.utf16.count
        guard total > 0 else { return [] }
        if tokenizer.count(content) <= maxTokens { return [Chunk(start: 0, end: total, text: content)] }

        // Blocks: paragraphs separated by blank lines; headings start a new block; fenced code stays together.
        var blocks: [(start: Int, end: Int, text: Substring)] = []
        var blockStart: Int?
        var blockEnd = 0
        var inFence = false
        func close() {
            if let s = blockStart, blockEnd > s {
                let a = String.Index(utf16Offset: s, in: content), b = String.Index(utf16Offset: blockEnd, in: content)
                blocks.append((s, blockEnd, content[a..<b]))
            }
            blockStart = nil
        }
        for line in Text.lines(content[...]) {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if !inFence && trimmed.isEmpty {
                close()
            } else {
                if !inFence && trimmed.hasPrefix("#") { close() }
                if blockStart == nil { blockStart = line.start }
                blockEnd = line.end
            }
        }
        close()

        // Pieces: blocks, with oversized blocks split by line and then by hard token windows.
        var pieces: [(start: Int, end: Int, tokens: Int)] = []
        for b in blocks {
            let n = tokenizer.count(String(b.text))
            if n <= maxTokens { pieces.append((b.start, b.end, n)); continue }
            for l in Text.lines(b.text) {
                let line = l.text, lineStart = b.start + l.start, len = l.end - l.start
                let ln = tokenizer.count(String(line))
                if ln <= maxTokens {
                    if len > 0 { pieces.append((lineStart, lineStart + len, ln)) }
                } else {
                    // Hard split long lines into ~maxTokens windows by words.
                    var wStart = lineStart, acc = 0, cursor = lineStart
                    for word in line.split(separator: " ", omittingEmptySubsequences: false) {
                        let wl = word.utf16.count
                        let wt = max(1, tokenizer.count(String(word)))
                        if acc + wt > maxTokens, cursor > wStart {
                            pieces.append((wStart, cursor, acc)); wStart = cursor; acc = 0
                        }
                        acc += wt; cursor += wl + 1
                    }
                    if lineStart + len > wStart { pieces.append((wStart, lineStart + len, acc)) }
                }
            }
        }

        // Greedily pack pieces into chunks.
        var out: [Chunk] = []
        var cs: Int?, ce = 0, ct = 0
        func emit() {
            guard let s = cs, ce > s, let text = chunkText(content: content, title: title, start: s, end: ce) else { return }
            out.append(Chunk(start: s, end: ce, text: text))
            cs = nil; ct = 0
        }
        for p in pieces {
            if cs != nil, ct + p.tokens > maxTokens { emit() }
            if out.count >= maxChunks { break }
            if cs == nil { cs = p.start }
            ce = p.end; ct += p.tokens
        }
        if out.count < maxChunks { emit() }
        return out
    }
}
