import Foundation

/// Text helpers for indexing/ranking. "Folding" lowercases while preserving encoded length, so offsets in a
/// folded buffer are valid in the original string.
nonisolated enum Text {
    /// Folded UTF-8 bytes (same byte length as `s.utf8`).
    static func foldUTF8(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            if scalar.isASCII {
                var b = UInt8(scalar.value)
                if b >= 65 && b <= 90 { b += 32 }
                out.append(b)
            } else {
                let orig = Array(String(scalar).utf8)
                let low = Array(scalar.properties.lowercaseMapping.utf8)
                out += low.count == orig.count ? low : orig
            }
        }
        return out
    }

    /// Folded UTF-16 code units (same length as `s.utf16`).
    static func foldUTF16(_ s: String) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(s.utf16.count)
        for scalar in s.unicodeScalars {
            if scalar.isASCII {
                var b = UInt16(scalar.value)
                if b >= 65 && b <= 90 { b += 32 }
                out.append(b)
            } else {
                let orig = Array(String(scalar).utf16)
                let low = Array(scalar.properties.lowercaseMapping.utf16)
                out += low.count == orig.count ? low : orig
            }
        }
        return out
    }

    static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || b == 95 || b >= 0x80
    }

    static func isWordUnit(_ u: UInt16) -> Bool {
        (u >= 48 && u <= 57) || (u >= 97 && u <= 122) || (u >= 65 && u <= 90) || u == 95 || u >= 0x80
    }

    /// Lowercased word tokens (letters/digits/underscore runs; non-ASCII letters included).
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for sc in s.unicodeScalars {
            if sc.properties.isAlphabetic || sc.properties.numericType != nil || sc == "_" {
                cur.append(sc)
            } else if !cur.isEmpty {
                out.append(String(cur).lowercased()); cur.removeAll(keepingCapacity: true)
            }
        }
        if !cur.isEmpty { out.append(String(cur).lowercased()) }
        return out
    }

    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "am", "an", "and", "any", "are", "as", "at", "be", "because",
        "been", "before", "being", "between", "both", "but", "by", "can", "could", "did", "do", "does", "doing", "down",
        "during", "each", "few", "for", "from", "further", "had", "has", "have", "having", "he", "her", "here", "hers",
        "him", "his", "how", "i", "if", "in", "into", "is", "it", "its", "just", "me", "more", "most", "my", "myself",
        "no", "nor", "not", "of", "off", "on", "once", "only", "or", "other", "our", "out", "over", "own", "same", "she",
        "should", "so", "some", "such", "than", "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "those", "through", "to", "too", "under", "until", "up", "very", "was", "we", "were", "what", "when",
        "where", "which", "while", "who", "whom", "why", "will", "with", "would", "you", "your", "thing", "things",
        "stuff", "note", "notes", "something", "somewhere", "remember", "wrote", "write", "written", "ve", "s", "t", "d",
        "ll", "m", "re", "im", "ive", "dont", "get", "got", "like", "one", "think",
    ]

    /// Crude suffix stripping for lexical matching ("recipes" -> "recipe", "running" -> "runn").
    static func stem(_ w: String) -> String {
        for suf in ["ings", "ing", "ies", "ied", "es", "ed", "ly", "s"] where w.count > suf.count + 2 && w.hasSuffix(suf) {
            return String(w.dropLast(suf.count))
        }
        return w
    }

    /// Optimal-string-alignment (Damerau-Levenshtein) distance between `a` and the first `bCount` bytes of `b`
    /// (default: all), with early exit above `limit`. Allocation-free for short words.
    static func editDistance(_ a: [UInt8], _ b: [UInt8], bCount: Int? = nil, limit: Int) -> Int {
        let n = a.count, m = min(bCount ?? b.count, b.count)
        if abs(n - m) > limit { return limit + 1 }
        if n == 0 { return m }
        if m == 0 { return n }
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * (m + 1)) { buf in
            var prev2 = buf.baseAddress!, prev = prev2 + (m + 1), cur = prev + (m + 1)
            for j in 0...m { prev[j] = j; prev2[j] = 0 }
            for i in 1...n {
                cur[0] = i
                var rowMin = i
                for j in 1...m {
                    let cost = a[i - 1] == b[j - 1] ? 0 : 1
                    var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                    if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, prev2[j - 2] + 1) }
                    cur[j] = v
                    rowMin = min(rowMin, v)
                }
                if rowMin > limit { return limit + 1 }
                (prev2, prev, cur) = (prev, cur, prev2)
            }
            return prev[m]
        }
    }

    /// Letters of readable text in `s`, counted up to `cap`. Link/image destinations (`](assets/x.png)`, `][label]`)
    /// and markup lines (link reference definitions like `[img]: assets/x.png`, fences, rules) don't count, so a pasted
    /// screenshot alone has none in either image form. Non-ASCII scalars count as letters.
    static func proseLetters(_ s: String, cap: Int) -> Int {
        var n = 0
        var rest = Substring(s)
        while n < cap, !rest.isEmpty {
            let end = rest.utf8.firstIndex(of: 10) ?? rest.endIndex
            let line = rest[..<end]
            if !NoteTitle.isMarkup(line) { n += letters(line, cap: cap - n) }
            rest = end == rest.endIndex ? "" : rest[rest.utf8.index(after: end)...]
        }
        return n
    }

    private static func letters(_ line: Substring, cap: Int) -> Int {
        var line = line
        return line.withUTF8 { buf in
            var n = 0, i = 0
            while i < buf.count, n < cap {
                let b = buf[i]
                if b == 93, i + 1 < buf.count, buf[i + 1] == 40 {  // "](" ... ")" (balanced parens)
                    var depth = 0
                    i += 1
                    while i < buf.count {
                        if buf[i] == 40 { depth += 1 } else if buf[i] == 41 { depth -= 1; if depth == 0 { break } }
                        i += 1
                    }
                } else if b == 93, i + 1 < buf.count, buf[i + 1] == 91 {  // "][label]": a reference, not text
                    i += 1
                    while i < buf.count, buf[i] != 93 { i += 1 }
                } else if (b | 0x20) >= 97 && (b | 0x20) <= 122 || b >= 0xC0 {
                    n += 1
                }
                i += 1
            }
            return n
        }
    }

    /// Stable 64-bit FNV-1a content hash.
    static func hash(_ s: String) -> String {
        String(hash64(s), radix: 16) + ":" + String(s.utf8.count)
    }

    static func hash64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// Lines of `s` with their UTF-16 [start, end) offsets (relative to `s`), terminators excluded.
    /// Handles "\n", "\r\n" and lone "\r"; same shape as `split(separator: "\n", omittingEmptySubsequences: false)`.
    static func lines(_ s: Substring) -> [(text: Substring, start: Int, end: Int)] {
        var out: [(Substring, Int, Int)] = []
        let u = s.unicodeScalars
        var i = u.startIndex, lineStart = i, off = 0, startOff = 0
        while i != u.endIndex {
            let c = u[i].value
            guard c == 10 || c == 13 else { off += u[i].utf16.count; i = u.index(after: i); continue }
            out.append((Substring(u[lineStart..<i]), startOff, off))
            i = u.index(after: i); off += 1
            if c == 13, i != u.endIndex, u[i].value == 10 { i = u.index(after: i); off += 1 }
            lineStart = i; startOff = off
        }
        out.append((Substring(u[lineStart..<i]), startOff, off))
        return out
    }

    /// Strips leading Markdown block markers for display ("## ", "- [ ] ", "> ", "1. ").
    static func displayLine(_ line: Substring) -> Substring {
        var s = line.drop { $0 == " " || $0 == "\t" }
        // A bare `#`…`######` line is an empty heading (CommonMark): nothing to show.
        let hashes = s.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), s.dropFirst(hashes).allSatisfy({ $0 == " " || $0 == "\t" }) { return s[s.endIndex...] }
        for prefix in ["###### ", "##### ", "#### ", "### ", "## ", "# ", "> ", "- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "- ", "* ", "+ "]
        where s.hasPrefix(prefix) {
            s = s.dropFirst(prefix.count)
            break
        }
        if let dot = s.firstIndex(of: "."), s[..<dot].count <= 3, !s[..<dot].isEmpty, s[..<dot].allSatisfy(\.isNumber),
           s.index(after: dot) < s.endIndex, s[s.index(after: dot)] == " " {
            s = s[s.index(dot, offsetBy: 2)...]
        }
        return s
    }
}

extension Array where Element == UInt8 {
    /// All start offsets of `needle` (memmem-based).
    nonisolated func occurrences(of needle: [UInt8], max: Int = 64) -> [Int] {
        guard !needle.isEmpty, needle.count <= count else { return [] }
        var out: [Int] = []
        withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { nd in
                var start = 0
                while start <= hay.count - nd.count, out.count < max {
                    guard let p = memmem(hay.baseAddress! + start, hay.count - start, nd.baseAddress!, nd.count) else { break }
                    let off = hay.baseAddress!.distance(to: p.assumingMemoryBound(to: UInt8.self))
                    out.append(off)
                    start = off + 1
                }
            }
        }
        return out
    }
}
