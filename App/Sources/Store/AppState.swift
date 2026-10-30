import Foundation

// CONTRACT (owned by the Store/Search agent; public API must stay as-is, internals are free).
// Non-content app state: pins, last note, per-note view state, frecency, back/forward history.
// Persisted as `<directory>/state.json`, debounced; call `flush()` on app quit. Missing/corrupt file => fresh state.

final class AppState {
    private(set) var pins: [NoteID] = [] { didSet { scheduleSave() } }
    var lastOpenID: NoteID? { didSet { if lastOpenID != oldValue { scheduleSave() } } }
    private var viewStates: [NoteID: ViewState] = [:]
    private var back: [NoteID] = []
    private var forward: [NoteID] = []
    private var frec: [NoteID: Frecency] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    static let historyLimit = 100
    static let frecencyLimit = 2000
    static let viewStateLimit = 1000
    /// Frecency half-life.
    static let halfLife: TimeInterval = 7 * 86_400
    /// Edits count at most once per note per window (autosave fires constantly while typing).
    static let editWindow: TimeInterval = 10 * 60

    nonisolated struct Frecency: Codable, Sendable {
        var score: Double
        var updated: Double
        var lastEdit: Double?
    }

    nonisolated private struct Persisted: Codable, Sendable {
        var version = 1
        var pins: [NoteID] = []
        var lastOpenID: NoteID?
        var viewStates: [NoteID: ViewState] = [:]
        var back: [NoteID] = []
        var forward: [NoteID] = []
        var frecency: [NoteID: Frecency] = [:]
    }

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("state.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: fileURL), let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        var seen = Set<NoteID>()
        pins = p.pins.filter { seen.insert($0).inserted }
        lastOpenID = p.lastOpenID
        viewStates = p.viewStates
        back = Array(p.back.suffix(Self.historyLimit))
        forward = Array(p.forward.suffix(Self.historyLimit))
        frec = p.frecency
        saveTask?.cancel()
        saveTask = nil
    }

    func viewState(for id: NoteID) -> ViewState? { viewStates[id] }
    func setViewState(_ vs: ViewState, for id: NoteID) {
        guard viewStates[id] != vs else { return }
        viewStates[id] = vs
        if viewStates.count > Self.viewStateLimit {
            let keep = Set(viewStates.keys.sorted { frecency($0) > frecency($1) }.prefix(Self.viewStateLimit * 9 / 10))
            viewStates = viewStates.filter { keep.contains($0.key) || $0.key == id }
        }
        scheduleSave()
    }

    func pinIndex(_ id: NoteID) -> Int? { pins.firstIndex(of: id) }

    @discardableResult
    func togglePin(_ id: NoteID) -> Int? {
        if let i = pins.firstIndex(of: id) { pins.remove(at: i); return nil }
        pins.append(id)
        return pins.count - 1
    }

    // MARK: Frecency (exponentially decayed open/edit counts)

    func recordOpen(_ id: NoteID) { bump(id, by: 1) }

    func recordEdit(_ id: NoteID) {
        let now = Date().timeIntervalSince1970
        if let last = frec[id]?.lastEdit, now - last < Self.editWindow { return }
        bump(id, by: 0.5)
        frec[id]?.lastEdit = now
    }

    /// Higher = more frecent. 0 for unknown notes. One open today ~ 1.0, decaying by half every week.
    func frecency(_ id: NoteID) -> Double {
        guard let f = frec[id] else { return 0 }
        return Self.decayed(f, now: Date().timeIntervalSince1970)
    }

    /// Frecency for every known note (for `RankingContext`).
    /// Last open/edit time per note, for RankingContext.lastOpened.
    var lastTouched: [NoteID: Date] { frec.mapValues { Date(timeIntervalSince1970: $0.updated) } }

    var frecencyScores: [NoteID: Double] {
        let now = Date().timeIntervalSince1970
        return frec.mapValues { Self.decayed($0, now: now) }
    }

    private static func decayed(_ f: Frecency, now: Double) -> Double {
        f.score * exp2(-max(0, now - f.updated) / halfLife)
    }

    private func bump(_ id: NoteID, by w: Double) {
        let now = Date().timeIntervalSince1970
        let current = frec[id].map { Self.decayed($0, now: now) } ?? 0
        frec[id] = Frecency(score: current + w, updated: now, lastEdit: frec[id]?.lastEdit)
        if frec.count > Self.frecencyLimit {
            let keep = frec.keys.sorted { frecency($0) > frecency($1) }.prefix(Self.frecencyLimit * 9 / 10)
            let set = Set(keep)
            frec = frec.filter { set.contains($0.key) }
        }
        scheduleSave()
    }

    // MARK: Navigation history

    /// Call `visit` when the user moves from `from` to a different note.
    func visit(from: NoteID?, to: NoteID) {
        guard from != to else { return }
        if let from, back.last != from { back.append(from) }
        if back.last == to { back.removeLast() }  // A -> B -> A shouldn't leave A on top of the back stack
        if back.count > Self.historyLimit { back.removeFirst(back.count - Self.historyLimit) }
        forward.removeAll()
        scheduleSave()
    }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func goBack(current: NoteID?) -> NoteID? {
        while let id = back.popLast() {
            guard id != current else { continue }
            if let current, forward.last != current { forward.append(current) }
            scheduleSave()
            return id
        }
        return nil
    }

    func goForward(current: NoteID?) -> NoteID? {
        while let id = forward.popLast() {
            guard id != current else { continue }
            if let current, back.last != current { back.append(current) }
            scheduleSave()
            return id
        }
        return nil
    }

    // MARK: Consistency

    /// Keep state consistent when notes go away or move.
    func forget(_ id: NoteID) {
        pins.removeAll { $0 == id }
        back = Self.dedupeConsecutive(back.filter { $0 != id })
        forward = Self.dedupeConsecutive(forward.filter { $0 != id })
        viewStates[id] = nil
        frec[id] = nil
        if lastOpenID == id { lastOpenID = nil }
        scheduleSave()
    }

    func rename(from: NoteID, to: NoteID) {
        guard from != to else { return }
        var seen = Set<NoteID>()
        pins = pins.map { $0 == from ? to : $0 }.filter { seen.insert($0).inserted }
        back = Self.dedupeConsecutive(back.map { $0 == from ? to : $0 })
        forward = Self.dedupeConsecutive(forward.map { $0 == from ? to : $0 })
        if let vs = viewStates.removeValue(forKey: from) { viewStates[to] = vs }
        if let f = frec.removeValue(forKey: from) { frec[to] = f }
        if lastOpenID == from { lastOpenID = to }
        scheduleSave()
    }

    private static func dedupeConsecutive(_ a: [NoteID]) -> [NoteID] {
        var out: [NoteID] = []
        for x in a where out.last != x { out.append(x) }
        return out
    }

    // MARK: Persistence

    private func snapshot() -> Data? {
        let p = Persisted(pins: pins, lastOpenID: lastOpenID, viewStates: viewStates, back: back, forward: forward, frecency: frec)
        return try? JSONEncoder().encode(p)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, let data = self.snapshot() else { return }
            self.saveTask = nil
            let url = self.fileURL
            await Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }.value
        }
    }

    /// Writes pending state synchronously. Call on app termination.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = snapshot() else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
