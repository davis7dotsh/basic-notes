import Accelerate
import Foundation

extension SearchService {
    nonisolated struct Token: Sendable {
        var bytes: [UInt8]
        var stem: [UInt8]?
        var corrections: [[UInt8]] = []
        var weight: Double = 1
        var isLast: Bool = false
        /// Head of an unknown compound ("houseplant" -> "plant"): a title naming it marks a note about the category.
        var head: [UInt8]?
    }

    nonisolated struct ParsedQuery: Sendable {
        var raw: String
        var folded: [UInt8]
        var words: [String]
        var content: [Token]
        var lastIsPartial: Bool
        /// Raw substring is meaningful (multi-word or code-ish, >= 3 chars).
        var substringWorthy: Bool
        /// Contains an identifier-like token (`force-with-lease`, `errors.Is`, `--onto`, `removeEventListener`): notes
        /// containing the literal query outrank notes that only match its parts.
        var literal: Bool
        /// Text to embed: the query, or its unique words when it repeats itself ("x x x … coffee").
        var embedText: String
        /// Share of non-stopword query words that neither the model nor the notes know (raises the semantic floor).
        var unknownFraction: Double
        /// Unknown words with no spelling correction in the notes either (gibberish, or things these notes never mention).
        var noiseWords: Int
        /// Share of the non-stopword query words that are noise beyond the first (one unknown word can be a name or
        /// a term the model lacks; several mean the embedding is mostly noise).
        var extraNoiseFraction: Double
        /// Every content word is rare in the notes (an exact lookup like a sentinel token or a name).
        var rare: Bool
    }

    nonisolated struct Signals: Sendable {
        var bm = 0.0
        var candidate = false
        var title = 0.0
        var titleRanges: [[Int]] = []
        var coverage = 0.0
        var specificity = 1.0
        var phrase = 0.0
        /// Weighted share of query terms found together on one line (only when >= 2 terms are), and that line.
        var lineCoverage = 0.0
        var line: (start: Int, end: Int)?
        /// Weighted share of consecutive query-term pairs that appear next to each other in order ("call mom").
        var adjacency = 0.0
        var occurrences: [[Int]] = []
        var sim: Float = -1
        var semantic = 0.0
        var bestChunk = -1
    }

    /// Ranking knobs (tuned against tools/fixtures with SearchEval).
    nonisolated enum Tune {
        static let semanticWeight = 1.0
        static let recencyWeight = 0.05
        static let frecencyWeight = 0.06
        static let pinWeight = 0.04
        static let recencyHalfLifeDays = 30.0
        /// Empty-query recents: the most a note's frecency can move it, in seconds of last-touched time.
        static let recentsFrecencySeconds = 120.0
        /// How far (as a share of the manifest's simFloor...simHigh span) a fully non-word query raises the floor.
        static let unknownWordFloorBump = 1.0 / 3
        /// Extra floor (same units) once any query word is unknown to the model and has no spelling match in the notes:
        /// such a word drags the embedding toward look-alike word pieces ("zzqq" ~ "zshrc").
        static let noiseWordFloorBump = 0.35
        /// ...plus this much x the share of the query that further such words make up ("waffle recipe friday r3").
        static let extraNoiseFloorBump = 0.35
        /// Score tier for literal hits of identifier-like queries.
        static let literalTier = 1.0
        /// Lexical bonus for query terms sharing a line (x lineCoverage^2) and for in-order adjacent pairs.
        static let lineWeight = 0.5
        static let adjacencyWeight = 0.3
        /// Lines holding at least this weighted share of the query get their own embedding (at most this many/search).
        static let lineRescoreCoverage = 0.5
        static let lineRescoreBudget = 2
        /// Snippet lines a single search may embed for semantic hits (cached by line text afterwards).
        static let snippetLineEmbedBudget = 8
        /// Query terms named in a note's title (x their weighted share, x the share the body doesn't cover): a descriptive
        /// multi-word query rarely matches a title as a whole, but a title hit on some of its terms says what the note is about.
        static let titleTermWeight = 0.8
        /// Notes with less readable text than this embed close to everything (short fragments, a lone pasted image).
        /// Their cosine is lowered by up to `shortProsePenalty` (share of the manifest span), linearly by missing text;
        /// below `minProseLetters` they get no semantic evidence at all.
        static let shortProseLetters = 32
        static let minProseLetters = 4
        static let shortProsePenalty = 1.0
        /// Once a note holds an identifier query's literal, or every word of a rare-word query exactly, notes with only
        /// semantic evidence must clear a floor this much higher (share of the span): a lookup's look-alikes are noise.
        static let exactHitFloorBump = 0.5
        /// Compound parts must be whole model words at least this long ("house"+"plant", not "cheats"+"het").
        static let compoundMinPart = 4
        /// Rows admitted on semantic evidence alone, at most. They're ranked guesses: past the nearest few, a query
        /// whose similarities are all middling ("waffle recipe friday") only adds look-alikes (no eval target sits
        /// lower than 4th among them).
        static let maxSemanticOnly = 5
    }

    // MARK: Search

    /// Empty query => recents (pins first). Otherwise one blended ranked list with match context.
    func search(_ query: String, context: RankingContext, limit: Int = 50) async -> [SearchHit] {
        flushDeferredUpserts()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return recents(context, limit: limit) }
        let q = parse(query)
        var sig: [NoteID: Signals] = [:]

