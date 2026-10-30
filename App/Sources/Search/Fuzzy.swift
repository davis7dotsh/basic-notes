import Foundation

/// Typo-tolerant fuzzy matching of query tokens against title words.
nonisolated enum Fuzzy {
    /// Shortest query word that may carry a typo when matched against note bodies or word prefixes. Four-letter words
    /// are one edit away from dozens of others ("fart": part, fast, art...), so there it mostly matches noise; a
    /// whole title word ("tmxu" -> "tmux") is still allowed one edit.
    static let minTypoLength = 5

    struct Word: Sendable {
        var folded: [UInt8]
        /// UTF-16 range in the title
        var start: Int
        var end: Int
    }

    static func words(of title: String) -> [Word] {
        var out: [Word] = []
        var cur: [UInt8] = []
        var start = 0, pos = 0
        for sc in title.unicodeScalars {
            let w = sc.properties.isAlphabetic || sc.properties.numericType != nil || sc == "_"
            let len = sc.value > 0xFFFF ? 2 : 1
            if w {
                if cur.isEmpty { start = pos }
                cur += Text.foldUTF8(String(sc))
            } else if !cur.isEmpty {
                out.append(Word(folded: cur, start: start, end: pos)); cur = []
            }
            pos += len
        }
        if !cur.isEmpty { out.append(Word(folded: cur, start: start, end: pos)) }
        return out
    }

    /// Score of one query token against one word in [0,1] and the matched UTF-16 length from the word start
    /// (nil = whole word).
    static func match(_ t: [UInt8], _ w: [UInt8], isLast: Bool) -> (score: Double, prefixLen: Int?) {
        if t.isEmpty || w.isEmpty { return (0, nil) }
        if t == w { return (1, nil) }
        let tn = t.count, wn = w.count
        if tn < wn, w.starts(with: t) {
            if tn == 1 { return (isLast ? 0.35 : 0.15, 1) }
            return (0.7 + 0.3 * Double(tn) / Double(wn), tn)
        }
        let k = tn >= 8 ? 2 : (tn >= 4 ? 1 : 0)
        var best = 0.0
        if k > 0, t[0] == w[0] || (tn > 1 && wn > 1 && t[0] == w[1] && t[1] == w[0]) {
            let d = Text.editDistance(t, w, limit: k)
            if d <= k { best = d == 1 ? 0.78 : 0.62 }
            // Typo while still typing: compare against the word's prefix of the same length.
            if best == 0, isLast, wn > tn, tn >= minTypoLength {
                let dp = Text.editDistance(t, w, bCount: tn, limit: k)
                if dp <= k { best = 0.6 - 0.1 * Double(dp - 1) }
            }
        }
        // Abbreviation-style subsequence ("tmx" -> "tmux", "grcry" -> "grocery") must cover most of the word.
        if best == 0, tn >= 3, 3 * tn >= 2 * wn, t[0] == w[0], isSubsequence(t, of: w) {
            best = 0.5 * (Double(tn) / Double(wn)).squareRoot()
        }
        return (best, nil)
    }

    private static func isSubsequence(_ t: [UInt8], of w: [UInt8]) -> Bool {
        var i = 0
        for c in w where i < t.count && c == t[i] { i += 1 }
        return i == t.count
    }

    /// Title score in [0,1] for weighted query tokens, plus UTF-16 highlight ranges into the title.
    static func score(tokens: [(bytes: [UInt8], weight: Double)], lastIsPartial: Bool, words: [Word]) -> (Double, [[Int]]) {
        guard !tokens.isEmpty, !words.isEmpty else { return (0, []) }
        var total = 0.0, weightSum = 0.0, matchedWeight = 0.0
        var ranges: [[Int]] = []
        var usedWords = Set<Int>()
        for (ti, tok) in tokens.enumerated() {
            let isLast = lastIsPartial && ti == tokens.count - 1
            var best = 0.0, bestWord = -1, bestPrefix: Int?
            for (wi, w) in words.enumerated() {
                let (s, p) = match(tok.bytes, w.folded, isLast: isLast)
                if s > best || (s == best && s > 0 && usedWords.contains(bestWord) && !usedWords.contains(wi)) {
                    best = s; bestWord = wi; bestPrefix = p
                }
            }
            total += best * tok.weight
            weightSum += tok.weight
            if best >= 0.3, bestWord >= 0 {
                matchedWeight += tok.weight
                usedWords.insert(bestWord)
                let w = words[bestWord]
                ranges.append([w.start, bestPrefix.map { min(w.end, w.start + $0) } ?? w.end])
            }
        }
        guard weightSum > 0 else { return (0, []) }
        var s = total / weightSum
        // Missing query words hurt more than typos ("food shopping" vs "Mattress shopping").
        s *= (matchedWeight / weightSum).squareRoot()
        // Prefer titles mostly covered by the query ("Groceries" over "Groceries for the cabin trip").
        let coverage = Double(usedWords.count) / Double(words.count)
        s *= 0.85 + 0.15 * coverage
        return (s, ranges)
    }
}
