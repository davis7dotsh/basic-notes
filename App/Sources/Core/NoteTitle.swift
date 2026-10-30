import Foundation

nonisolated enum NoteTitle {
    /// First line with readable text, stripped of leading Markdown markers and inline syntax. "Untitled" when none.
    /// Any line ending counts ("\r\n" is a single Character in Swift, so splitting on "\n" would miss CRLF files).
    static func from(_ content: String) -> String {
        firstTitle(in: content)?.text ?? "Untitled"
    }

    static func firstTitle(in content: String) -> (source: Substring, text: String, line: Int)? {
        // Line by line up to the first title line (not `split`, which cuts up a whole long note on every save).
        var rest = content[...]
        var lineNumber = 1
        while !rest.isEmpty {
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            let raw = rest[..<end]
            if !raw.isEmpty, let line = text(ofLine: raw), !line.isEmpty { return (raw, line, lineNumber) }
            guard end < rest.endIndex else { break }
            // CodeMirror counts CR, LF and CRLF as line breaks.
            if rest[end] == "\n" || rest[end] == "\r" || rest[end] == "\r\n" { lineNumber += 1 }
            rest = rest[rest.index(after: end)...]
        }
        return nil
    }

    /// The title text a line would give (block marker stripped, inline Markdown -> plain text); nil for markup lines.
    static func text<S: StringProtocol>(ofLine raw: S) -> String? {
        guard !isMarkup(raw) else { return nil }
        // Quote markers (any depth), then one heading or list marker, then an optional task box.
        let full = String(raw)
        let ns = full as NSString
        let prefixEnd = blockPrefix.firstMatch(in: full, range: NSRange(location: 0, length: ns.length))?.range.length ?? 0
        let line = ns.substring(from: prefixEnd).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("```") || line == "---" { return nil }
        // What's left is only more markup (`- #`, `- [ ]`, `> -`, `## #`, `**`): no title text on this line.
        if line.range(of: #"^(#{1,6}|\[[ xX]\]|[-*+]|[*_~`]+)$"#, options: .regularExpression) != nil { return "" }
        return plain(line)
    }

    /// (A bare `#`…`######` line is an empty heading, as in CommonMark: skipped like any other markup line. A list item's
    /// marker is followed by a task box or a heading marker: `- ## Real` is a heading in a list.)
    private static let blockPrefix = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)*[ \t]*(?:#{1,6}(?:[ \t]+|$)|(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+|#{1,6}(?:[ \t]+|$))?)?"#)

    /// Markdown structure, not prose: code fences, thematic breaks (`---`, `* * *`) and link reference definitions
    /// (`[img]: assets/x.png`). Never a title, a snippet, or readable text.
    static func isMarkup<S: StringProtocol>(_ line: S) -> Bool {
        var it = line.unicodeScalars.makeIterator()
        var c = it.next(), indent = 0
        while c == " " { indent += 1; c = it.next() }
        guard indent <= 3, let first = c else { return false }
        switch first {
        case "`", "~":  // fence
            return it.next() == first && it.next() == first
        case "-", "*", "_":  // thematic break: 3+ of one marker, spaces allowed between
            var count = 1
            while let ch = it.next() {
                if ch == first { count += 1 } else if ch != " " && ch != "\t" && ch != "\r" { return false }
            }
            return count >= 3
        case "[":  // link reference definition: [label]: destination (footnotes `[^1]: text` are prose)
            var label = 0, closed = false
            while let ch = it.next() {
                if ch == "]" { closed = true; break }
                if ch == "[" || (label == 0 && ch == "^") { return false }
                label += 1
            }
            guard closed, label > 0, it.next() == ":" else { return false }
            while let ch = it.next() { if ch != " " && ch != "\t" && ch != "\r" { return true } }
            return false
        default:
            return false
        }
    }

    /// Inline Markdown -> display text: images dropped (or their alt text kept), links -> their text, emphasis/code
    /// markers removed, backslash escapes and HTML entities resolved.
    static func plain(_ line: String, keepImageAlt: Bool = false) -> String {
        guard line.unicodeScalars.contains(where: { inlineSyntax.contains($0) }) else {
            return line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        // Backslash-escaped punctuation is literal: park it in the private-use area so the patterns below skip it.
        var s = ""
        var escaped = false
        for scalar in line.unicodeScalars {
            if escaped, scalar.isASCII, "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars.contains(scalar) {
                s.unicodeScalars.append(Unicode.Scalar(parked + scalar.value)!)
            } else {
                if escaped { s.append("\\") }
                if scalar != "\\" { s.unicodeScalars.append(scalar) }
            }
            escaped = !escaped && scalar == "\\"
        }
        if escaped { s.append("\\") }
        // A dropped image leaves a placeholder until emphasis is resolved, so `*![p](x.png) words*` loses both stars.
        s = image.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                           withTemplate: keepImageAlt ? "$1" : String(Unicode.Scalar(placeholder)!))
        for (regex, template) in inlineRules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        s = decodeEntities(s)
        let restored = String(String.UnicodeScalarView(s.unicodeScalars.compactMap {
            $0.value == placeholder ? nil : (parked..<(parked + 0x80)).contains($0.value) ? Unicode.Scalar($0.value - parked)! : $0
        }))
        return restored.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let parked: UInt32 = 0xE000
    private static let placeholder: UInt32 = 0xE100
    private static let inlineSyntax = Set("[]*_~`&\\".unicodeScalars)

    /// Bracketed text with one level of nested brackets (`a [b] c`), then an inline `(dest)` (balanced parens) or a
    /// reference `[label]`.
    private static let bracketed = #"\[((?:[^\[\]]|\[[^\]]*\])*)\]"#
    private static let destination = #"(?:\([^)]*(?:\([^)]*\)[^)]*)*\)|\[[^\]]*\])"#
    /// Images in every form, including shortcut `![alt]`.
    private static let image = try! NSRegularExpression(pattern: "!" + bracketed + destination + "?")
    private static let inlineRules: [(NSRegularExpression, String)] = [
        (bracketed + destination, "$1"),
        (#"(\*\*|__|~~|`)(.+?)\1"#, "$2"),
        (#"(?<![\w*])[*_](?![\s*_])(.+?)(?<![\s*_])[*_](?![\w*])"#, "$1"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static let entity = try! NSRegularExpression(pattern: #"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z]{2,6});"#)
    private static let namedEntities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]

    /// `&amp;`, `&#38;`, `&#x26;` -> "&" (the common named ones and any numeric reference; unknown names stay).
    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = "", last = s.startIndex
        for m in entity.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s), let body = Range(m.range(at: 1), in: s) else { continue }
            let name = s[body]
            let value: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                value = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if name.hasPrefix("#") {
                value = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                value = namedEntities[String(name)]
            }
            out += s[last..<whole.lowerBound]
            out += value.flatMap { $0 == "\u{0}" ? nil : $0 } ?? String(s[whole])
            last = whole.upperBound
        }
        return out + s[last...]
    }
}