        // 1. Full-text BM25 (porter-stemmed; title weighted).
        if let expr = ftsExpression(q) {
            var rows: [(Int64, Double)] = []
            db.run("SELECT rowid, -bm25(fts, 4.0, 1.0) AS s FROM fts WHERE fts MATCH ? ORDER BY s DESC LIMIT 250", [.text(expr)]) {
                rows.append(($0.int(0), $0.double(1)))
            }
            let mx = max(rows.first?.1 ?? 1, 1e-9)
            for (r, s) in rows { if let id = idByRow[r] { sig[id, default: .init()].bm = s / mx; sig[id]!.candidate = true } }
        }
        // 2. Trigram substring candidates (identifiers inside words, punctuation-heavy code queries).
        var triTerms: [String] = []
        if q.substringWorthy { triTerms.append(Self.quote(q.raw)) }
        for t in q.content where t.bytes.count >= 3 { triTerms.append(Self.quote(String(decoding: t.bytes, as: UTF8.self))) }
        if !triTerms.isEmpty {
            var rows: [Int64] = []
            db.run("SELECT rowid FROM tri WHERE tri MATCH ? LIMIT 250", [.text(triTerms.joined(separator: " OR "))]) { rows.append($0.int(0)) }
            for r in rows { if let id = idByRow[r] { sig[id, default: .init()].candidate = true } }
        }
        // 3. Lexical coverage + phrase on candidates.
        for (id, s) in sig where s.candidate {
            guard let doc = docs[id] else { continue }
            let lex = lexical(doc, q)
            sig[id]!.coverage = lex.coverage
            sig[id]!.specificity = lex.specificity
            sig[id]!.phrase = lex.phrase
            sig[id]!.occurrences = lex.occurrences
            if q.content.count >= 2 {
                let p = proximity(doc, q, lex.occurrences)
                sig[id]!.lineCoverage = p.lineCoverage
                sig[id]!.line = p.line
                sig[id]!.adjacency = p.adjacency
            }
        }
        // 4. Fuzzy title over every note.
        let titleTokens = q.words.map { w -> (bytes: [UInt8], weight: Double) in
            let b = Text.foldUTF8(w)
            return (b, Text.stopwords.contains(w) ? 0.25 : 1)
        }
        let qFoldedTitle = q.folded
        for (id, doc) in docs {
            var (s, ranges) = Fuzzy.score(tokens: titleTokens, lastIsPartial: q.lastIsPartial, words: doc.titleWords)
            // The query as a substring of the title, starting at a word ("tmux.co" in "tmux.conf"); a mid-word hit
            // of a few letters ("oar" in "keyboard") is noise.
            if qFoldedTitle.count >= 3,
               doc.titleFolded.occurrences(of: qFoldedTitle, max: 8).contains(where: { $0 == 0 || !Text.isWordByte(doc.titleFolded[$0 - 1]) }) {
                s = max(s, 0.95)
            }
            if s > 0.2 { sig[id, default: .init()].title = s; sig[id]!.titleRanges = ranges }
        }
        // 5. Semantic similarity (best chunk per note), trusted less when the query is mostly non-words/typos.
        //    Only similarity above an absolute floor counts as evidence: per-query normalization alone would always
        //    find "the best" notes, even for gibberish.
        var semanticTrust = 1.0
        var floor: Float = .infinity
        let qv = queryVector(q)
        if let qv {
            semantic(qv, into: &sig, lines: lineSimilarities(qv, sig))
            semanticTrust = 0.25 + 0.75 * (1 - q.unknownFraction)
            floor = semanticFloor(unknownFraction: q.unknownFraction, noise: q.noiseWords > 0, extraNoise: q.extraNoiseFraction)
        }
        let literalHits = q.literal && sig.values.contains { $0.phrase > 0 }
        // An exact lookup found what it was looking for (an identifier's literal, or every word of a rare-word query):
        // semantic-only rows are look-alikes and need clearly stronger evidence.
        let lookup = literalHits || (q.rare && sig.values.contains { $0.coverage >= 0.999 })
        let extraFloor = lookup ? floor + Float(Tune.exactHitFloorBump) * semanticSpan : floor

        // 6. Blend into one list. Relevance decides membership; pins/recency/frecency only re-order members.
        let now = Date()
        var scored: [(id: NoteID, score: Double, kind: MatchKind, s: Signals, semanticOnly: Bool)] = []
        for (id, s) in sig {
            guard let doc = docs[id] else { continue }
            let near = Tune.lineWeight * s.lineCoverage * s.lineCoverage + Tune.adjacencyWeight * s.adjacency * s.lineCoverage
            let text = s.coverage > 0 ? (s.coverage * s.coverage + near) * (0.85 + 0.15 * s.bm) * s.specificity * 0.92 : 0
            var lex = max(s.title, text, s.phrase)
            lex = min(1.2, lex + 0.1 * min(s.title, text))
            let semantic = s.sim >= (lex >= 0.25 ? floor : extraFloor) ? s.semantic : 0
            guard lex >= 0.25 || semantic > 0.05 else { continue }
            let semanticOnly = lex < 0.25
            // Title terms only re-rank members (a lone title word like "plant a tree" doesn't make a hit).
            if q.content.count >= 2, s.coverage < 0.999 {
                lex = min(1.2, lex + Tune.titleTermWeight * titleTerms(doc, q) * (1 - s.coverage))
            }
            let sem = Tune.semanticWeight * semanticTrust * semantic * (1 - 0.35 * min(lex, 1))
            let rel = lex + sem + (literalHits && s.phrase > 0 ? Tune.literalTier : 0)
            let score = rel + boost(id, doc: doc, context: context, now: now)
            let kind: MatchKind = lex >= sem ? (s.title >= max(text, s.phrase) && s.title > 0 ? .title : .text) : .semantic
            scored.append((id, score, kind, s, semanticOnly))
            if explain {
                print(String(format: "  %-34@ %.3f = lex %.3f + sem %.3f | title %.2f text %.3f cov %.2f line %.2f bm %.2f | cos %.4f rel %.3f floor %.4f prose %d",
                             id as NSString, score, lex, sem, s.title, text, s.coverage, s.lineCoverage, s.bm, s.sim, s.semantic,
                             lex >= 0.25 ? floor : extraFloor, doc.prose))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.id > $1.id }
        let top = scored.first?.score ?? 0
        var semanticRows = 0
        scored = scored.filter { r in
            guard r.semanticOnly else { return true }
            semanticRows += 1
            return semanticRows <= Tune.maxSemanticOnly
        }
        var lineBudget = Tune.snippetLineEmbedBudget
        return scored.prefix(limit).filter { $0.score >= top * 0.3 }.map { r in
            makeHit(docs[r.id]!, kind: r.kind, score: r.score, signals: r.s, query: q, queryVector: qv, lineBudget: &lineBudget,
                    context: context)
        }
    }

    private func boost(_ id: NoteID, doc: Doc, context: RankingContext, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(doc.modified) / 86_400)
        let recency = exp2(-ageDays / Tune.recencyHalfLifeDays)
        let f = context.frecency[id] ?? 0
        let frec = 1 - exp(-f / 3)
        return Tune.recencyWeight * recency + Tune.frecencyWeight * frec + (context.pins.contains(id) ? Tune.pinWeight : 0)
    }

    /// Pins (pin order), then everything else by last touched = max(file modified, last opened in the app), newest
    /// first. Frecency is worth at most `recentsFrecencySeconds` of recency, so it only breaks near-ties.
    private func recents(_ context: RankingContext, limit: Int) -> [SearchHit] {
        let pinned = context.pins.compactMap { docs[$0] }
        let pinSet = Set(context.pins)
        let rest = docs.values.filter { !pinSet.contains($0.id) }.map { doc -> (Doc, Double) in
            let touched = max(doc.modified, context.lastOpened[doc.id] ?? .distantPast).timeIntervalSince1970
            let f = context.frecency[doc.id] ?? 0
            return (doc, touched + Tune.recentsFrecencySeconds * (1 - exp(-f / 3)))
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
        let ordered = pinned + rest.map(\.0)
        return ordered.prefix(limit).enumerated().map { i, doc in
            let pin = context.pins.firstIndex(of: doc.id)
            return SearchHit(
                id: doc.id, title: doc.title, snippet: preview(doc), snippetHighlights: [], titleHighlights: [],
                modified: doc.modified.timeIntervalSince1970 * 1000, pinned: pin != nil, pinIndex: pin,
                matchKind: .recent, score: 1 / Double(i + 1))
        }
    }

    // MARK: Query parsing

    func parse(_ query: String) -> ParsedQuery {
        // Nobody types more than this; long pastes would only make substring matching pathological.
        let raw = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96))
        // Words come from a longer prefix (deduplicated), so a run of repeated filler can't push real words out.
        let allWords = Text.words(String(query.prefix(2048))).map { String($0.prefix(40)) }
        let lastIsPartial = !(query.last?.isWhitespace ?? true)
        var seen = Set<String>()
        let unique = Array(allWords.filter { seen.insert($0).inserted }.prefix(24))
        let words = allWords.count > unique.count ? unique : Array(allWords.prefix(24))
        let nonStop = unique.filter { !Text.stopwords.contains($0) }
        let chosen = nonStop.isEmpty ? unique : nonStop
        let n = Double(max(docs.count, 1))
        let vocab = embedder?.tokenizer.vocab
        func token(_ w: String, isLast: Bool) -> Token {
            var t = Token(bytes: Text.foldUTF8(w))
            t.isLast = isLast
            let st = Text.stem(w)
            if st != w { t.stem = Text.foldUTF8(st) }
            t.weight = log(1 + (n + 1) / (Double(df[w] ?? 0) + 0.5))
            return t
        }
        var tokens: [Token] = []
        var unknown = 0.0, noise = 0
        var splits: [String: String] = [:]
        for (i, w) in chosen.enumerated() {
            var t = token(w, isLast: lastIsPartial && i == chosen.count - 1 && w == allWords.last)
            // Compounds of known words ("houseplant") are words, not noise.
            let known = vocab.map { Self.inModel(w, $0) || isCompound(w, vocab: $0) } ?? true || (df[w] ?? 0) > 0
                || w.allSatisfy(\.isNumber)
            if df[w] == nil, t.bytes.count >= Fuzzy.minTypoLength, !(t.isLast && vocabularyHasPrefix(t.bytes)) {
                let corr = corrections(for: t.bytes)
                t.corrections = corr.map(\.word)
                if let f = corr.first?.df { t.weight = log(1 + (n + 1) / (Double(f) + 0.5)) }
            }
            // An out-of-vocabulary compound ("houseplant" -> "house ##pl ##ant") embeds as noise: embed its parts.
            if df[w] == nil, t.corrections.isEmpty, !(t.isLast && vocabularyHasPrefix(t.bytes)), let vocab,
               !Self.inModel(w, vocab), let parts = Self.compoundSplit(w, vocab: vocab) {
                t.head = Text.foldUTF8(parts.1)
                splits[w] = parts.0 + " " + parts.1
            }
            if !known {
                unknown += 1
                if t.corrections.isEmpty, !(t.isLast && vocabularyHasPrefix(t.bytes)) { noise += 1 }
            }
            if t.bytes.count == 1 || nonStop.isEmpty { t.weight *= 0.3 }
            tokens.append(t)
        }
        // Repeated filler collapses to its unique words (single letters dropped: "x x x … coffee" means "coffee").
        var embedText = words.count == allWords.count ? raw : unique.filter { $0.count > 1 }.joined(separator: " ")
        if !splits.isEmpty { embedText = Text.words(embedText).map { splits[$0] ?? $0 }.joined(separator: " ") }
        let rareMax = max(2, docs.count / 100)
        let folded = Text.foldUTF8(raw)
        let codeish = raw.unicodeScalars.contains { !($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == " ") }
        let substringWorthy = raw.count >= 3 && (words.count >= 2 || codeish)
        return ParsedQuery(
            raw: raw, folded: folded, words: words, content: tokens, lastIsPartial: lastIsPartial,
            substringWorthy: substringWorthy, literal: substringWorthy && Self.looksLikeCode(raw), embedText: embedText,
            unknownFraction: nonStop.isEmpty ? 0 : unknown / Double(nonStop.count), noiseWords: noise,
            extraNoiseFraction: nonStop.isEmpty ? 0 : Double(max(0, noise - 1)) / Double(nonStop.count),
            rare: !nonStop.isEmpty && nonStop.allSatisfy { (1...rareMax).contains(df[$0] ?? 0) })
    }

    /// The model knows the word, a simple inflection of it ("hamburgers", "validating" -> "validate"), or its plural
    /// ("subscriber" -> "subscribers": a real word whose singular the vocabulary happens to split into pieces).
    private static func inModel(_ w: String, _ vocab: [String: Int32]) -> Bool {
        if vocab[w] != nil || vocab[w + "s"] != nil || vocab[w + "es"] != nil { return true }
        let st = Text.stem(w)
        return st != w && (vocab[st] != nil || vocab[st + "e"] != nil)
    }

    /// Two words the model knows (or the notes use), each at least 3 letters: "houseplant", "paycheck".
    private func isCompound(_ w: String, vocab: [String: Int32]) -> Bool {
        let c = Array(w)
        guard c.count >= 7, c.allSatisfy(\.isLetter) else { return false }
        func known(_ s: String) -> Bool { Self.inModel(s, vocab) || (df[s] ?? 0) > 0 }
        return (3...(c.count - 3)).contains { known(String(c[..<$0])) && known(String(c[$0...])) }
    }

    /// A compound of two whole words the model knows, each at least `Tune.compoundMinPart` letters:
    /// "houseplant" -> ("house", "plant"). English compounds are right-headed: the second part names the category.
    static func compoundSplit(_ w: String, vocab: [String: Int32]) -> (String, String)? {
        let c = Array(w), k = Tune.compoundMinPart
        guard c.count >= 2 * k, c.allSatisfy(\.isLetter) else { return nil }
        for i in k...(c.count - k) {
            let a = String(c[..<i]), b = String(c[i...])
            if vocab[a] != nil, inModel(b, vocab) { return (a, b) }
        }
        return nil
    }

    /// Some whitespace-separated token is identifier-like: word runs joined by code punctuation (`force-with-lease`,
    /// `errors.Is`, `tag:server`, `pg_isready`, `0.0.0.0:8080`), a flag (`--onto`), or camelCase (`useEffect`).
    nonisolated static func looksLikeCode(_ raw: String) -> Bool {
        let joiners = Set("-_./:@#=<>+*&|\\".unicodeScalars)
        for tok in raw.split(whereSeparator: \.isWhitespace) {
            let sc = Array(tok.unicodeScalars)
            var runs = 0, inWord = false, joined = false
            for (i, c) in sc.enumerated() {
                if c.properties.isAlphabetic || c.properties.numericType != nil {
                    if !inWord { runs += 1; if i > 0, joiners.contains(sc[i - 1]), runs > 1 { joined = true } }
                    inWord = true
                    if i > 0, c.properties.isUppercase, sc[i - 1].properties.isLowercase { return true }
                } else {
                    inWord = false
                }
            }
            if joined || (tok.hasPrefix("-") && runs > 0) { return true }
        }
        return false
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private func ftsExpression(_ q: ParsedQuery) -> String? {
        let groups = q.content.compactMap { t -> String? in
            // Single characters ("x", "a") match half the notes; they still count toward coverage of real candidates.
            guard t.bytes.count >= 2 else { return nil }
            let w = String(decoding: t.bytes, as: UTF8.self)
            var alts = [Self.quote(w) + (t.isLast && t.bytes.count >= 2 ? "*" : "")]
            alts += t.corrections.map { Self.quote(String(decoding: $0, as: UTF8.self)) }
            return alts.count == 1 ? alts[0] : "(" + alts.joined(separator: " OR ") + ")"
        }
        return groups.isEmpty ? nil : groups.joined(separator: " OR ")
    }

    private func vocabularyHasPrefix(_ p: [UInt8]) -> Bool {
        if vocabCache == nil { vocabCache = df.map { (Array($0.key.utf8), $0.value) } }
        return vocabCache!.contains { $0.word.count > p.count && $0.word.starts(with: p) }
    }

    /// Spelling corrections from the corpus vocabulary (edit distance 1, or 2 for long words).
    private func corrections(for t: [UInt8]) -> [(word: [UInt8], df: Int)] {
        if vocabCache == nil { vocabCache = df.map { (Array($0.key.utf8), $0.value) } }
        let k = t.count >= 8 ? 2 : 1
        var out: [(word: [UInt8], df: Int, d: Int)] = []
        for v in vocabCache! where abs(v.word.count - t.count) <= k && (v.word[0] == t[0] || v.word[1] == t[1]) {
            let d = Text.editDistance(t, v.word, limit: k)
            if d <= k { out.append((v.word, v.df, d)) }
        }
        return out.sorted { $0.d != $1.d ? $0.d < $1.d : $0.df > $1.df }.prefix(3).map { ($0.word, $0.df) }
    }

    // MARK: Lexical matching

    /// Weighted fraction of query tokens present in the note (exact word > prefix/stem > mid-word substring > typo).
    private func lexical(_ doc: Doc, _ q: ParsedQuery) -> (coverage: Double, specificity: Double, phrase: Double, occurrences: [[Int]]) {
        var total = 0.0, wsum = 0.0, msum = 0.0
        var occ: [[Int]] = []
        doc.content.utf8.withContiguousStorageIfAvailable { orig in
            for t in q.content {
                var (m, o) = Self.strength(doc.folded, orig, t.bytes, isLast: t.isLast)
                if m < 0.85, let st = t.stem {
                    let (ms, os) = Self.strength(doc.folded, orig, st, isLast: true)
                    if ms * 0.9 > m { m = ms * 0.9; o = os }
                }
                for c in t.corrections where m < 0.7 {
                    let (mc, oc) = Self.strength(doc.folded, orig, c, isLast: false)
                    if mc * 0.75 > m { m = mc * 0.75; o = oc }
                }
                total += m * t.weight
                wsum += t.weight
                msum += m
                occ.append(o)
            }
        }
        var phrase = 0.0
        if q.substringWorthy, !doc.folded.occurrences(of: q.folded, max: 1).isEmpty {
            phrase = doc.titleFolded.occurrences(of: q.folded, max: 1).isEmpty ? 0.9 : 1
        }
        // Matches on rare words mean more than matches on words that are in every other note.
        let maxIdf = log(1 + (Double(docs.count) + 1) / 0.5)
        let avgIdf = msum > 0 ? total / msum : 0
        let specificity = 0.6 + 0.4 * min(1, avgIdf / (0.75 * maxIdf))
        return (wsum > 0 ? total / wsum : 0, specificity, phrase, occ)
    }

    /// Weighted share of query terms named in the title: the word itself, an inflection (<= 3 more letters, or any
    /// completion of the word being typed), its stem, or an unknown compound's head ("plants" for "houseplant", 0.75).
    private func titleTerms(_ doc: Doc, _ q: ParsedQuery) -> Double {
        var total = 0.0, wsum = 0.0
        for t in q.content where t.bytes.count >= 2 {
            wsum += t.weight
            var m = 0.0
            for word in doc.titleWords {
                let f = word.folded
                func inflects(_ p: [UInt8], _ extra: Int) -> Bool { f.count - p.count <= extra && f.starts(with: p) }
                if f == t.bytes { m = 1; break }
                if inflects(t.bytes, t.isLast ? .max : 3) || t.stem.map({ inflects($0, 3) }) == true { m = max(m, 0.9) }
                if let h = t.head, inflects(h, 2) { m = max(m, 0.75) }
            }
            total += m * t.weight
        }
        return wsum > 0 ? total / wsum : 0
    }

    /// Same-line co-occurrence and in-order adjacency of query terms. Notes are mostly lists and short paragraphs, so
    /// terms sharing a line ("call mom re thanksgiving") are about the same thing; terms scattered across a note
    /// usually aren't.
    private func proximity(_ doc: Doc, _ q: ParsedQuery, _ occ: [[Int]]) -> (lineCoverage: Double, line: (start: Int, end: Int)?, adjacency: Double) {
        let terms = Array(q.content.prefix(16).enumerated()).filter { $0.element.bytes.count >= 2 }
        let total = q.content.reduce(0) { $0 + $1.weight }
        guard terms.count >= 2, total > 0 else { return (0, nil, 0) }
        let starts = doc.lineStarts
        func lineOf(_ off: Int) -> Int {
            var lo = 0, hi = starts.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if Int(starts[mid]) <= off { lo = mid } else { hi = mid - 1 } }
            return lo
        }
        var masks: [Int: UInt32] = [:]
        for (i, _) in terms where i < occ.count {
            for off in occ[i] { masks[lineOf(off), default: 0] |= 1 << UInt32(i) }
        }
        var best = 0.0, bestLine = -1
        for (line, mask) in masks where mask.nonzeroBitCount >= 2 {
            let w = terms.reduce(0.0) { mask & (1 << UInt32($1.offset)) != 0 ? $0 + $1.element.weight : $0 }
            if w > best || (w == best && line < bestLine) { best = w; bestLine = line }
        }
        // Consecutive query terms within a short gap, in query order (a stopword or two may sit between them).
        var adj = 0.0, pairW = 0.0
        for k in 1..<terms.count {
            let (i, a) = terms[k - 1], (j, b) = terms[k]
            let w = min(a.weight, b.weight)
            pairW += w
            guard i < occ.count, j < occ.count else { continue }
            let len = a.bytes.count
            if occ[i].contains(where: { x in occ[j].contains { y in y - x >= len && y - x - len <= 12 } }) { adj += w }
        }
        let line = bestLine >= 0
            ? (Int(starts[bestLine]), bestLine + 1 < starts.count ? Int(starts[bestLine + 1]) - 1 : doc.folded.count) : nil
        return (best / total, line, pairW > 0 ? adj / pairW : 0)
    }

    /// Best match class of `needle` in `hay` and the offsets of its useful occurrences.
    private static func strength(_ hay: [UInt8], _ orig: UnsafeBufferPointer<UInt8>, _ needle: [UInt8], isLast: Bool) -> (Double, [Int]) {
        let offs = hay.occurrences(of: needle, max: 48)
        var best = 0.0
        var good: [Int] = []
        func upper(_ i: Int) -> Bool { i < orig.count && orig[i] >= 65 && orig[i] <= 90 }
        func lowerOrDigit(_ i: Int) -> Bool { i >= 0 && i < orig.count && ((orig[i] >= 97 && orig[i] <= 122) || (orig[i] >= 48 && orig[i] <= 57)) }
        for off in offs {
            let end = off + needle.count
            let startOK = off == 0 || !Text.isWordByte(hay[off - 1]) || (upper(off) && lowerOrDigit(off - 1))
            let endOK = end >= hay.count || !Text.isWordByte(hay[end]) || (upper(end) && lowerOrDigit(end - 1))
            var m: Double
            if startOK && endOK {
                m = 1
            } else if startOK {
                var rest = 0, i = end
                while rest <= 3, i < hay.count, Text.isWordByte(hay[i]), !(upper(i) && lowerOrDigit(i - 1)) { rest += 1; i += 1 }
                m = rest <= 3 ? 0.9 : (isLast ? 0.85 : 0.6)
            } else {
                m = needle.count >= 3 ? 0.5 : 0
            }
            if m > 0 { good.append(off) }
            best = max(best, m)
            if best == 1 && good.count >= 8 { break }
        }
        return (best, good)
    }

    // MARK: Semantic

    private func queryVector(_ q: ParsedQuery) -> [Float]? {
        guard let embedder else { return nil }
        // Partial single short words carry no meaning yet ("gro"); let keyword/title handle them.
        // Letters in real words: a string of single letters ("q z x v k") embeds as noise.
        let letters = Text.words(q.embedText).filter { $0.count > 1 }.reduce(0) { $0 + $1.unicodeScalars.filter(\.properties.isAlphabetic).count }
        guard letters >= 4, !(q.words.count == 1 && q.lastIsPartial && letters < 5) else { return nil }
        let key = q.embedText.lowercased()
        if let v = queryVectorCache[key] { return v }
        let v = embedder.embedQuery(q.embedText)
        if queryVectorCache.count > 256 { queryVectorCache.removeAll() }
        queryVectorCache[key] = v
        return v
    }

    /// Absolute floor on raw cosine for semantic evidence (model-specific, from the manifest; see tools/SearchEval
    /// --calib). Raised for queries made partly of words neither the model nor the notes know, whose embedding is
    /// mostly noise. No manifest calibration => no floor.
    func semanticFloor(unknownFraction u: Double, noise: Bool = false, extraNoise: Double = 0) -> Float {
        guard let m = embedder?.manifest, let base = floorOverride?.base ?? m.simFloor ?? m.simLow else { return -1 }
        let bump = u * (floorOverride?.bump ?? Tune.unknownWordFloorBump) + (noise ? Tune.noiseWordFloorBump : 0)
            + extraNoise * Tune.extraNoiseFloorBump
        return Float(base) + Float(bump) * semanticSpan
    }

    /// The manifest's calibrated cosine span (floor...high) that floor bumps are measured in; 0 without calibration.
    var semanticSpan: Float {
        guard let m = embedder?.manifest, let base = floorOverride?.base ?? m.simFloor ?? m.simLow else { return 0 }
        return Float(max(0, (m.simHigh ?? base) - base))
    }

    /// Notes embed as a few big chunks, which dilutes a single matching list item ("call mom re thanksgiving" inside
    /// a long todo list). The lines where most query terms meet are embedded on their own (cached by text, a small
    /// per-search budget) and stand in for the note's similarity when they're closer.
    private func lineSimilarities(_ qv: [Float], _ sig: [NoteID: Signals]) -> [NoteID: Float] {
        // Only where a line is a small part of its note: otherwise the note's own chunk already says the same thing.
        let picks = sig.compactMap { id, s -> (NoteID, Signals)? in
            guard s.lineCoverage >= Tune.lineRescoreCoverage, let l = s.line, let doc = docs[id],
                  Double(l.end - l.start) < 0.5 * Double(doc.folded.count) else { return nil }
            return (id, s)
        }.sorted { ($0.1.lineCoverage, $0.1.bm, $0.0) > ($1.1.lineCoverage, $1.1.bm, $1.0) }.prefix(Tune.lineRescoreBudget)
        var out: [NoteID: Float] = [:]
        var budget = Tune.lineRescoreBudget
        for (id, s) in picks {
            guard let doc = docs[id], let line = s.line else { continue }
            let text = Self.display(lineText(doc, line, maxBytes: 400))
            guard Text.words(text).count >= 2, let v = lineVectors([String(text.prefix(120))], budget: &budget).first ?? nil else { continue }
            out[id] = Self.dot(qv, v)
        }
        return out
    }

    private func semantic(_ qv: [Float], into sig: inout [NoteID: Signals], lines: [NoteID: Float] = [:]) {
        let dim = qv.count
        if packedDirty || packedDim != dim { repack(dim: dim) }
        let rows = packed.count / dim
        guard rows > 0 else { return }
        var out = [Float](repeating: 0, count: rows)
        packed.withUnsafeBufferPointer { m in
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(dim), 1, m.baseAddress!, Int32(dim), qv, 1, 0, &out, 1)
        }
        var sims: [(NoteID, Float, Int)] = []
        sims.reserveCapacity(packedRows.count)
        for r in packedRows {
            var best: Float = -1, bi = 0
            for i in 0..<r.count where out[r.start + i] > best { best = out[r.start + i]; bi = i }
            if let l = lines[r.id], l > best { best = l; bi = -1 }
            sims.append((r.id, best - r.penalty, bi))
        }
        guard !sims.isEmpty else { return }
        // Calibrate against this query's similarity distribution (model-agnostic; cosine ranges differ a lot between
        // models). Small corpora lean on the model's absolute range from its manifest instead.
        let values = sims.map { Double($0.1) }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let sd = max(1e-3, (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n).squareRoot())
        let zTop = ((values.max() ?? 0) - mean) / sd
        if explain {
            let top = sims.sorted { $0.1 > $1.1 }.prefix(8)
            print("  sem top: " + top.map { String(format: "%@ %.4f z%.2f", $0.0 as NSString, $0.1, (Double($0.1) - mean) / sd) }.joined(separator: " | "))
        }
        let low = embedder?.manifest.simLow, high = embedder?.manifest.simHigh
        let alpha = (low == nil || high == nil) ? 1 : min(1, n / 40)
        for (id, s, bi) in sims {
            let z = (Double(s) - mean) / sd
            let relZ = min(1, max(0, (z - 1.0) / 2.5)) * max(0, 1 - (zTop - z) / 2.5)
            var rel = alpha * relZ
            if alpha < 1, let low, let high { rel += (1 - alpha) * min(1, max(0, (Double(s) - low) / (high - low))) }
            guard rel > 0 || sig[id] != nil else { continue }
            sig[id, default: .init()].sim = s
            sig[id]!.semantic = rel
            sig[id]!.bestChunk = bi
        }
    }

    /// All chunk vectors in one row-major matrix so a query is a single sgemv. Notes with (almost) no readable text
    /// are left out, and short ones carry a cosine penalty: their embeddings sit close to every query.
    private func repack(dim: Int) {
        packed.removeAll(keepingCapacity: true)
        packedRows.removeAll(keepingCapacity: true)
        let span = semanticSpan, full = Double(Tune.shortProseLetters)
        for (id, doc) in docs where doc.vectors.count >= dim && doc.vectors.count % dim == 0 && doc.prose >= Tune.minProseLetters {
            let penalty = Float(Tune.shortProsePenalty * max(0, 1 - Double(doc.prose) / full)) * span
            packedRows.append((id, packed.count / dim, doc.vectors.count / dim, penalty))
            packed += doc.vectors
        }
        packedDim = dim
        packedDirty = false
    }

    // MARK: Hits & snippets

    private func makeHit(_ doc: Doc, kind: MatchKind, score: Double, signals s: Signals, query q: ParsedQuery, queryVector qv: [Float]?,
                         lineBudget: inout Int, context: RankingContext) -> SearchHit {
        let pin = context.pins.firstIndex(of: doc.id)
        let source: Substring?
        let windowAroundMatch: Bool
        if kind == .semantic, s.bestChunk >= 0 {
            source = semanticLine(doc, chunk: s.bestChunk, query: q, queryVector: qv, lineBudget: &lineBudget) ?? previewLine(doc)
            windowAroundMatch = false
        } else {
            let match = bestLine(doc, occurrences: s.occurrences, query: q)
            source = match ?? previewLine(doc)
            windowAroundMatch = match != nil
        }
        let line = DisplayLine(source ?? "")
        let window = Self.window(line.text, query: q, aroundMatch: windowAroundMatch)
        let highlights = Self.highlights(in: window.text, query: q)
        var passage = line.passage(in: doc.content, visible: window.range, leadingEllipsis: window.leadingEllipsis, highlights: highlights)
        if kind == .title, !windowAroundMatch, highlights.isEmpty, let title = NoteTitle.firstTitle(in: doc.content) {
            let titleLine = DisplayLine(title.source)
            let titleHighlights = titleLine.text == doc.title && !s.titleRanges.isEmpty ? s.titleRanges : Self.highlights(in: titleLine.text, query: q)
            let length = titleHighlights.isEmpty ? titleLine.text.prefix(Self.snippetLength).utf16.count : titleLine.text.utf16.count
            passage = titleLine.passage(in: doc.content, visible: 0..<length, leadingEllipsis: false, highlights: titleHighlights)
        }
        return SearchHit(
            id: doc.id, title: doc.title, snippet: window.text, snippetHighlights: highlights, titleHighlights: s.titleRanges,
            modified: doc.modified.timeIntervalSince1970 * 1000, pinned: pin != nil, pinIndex: pin,
            matchKind: kind, score: score, passage: passage)
    }

    /// Lines (UTF-8 byte ranges) excluding fences/blank lines.
    private static func lines(_ doc: Doc) -> [(start: Int, end: Int)] {
        var out: [(Int, Int)] = []
        var start = 0
        let f = doc.folded
        for i in 0...f.count where i == f.count || f[i] == 10 || f[i] == 13 {
            if i > start { out.append((start, i)) }
            start = i + 1
        }
        return out
    }

    /// Text of a byte range, clamped to `maxBytes` and snapped to UTF-8 character boundaries.
    private func lineText(_ doc: Doc, _ r: (start: Int, end: Int), maxBytes: Int = 600) -> Substring {
        let utf8 = doc.content.utf8
        var a = utf8.index(utf8.startIndex, offsetBy: r.start)
        var b = utf8.index(a, offsetBy: min(r.end - r.start, maxBytes))
        while a < b, utf8[a] & 0xC0 == 0x80 { utf8.formIndex(after: &a) }
        while b > a, b < utf8.endIndex, utf8[b] & 0xC0 == 0x80 { utf8.formIndex(before: &b) }
        return doc.content[a..<b]
    }

    /// The title line again (compared as plain text, the way the title was made), markup, or nothing readable.
    private func isTitleOrJunk(_ doc: Doc, _ text: String) -> Bool {
        guard !NoteTitle.isMarkup(text), NoteTitle.text(ofLine: text)?.isEmpty == false else { return true }
        let t = Text.displayLine(Substring(text)).trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("```") || t.hasPrefix("![") || t == "---" { return true }
        let plain = NoteTitle.plain(t)
        return plain.isEmpty || plain == doc.title || NoteTitle.text(ofLine: text) == doc.title
    }

    private func previewLine(_ doc: Doc) -> Substring? {
        for r in Self.lines(doc) {
            let line = lineText(doc, r)
            if !isTitleOrJunk(doc, String(line)) { return line }
        }
        return nil
    }

    func preview(_ doc: Doc) -> String {
        previewLine(doc).map { Self.clip(Self.display($0)) } ?? ""
    }

    private func bestLine(_ doc: Doc, occurrences: [[Int]], query q: ParsedQuery) -> Substring? {
        let f = doc.folded
        // The literal query (when meaningful) beats any mix of its words.
        let phrase = q.substringWorthy ? f.occurrences(of: q.folded, max: 8) : []
        guard !phrase.isEmpty || occurrences.contains(where: { !$0.isEmpty }) else { return nil }
        let lists = zip(q.content.map(\.weight), occurrences).map { $0 } + [(q.content.reduce(1) { $0 + $1.weight }, phrase)]
        var scores: [Int: (end: Int, score: Double)] = [:]
        for (weight, offs) in lists {
            var counted = Set<Int>()
            for off in offs {
                // Line bounds, but never scan more than a window around the match (single-line megabyte notes).
                var s = off
                while s > 0, f[s - 1] != 10, f[s - 1] != 13, off - s < 120 { s -= 1 }
                guard counted.insert(s).inserted else { continue }
                var e = off
                while e < f.count, f[e] != 10, f[e] != 13, e - off < 400 { e += 1 }
                scores[s, default: (e, 0)].score += weight
            }
        }
        let ranked = scores.sorted { $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.key < $1.key }
        for (start, candidate) in ranked {
            let text = lineText(doc, (start, candidate.end))
            if !isTitleOrJunk(doc, String(text)) { return text }
        }
        return nil
    }

    /// The line of the best-matching chunk closest in meaning to the query (line embeddings, cached by text; a
    /// per-search budget bounds model work), falling back to word overlap + substance when out of budget.
    private func semanticLine(_ doc: Doc, chunk: Int, query q: ParsedQuery, queryVector qv: [Float]?, lineBudget: inout Int) -> Substring? {
        guard chunk * 2 + 1 < doc.chunks.count else { return nil }
        var a = Int(doc.chunks[chunk * 2]), b = Int(doc.chunks[chunk * 2 + 1])
        if a == 0 && b == 0, doc.chunks.count >= 4 { (a, b) = (Int(doc.chunks[0]), Int(doc.chunks[1])) }  // title chunk: first body chunk
        let u = doc.content.utf16
        guard a >= 0, b <= u.count, a < b else { return nil }
        let body = doc.content[String.Index(utf16Offset: a, in: doc.content)..<String.Index(utf16Offset: b, in: doc.content)]
        let all = body.split(whereSeparator: \.isNewline)
            .filter { !isTitleOrJunk(doc, String($0)) && $0.contains(where: { $0.isLetter || $0.isNumber }) }
        // Short fragments and headings embed close to everything; use them only when there's nothing more substantive.
        let substantive = all.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && Text.words(String($0)).count >= 3 }
        let lines = (substantive.isEmpty ? all : substantive).prefix(8)
        guard !lines.isEmpty else { return nil }
        let stems = Set(q.words.filter { !Text.stopwords.contains($0) }.map { Text.stem($0) })
        var best: Substring?
        var bestScore = -Double.infinity
        let vectors = qv == nil ? [] : lineVectors(lines.map { Self.display($0) }, budget: &lineBudget)
        for (i, s) in lines.enumerated() {
            let words = Text.words(String(s))
            var score: Double
            if let qv, i < vectors.count, let v = vectors[i] {
                score = Double(Self.dot(qv, v))
            } else {
                // Prefer lines sharing words with the query, then substantive body lines over headings/short fragments.
                let overlap = Set(words.map { Text.stem($0) }).intersection(stems).count
                let heading = s.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                score = Double(overlap) * 10 + (heading ? 0 : 2) + min(Double(words.count), 12) / 12 - 100
            }
            if score > bestScore { best = s; bestScore = score }
        }
        return best
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        vDSP_dotpr(a, 1, b, 1, &s, vDSP_Length(min(a.count, b.count)))
        return s
    }

    /// Passage embeddings of snippet lines, cached by text. All-or-nothing per note so lines are compared fairly.
    private func lineVectors(_ texts: [String], budget: inout Int) -> [[Float]?] {
        guard let embedder else { return [] }
        let keys = texts.map { Text.hash64($0) }
        let missing = Array(Set(keys.indices.filter { lineVectorCache[keys[$0]] == nil }.map { keys[$0] }))
        if !missing.isEmpty {
            guard missing.count <= budget else { return [] }
            budget -= missing.count
            let byKey = Dictionary(keys.indices.map { (keys[$0], texts[$0]) }, uniquingKeysWith: { a, _ in a })
            if lineVectorCache.count + missing.count > 4096 { lineVectorCache.removeAll() }
            for (k, v) in zip(missing, embedder.embedDocuments(missing.map { String(byKey[$0]!.prefix(160)) })) { lineVectorCache[k] = v }
        }
        return keys.map { lineVectorCache[$0] }
    }

    static let snippetLength = 140

    /// The retained UTF-16 units map even repeated words in the preview back to the exact Markdown occurrence.
    private struct DisplayLine {
        let source: Substring
        let text: String
        let retained: IndexSet

        private static let link = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)
        private static let marks = try! NSRegularExpression(pattern: #"\*\*|__|~~|`"#)

        init(_ line: Substring) {
            let block = Text.displayLine(line)
            let visible = CharacterSet.whitespaces.inverted
            let start = block.rangeOfCharacter(from: visible)?.lowerBound ?? block.endIndex
            let end = block.rangeOfCharacter(from: visible, options: .backwards)?.upperBound ?? block.endIndex
            source = block[start..<end]
            let raw = String(source)
            let length = raw.utf16.count
            if !raw.contains(where: { "[*_`~".contains($0) }) {
                text = raw
                retained = IndexSet(integersIn: 0..<length)
                return
            }
            var kept = IndexSet(integersIn: 0..<length)
            func joined(_ ranges: IndexSet) -> String {
                if ranges.count == length { return raw }
                let ns = raw as NSString
                return ranges.rangeView.map { ns.substring(with: NSRange($0)) }.joined()
            }
            for match in Self.link.matches(in: raw, range: NSRange(location: 0, length: length)) {
                let label = match.range(at: 1)
                kept.remove(integersIn: match.range.location..<label.location)
                kept.remove(integersIn: NSMaxRange(label)..<NSMaxRange(match.range))
            }
            let labels = joined(kept)
            var markup = IndexSet()
            for match in Self.marks.matches(in: labels, range: NSRange(location: 0, length: kept.count)) {
                markup.insert(integersIn: match.range.location..<NSMaxRange(match.range))
            }
            // Markers are found after link removal, so character pairs that now touch still strip together.
            var startInLabels = 0
            for run in kept.rangeView where !markup.isEmpty {
                for cut in markup.rangeView(of: startInLabels..<(startInLabels + run.count)) {
                    let shift = run.lowerBound - startInLabels
                    kept.remove(integersIn: (cut.lowerBound + shift)..<(cut.upperBound + shift))
                }
                startInLabels += run.count
            }
            retained = kept
            text = markup.isEmpty ? labels : joined(kept)
        }

        /// Translate one visible UTF-16 index by skipping the erased runs of Markdown.
        private func sourceIndex(_ index: Int) -> Int {
            var remaining = index
            for run in retained.rangeView {
                if remaining < run.count { return run.lowerBound + remaining }
                remaining -= run.count
            }
            return source.utf16.count
        }

        func passage(in content: String, visible: Range<Int>, leadingEllipsis: Bool, highlights: [[Int]]) -> SearchPassage? {
            guard !visible.isEmpty else { return nil }
            let origin = visible.lowerBound - (leadingEllipsis ? 1 : 0)
            let matched = highlights.lazy.map { (origin + $0[0])..<(origin + $0[1]) }
                .first { visible.lowerBound <= $0.lowerBound && $0.upperBound <= visible.upperBound }
            let target = matched ?? visible
            let first = sourceIndex(target.lowerBound), end = sourceIndex(target.upperBound - 1) + 1
            let raw = String(source) as NSString
            return SearchPassage(offset: source.startIndex.utf16Offset(in: content) + first,
                                 text: raw.substring(with: NSRange(location: first, length: end - first)))
        }
    }

    static func display(_ line: Substring) -> String { DisplayLine(line).text }

    private static func clip(_ s: String) -> String {
        guard s.count > snippetLength else { return s }
        return String(s.prefix(snippetLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The visible range excludes the decorative ellipses, which have no source position.
    private static func window(_ text: String, query q: ParsedQuery, aroundMatch: Bool)
        -> (text: String, range: Range<Int>, leadingEllipsis: Bool) {
        guard text.count > snippetLength else { return (text, 0..<text.utf16.count, false) }
        if !aroundMatch {
            let visible = text.prefix(snippetLength).trimmingCharacters(in: .whitespaces)
            let start = text.range(of: visible, options: .literal)?.lowerBound.utf16Offset(in: text) ?? 0
            return (visible + "…", start..<(start + visible.utf16.count), false)
        }
        let first = highlights(in: text, query: q).first?[0] ?? 0
        let hit = String.Index(utf16Offset: first, in: text)
        var start = text.index(hit, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        while start > text.startIndex, start < hit, text[text.index(before: start)] != " " { text.formIndex(after: &start) }
        let end = text.index(start, offsetBy: snippetLength, limitedBy: text.endIndex) ?? text.endIndex
        let leading = start != text.startIndex
        let shown = (leading ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
        return (shown, start.utf16Offset(in: text)..<end.utf16Offset(in: text), leading)
    }

    /// UTF-16 ranges of query tokens (and their stems/corrections) in `s`. Short tokens only at word starts.
    static func highlights(in s: String, query q: ParsedQuery) -> [[Int]] {
        let hay = Text.foldUTF16(s)
        var ranges: [[Int]] = []
        var needles: [[UInt16]] = []
        for t in q.content {
            needles.append(Array(String(decoding: t.bytes, as: UTF8.self).utf16))
            if let st = t.stem { needles.append(Array(String(decoding: st, as: UTF8.self).utf16)) }
            needles += t.corrections.map { Array(String(decoding: $0, as: UTF8.self).utf16) }
        }
        if q.substringWorthy { needles.append(Array(String(decoding: q.folded, as: UTF8.self).utf16)) }
        for n in needles where !n.isEmpty && n.count <= hay.count {
            var i = 0
            while i <= hay.count - n.count {
                if hay[i] == n[0], Array(hay[i..<(i + n.count)]) == n {
                    let atStart = i == 0 || !Text.isWordUnit(hay[i - 1])
                    if n.count >= 3 || atStart { ranges.append([i, i + n.count]); i += n.count; continue }
                }
                i += 1
            }
        }
        // Merge overlaps.
        ranges.sort { $0[0] < $1[0] }
        var merged: [[Int]] = []
        for r in ranges {
            if let last = merged.last, r[0] <= last[1] { merged[merged.count - 1][1] = max(last[1], r[1]) } else { merged.append(r) }
        }
        return merged
    }
}
