import AppKit

/// The app's brain: wires the editor bridge to the store, app state, search, and the panel.
final class Coordinator {
    let env: LaunchEnvironment
    let prefs: Preferences
    let store: NoteStore
    let web: WebHost
    let panel: PanelController
    private(set) var state: AppState
    private(set) var search: SearchService
    var onOpenSettings: (() -> Void)?

    // Open note
    private(set) var currentID: NoteID? {
        didSet { if currentID != oldValue { watchLinkTarget() } }
    }
    /// The open note's symlink target (it can live outside the watched folder): external edits there refresh it live.
    private var linkWatcher: (id: NoteID, watcher: FileWatcher)?
    /// Brand-new note that doesn't have a file yet (becomes one once it has non-whitespace content).
    private(set) var currentIsNew = false
    /// Own-copy pastes in flight → whether another one ran at the same time.
    private var ownPastes: [UUID: Bool] = [:]
    /// Own-copy pastes handed to the editor, awaiting its `pasteResult` (reservation token → the files written for it, and
    /// whether another paste may be using them).
    private var awaitingInsert: [String: (files: [URL], shared: Bool)] = [:]
    private var currentContent = ""
    /// Late saves addressed to a renamed note go to its new id.
    private var renamed: [NoteID: NoteID] = [:]
    /// All note ids in the folder (for the frecency map passed to search).
    private var knownIDs: Set<NoteID> = []
    /// Navigation/external-change work runs strictly in order.
    private var queue: Task<Void, Never>?
    // Text held outside the notes folder. Each is mirrored into a recovery file the moment it's held (see `syncHeld`):
    // these properties are a cache of that durable copy, which goes away only once the text is in the folder.
    /// Last save that failed (its content is the only copy until a retry succeeds).
    private var failedSave: (id: NoteID, content: String)? { didSet { syncHeld() } }
    private var folderMissing = false
    /// Notes left (⌘N, another note) while the notes folder was missing: their files went with it, the editor's text is
    /// all there is. Written back when the folder returns (see `.folderAvailable`).
    private var lostWithFolder: [NoteID: String] = [:] { didSet { syncHeld() } }
    /// Text taken when the missing folder came back, waiting (a moment, see `.folderAvailable`) to be re-saved into it.
    /// Held here rather than in the delayed task: a folder switch or quit before then writes it first (`keepResaves`).
    /// Reopening such a note shows this text, never the folder's version over it (`editorText`).
    private var resaves: [NoteID: String] = [:] {
        didSet {
            syncHeld()
            if !overRestored.isEmpty { overRestored.formIntersection(resaves.keys) }
        }
    }
    /// `resaves` taken from the open note's editor (its text when the folder came back): that text stays the note wherever
    /// it's settled — written over the restored file, which is kept as the copy — even once another note is open.
    private var overRestored: Set<NoteID> = []
    /// The open note's re-save into the restored folder failed: tried again (backoff) while it stays open.
    private var resaveRetry: Task<Void, Never>?
    private var resaveRetryID: NoteID?
    /// Unsaved text handed to recovery at a quit or folder switch (the editor's, read then) — imported on next launch.
    private var handedToRecovery: [NoteID: String] = [:] { didSet { syncHeld() } }
    /// NSPasteboard.changeCount last mirrored into the editor (vim's unnamed register) or written by us.
    private var seenPasteboardChange = -1
    /// NSPasteboard.changeCount a vim put of our own copy read live (`.pasteOwnCopy`): what it put is current.
    private var putReadPasteboardChange = -1
    /// While the panel is key: a look at the pasteboard each second (see `watchClipboard`).
    private var clipboardWatch: Task<Void, Never>?
    /// The last ⌘⇧C copy of a note with images, for vim's `p` (see `.pasteOwnCopy`).
    private var lastOwnCopy: ClipboardExport.OwnCopy?
    /// Renders ⌘⇧C's picture of a note with images.
    private let noteSnapshot = NoteSnapshot()
    /// Notes the editor was handed since the last folder switch. A save for any other id is a stale editor session
    /// from the previous folder (ids are only unique within a folder) and is rejected instead of written here.
    private var presentedIDs: Set<NoteID> = []
    /// Toasts raised while the panel is hidden (or the page not ready): shown on the next show.
    private var queuedToasts: [(message: String, tone: ToastTone)] = []
    /// Newest note imported from recovery at launch: it's what the first show presents.
    private var recoveredToOpen: NoteID?
    /// Notes this app moved to the Trash: a late save for one is acknowledged, not written (no resurrection).
    private var trashedIDs: Set<NoteID> = []
    /// Unreadable note files already reported this launch (file name).
    private var reportedUnreadable: Set<String> = []

    init(env: LaunchEnvironment, prefs: Preferences) {
        self.env = env
        self.prefs = prefs
        NoteStore.warn = { Log.warn($0) }
        store = NoteStore(folder: prefs.notesFolder)
        let dir = env.stateDirectory(for: prefs.notesFolder)
        state = AppState(directory: dir)
        search = SearchService(indexDirectory: dir.appendingPathComponent("index", isDirectory: true))
        panel = PanelController(prefs: prefs)
        panel.automationMode = env.isAutomation
        let store = store
        web = WebHost(resolveNote: { store.resolve(relativePath: $0) }, automation: env.isAutomation)
        panel.setContent(web.webView)

        web.onMessage = { [unowned self] in await handle($0) }
        web.webView.onPasteImages = { [unowned self] in pasteImages($0) }
        web.webView.onPasteText = { [unowned self] in web.send(.insertText($0, block: false)) }
        web.webView.onPasteOwnCopy = { [unowned self] in pasteOwnCopy($0) }
        web.webView.onPasteSearchText = { [unowned self] in web.send(.searchText($0)) }
        store.onEvent = { [unowned self] in handleStoreEvent($0) }
        store.onRevisionRead = { [unowned self] note in
            knownIDs.insert(note.id)
            let search = search
            Task { await search.upsert(IndexedNote(id: note.id, content: note.content, modified: note.modified)) }
        }
        panel.onBecameKey = { [unowned self] in
            syncSystemClipboard()
            watchClipboard()
        }
        // Before a key reaches the editor: a vim put (`p`, `"+P`, ⌃R +) reads the pasteboard as it is now.
        panel.onKeyDown = { [unowned self] in syncSystemClipboard() }
        panel.onClose = { [unowned self] in hide() }
        panel.onHeaderAction = { [unowned self] in web.send(.runAction($0)) }
        web.webView.pageZoom = prefs.pageZoom
    }

    func start() {
        importRecovery()
        web.load()
        reindexAll()
    }

    // MARK: Panel actions (hotkeys, menu bar, URL scheme, automation)

    func toggle() {
        if panel.isVisible && panel.isKey { hide() } else { show() }
    }

    func show() {
        panel.show()
        web.send(.focus)
        deliverQueuedToasts()
        // A symlinked note's target can live outside the watched folder: look at it again whenever the panel shows
        // (and follow the link if it was pointed elsewhere meanwhile).
        watchLinkTarget()
        if let id = currentID, !currentIsNew, let url = store.fileURL(id), NoteRegistry.symlinkTarget(url) != nil,
           let disk = store.unacknowledgedChange(id) {
            handleStoreEvent(.changed(id: id, content: disk))
        }
    }

    /// Watch the open note's symlink target, if it is one (stops watching the previous note's). Re-resolved on every
    /// store event and show: a link retargeted to another file swaps the watcher; an unchanged target keeps it. Only while
    /// the panel is up: hide stops it, show re-reads the target anyway.
    private func watchLinkTarget() {
        let target = panel.isVisible ? currentID.flatMap { store.fileURL($0) }.flatMap { NoteRegistry.symlinkTarget($0) } : nil
        if let current = linkWatcher, current.id == currentID, current.watcher.path == target?.path { return }
        linkWatcher?.watcher.stop()
        linkWatcher = nil
        guard let id = currentID, let target else { return }
        linkWatcher = (id, FileWatcher(path: target.path) { [weak self] in self?.linkTargetChanged(id) })
        Log.info("watching symlinked note \(id) → \(target.path)")
    }

    /// Same path as an external edit inside the folder: applied when the editor is clean, else kept as a conflict copy.
    private func linkTargetChanged(_ id: NoteID) {
        guard id == currentID, let disk = store.unacknowledgedChange(id) else { return }
        handleStoreEvent(.changed(id: id, content: disk))
    }

    /// Toasts are only sent to a visible, ready page; anything else waits for the next show.
    private func toast(_ message: String, _ tone: ToastTone) {
        guard panel.isVisible, web.isReady else {
            if !queuedToasts.contains(where: { $0.message == message }) { queuedToasts.append((message, tone)) }
            if queuedToasts.count > 3 { queuedToasts.removeFirst(queuedToasts.count - 3) }
            return Log.info("toast queued until shown: \(message)")
        }
        web.send(.toast(message: message, tone: tone))
    }

    private func deliverQueuedToasts() {
        guard panel.isVisible, web.isReady, !queuedToasts.isEmpty else { return }
        let toasts = queuedToasts
        queuedToasts = []
        // The page shows one toast at a time: the last (most important — errors are queued after info) wins.
        for t in toasts { web.send(.toast(message: t.message, tone: t.tone)) }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.hide()
        watchLinkTarget()  // stops it
        Task { await web.flush() }
    }

    func newNote() {
        if panel.isVisible {
            show()
            navigate(.new)
        } else {
            // Swap the note first so the panel never flashes the previous one.
            navigate(.new) { [weak self] in self?.show() }
        }
    }

    func openSearch() {
        show()
        web.send(.openSearch)
    }

    func open(_ id: NoteID) {
        guard NoteStore.isValidID(id) else {
            Log.warn("open: rejected invalid note id \(id.debugDescription)")
            return toast("Invalid note link", .error)
        }
        guard store.exists(id) else { return Log.warn("open: no note \(id)") }
        if panel.isVisible { show(); navigate(.note(id)) } else { navigate(.note(id)) { [weak self] in self?.show() } }
    }

    func settingsChanged(_ change: Preferences.Change) {
        switch change {
        case .vim:
            web.send(.settings(prefs.editorSettings))
            seenPasteboardChange = -1
            if panel.isKey {
                syncSystemClipboard()
                watchClipboard()
            }
        case .hideFromCapture: panel.applyCaptureSetting()
        case .notesFolder: switchFolder(to: prefs.notesFolder)
        case .hotkeys: break
        }
    }

    /// Flush the editor and drop an empty note before quitting. Text that can't be saved goes to a recovery
    /// directory (see `LaunchEnvironment.recoveryDirectories`). false = it couldn't be kept anywhere: don't quit.
    func prepareForQuit() async -> Bool {
        let outcome = await web.flush()
        var kept = true
        switch outcome {
        case .ok, .notReady:
            cleanupIfEmpty(currentID)
        case .failed, .timedOut:
            // timedOut: the page may be hung — recover only what's known to be unsaved.
            if let id = currentID {
                let failed = failedSave?.id == id ? failedSave?.content : nil
                let live = await web.editorContent()
                let unsaved = if case .failed = outcome { true } else { failed != nil }
                if unsaved, let content = live ?? failed {
                    if !content.isBlank { kept = writeRecovery(id: id, content: content) }
                } else if unsaved, case .failed = outcome {
                    kept = false  // the editor still holds text we can't read: keep the app (and it) alive
                }
            }
        }
        // The open note's file went with a still-missing folder (its buffer was clean): the editor's text is all there is.
        let flushed = switch outcome { case .ok, .notReady: true; case .failed, .timedOut: false }
        if flushed, folderMissing, let id = currentID, !currentIsNew, !store.exists(id) { takeOpenText(id) }
        kept = keepResaves(leaving: true) && kept
        // Everything still held (failed saves, pending re-saves, notes lost with the folder) must be in recovery.
        kept = syncHeld() && kept
        state.flush()
        return kept
    }

    /// Quit fallback when `prepareForQuit` hasn't finished (page hung): keep the last known unsaved text, if any.
    /// false = it couldn't be kept: don't quit.
    func recoverForForcedQuit() -> Bool {
        if let id = currentID, resaves[id] != nil { resaves[id] = openText(id) }
        return syncHeld()
    }

    /// Quit was cancelled because unsaved text couldn't be kept anywhere: leave it on screen and say so.
    func quitCancelled() {
        show()
        toast("Can’t save or back up this note — quit cancelled", .error)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: Held text (recovery)

    /// Held text → its recovery file. Key = note id plus the slot it's held in (`heldTexts`).
    private var heldFiles: [String: (url: URL, id: NoteID, text: String)] = [:]
    /// Keys whose text no recovery directory took (retried on every change; a switch or quit with any is cancelled).
    private var unheld: Set<String> = []
    private var heldSyncPaused = false

    /// Everything held outside the notes folder, by slot. A text already held for the same note isn't held twice.
    private var heldTexts: [String: (id: NoteID, text: String)] {
        var out: [String: (id: NoteID, text: String)] = [:]
        var texts: [NoteID: [String]] = [:]
        func hold(_ id: NoteID, _ text: String?, _ slot: String) {
            guard let text, !text.isBlank, texts[id]?.contains(text) != true else { return }
            texts[id, default: []].append(text)
            out[id + slot] = (id, text)
        }
        for (id, text) in resaves { hold(id, text, "") }
        for (id, text) in lostWithFolder { hold(id, text, resaves[id] == nil ? "" : "/lost") }
        if let failedSave { hold(failedSave.id, failedSave.content, "/failed") }
        for (id, text) in handedToRecovery { hold(id, text, "/quit") }
        return out
    }

    /// Mirrors `heldTexts` into recovery files: writes new or changed ones (each slot keeps its file), removes those no
    /// longer held — their text is in the notes folder now, superseded by a later save, or blank. A file whose new text
    /// can't be written keeps its previous one. false = some held text is in no recovery file.
    @discardableResult
    private func syncHeld() -> Bool {
        guard !heldSyncPaused else { return unheld.isEmpty }
        let want = heldTexts
        // New files first: a slot's file is only rewritten once a text moved out of it is in its own.
        for (key, entry) in want.sorted(by: { (heldFiles[$0.key] == nil ? 0 : 1, $0.key) < (heldFiles[$1.key] == nil ? 0 : 1, $1.key) }) {
            if let have = heldFiles[key], have.text == entry.text { continue }
            if let url = writeHeldFile(entry.id, entry.text, replacing: heldFiles[key]?.url, quiet: unheld.contains(key)) {
                heldFiles[key] = (url, entry.id, entry.text)
                unheld.remove(key)
            } else {
                unheld.insert(key)
            }
        }
        for (key, file) in heldFiles where want[key] == nil {
            heldFiles[key] = nil
            do { try FileManager.default.removeItem(at: file.url) } catch {
                Log.error("recovery: couldn't remove \(file.url.lastPathComponent): \(error.localizedDescription)")
            }
            Log.info("recovery: \(file.id) no longer held — removed \(file.url.lastPathComponent)")
        }
        unheld.formIntersection(want.keys)
        return unheld.isEmpty
    }

    /// `<id>-<stamp>[-n].md` in the first recovery directory that takes it (the existing file first). nil if none did.
    private func writeHeldFile(_ id: NoteID, _ text: String, replacing existing: URL?, quiet: Bool) -> URL? {
        let fm = FileManager.default
        let data = Data(text.utf8)
        if let existing, (try? data.write(to: existing, options: .atomic)) != nil { return existing }
        let stamp = Self.timestamp()
        for dir in env.recoveryDirectories {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var n = 1
                var url: URL
                repeat {
                    url = dir.appendingPathComponent(NoteStore.fittedID(id, suffix: "-\(stamp)\(n == 1 ? "" : "-\(n)")") + ".md")
                    n += 1
                } while fm.fileExists(atPath: url.path)
                try data.write(to: url, options: .atomic)
                if let existing { try? fm.removeItem(at: existing) }
                Log.warn("unsaved note \(id) held in recovery: \(url.path)")
                return url
            } catch {
                if !quiet { Log.error("recovery write failed for \(id) in \(dir.path): \(error.localizedDescription)") }
            }
        }
        return nil
    }

    /// Whether `content` for `id` is in a recovery file (or the notes folder has to take it). Not held in any slot yet:
    /// held as handed to recovery (quit/switch).
    private func writeRecovery(id: NoteID, content: String) -> Bool {
        if content.isBlank { return true }
        if !heldTexts.values.contains(where: { $0.id == id && $0.text == content }) { handedToRecovery[id] = content }
        syncHeld()
        return heldFiles.values.contains { $0.id == id && $0.text == content }
    }

    /// Folder switch: everything held is in recovery files now (checked by the caller) — they stay for the next
    /// launch's import, no longer tracked by this session.
    private func handOffHeld() {
        heldSyncPaused = true
        resaves = [:]
        lostWithFolder = [:]
        failedSave = nil
        handedToRecovery = [:]
        heldFiles = [:]
        unheld = []
        heldSyncPaused = false
    }

    /// Launch: text that couldn't be saved before the last quit (`recovery/<id>-<stamp>[-n].md`) becomes its own note,
    /// `<id>-recovered-<stamp>.md`, in the current folder. A recovery file is removed only once its note is written —
    /// or when a note here already holds exactly its text (written there, then the app stopped before removing it).
    private func importRecovery() {
        let fm = FileManager.default
        let files = env.recoveryDirectories.flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.sorted()
                .map { dir.appendingPathComponent($0) }
        }
        guard !files.isEmpty else { return }
        var imported = 0, failed = 0
        var newest: (id: NoteID, stamp: String)?
        for url in files {
            let name = url.lastPathComponent
            guard let data = fm.contents(atPath: url.path), let content = String(data: data, encoding: .utf8) else {
                Log.error("recovery: can't read \(name)")
                failed += 1
                continue
            }
            let base = String(name.dropLast(3))
            let stamped = base.range(of: #"-\d{8}-\d{6}(-\d+)?$"#, options: .regularExpression)
            let original = stamped.map { String(base[..<$0.lowerBound]) } ?? base
            let stamp = stamped.map { String(base[$0].dropFirst().prefix(15)) } ?? Self.timestamp()
            if content.isBlank || store.list().contains(where: { $0.id.hasPrefix(original) && (try? store.peek($0.id).get()) == content }) {
                do { try fm.removeItem(at: url) } catch { Log.error("recovery: couldn't remove \(name): \(error.localizedDescription)") }
                Log.info("recovery: \(name) is already in the notes folder — removed")
                continue
            }
            var id = NoteStore.fittedID(original, suffix: "-recovered-\(stamp)", reserve: 4)
            var n = 2
            while store.exists(id) { id = NoteStore.fittedID(original, suffix: "-recovered-\(stamp)-\(n)"); n += 1 }
            // A name the store can't take (too long, `#…`/`~$…` prefix…) must not fail on every launch: fresh id instead.
            if !NoteStore.isValidID(id) { id = store.makeNewID() }
            switch store.write(id, content: content) {
            case .success:
                knownIDs.insert(id)
                imported += 1
                if newest == nil || stamp >= newest!.stamp { newest = (id, stamp) }
                do { try fm.removeItem(at: url) } catch { Log.error("recovery: imported \(name) as \(id) but couldn't remove it: \(error.localizedDescription)") }
                Log.info("recovery: imported \(name) as \(id)")
            case .failure(let error):
                Log.error("recovery: couldn't import \(name): \(error)")
                failed += 1
            }
        }
        recoveredToOpen = newest?.id
        if imported > 0 { toast("Recovered unsaved text — kept as a separate note", .info) }
        if failed > 0 { toast("Couldn't restore unsaved text — check the notes folder", .error) }
    }

    // MARK: Bridge

    func handle(_ message: ToSwift) async -> BridgeReply {
        // Note ids name files in the notes folder: anything that isn't a single valid file-name component is refused
        // before it reaches the store, the app state, or recovery (no current-note change).
        if let id = message.noteID, !NoteStore.isValidID(id) {
            Log.warn("bridge: rejected invalid note id \(id.debugDescription)")
            switch message {
            case .open, .viewState: return .success(nil)  // fire-and-forget: just a no-op
            default: return .failure(BridgeError("invalid note id"))
            }
        }
        switch message {
        case .ready:
            pageReady()
            return .success(nil)
        case .save(let id, let content):
            return save(id: id, content: content)
        case .viewState(let id, let viewState):
            state.setViewState(viewState, for: renamed[id] ?? id)
            return .success(nil)
        case .saveImage(let base64, let mime, let filename):
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
                return .failure(BridgeError("invalid base64 image"))
            }
            return store.saveAsset(data, ext: ImagePaste.ext(mime: mime, filename: filename))
                .map { ["path": $0] as Any? }
                .mapError { BridgeError("saveImage: \($0)") }
        case .search(let query):
            let hits = await search.search(query, context: rankingContext())
            return .success(Self.jsonObject(hits))
        case .headingVisible(let id, let endLine):
            if id == currentID { panel.strip.setVisibleHeading(through: endLine) }
            return .success(nil)
        case .open(let id, let passage):
            navigate(.note(id, passage: passage))
            return .success(nil)
        case .newNote:
            navigate(.new)
            return .success(nil)
        case .back:
            navigate(.back)
            return .success(nil)
        case .forward:
            navigate(.forward)
            return .success(nil)
        case .openPin(let index):
            guard state.pins.indices.contains(index) else { return .success(nil) }
            navigate(.note(state.pins[index]))
            return .success(nil)
        case .deleteNote(let id):
            if let error = await enqueueAndWait({ [self] in await delete(id) }) { return .failure(BridgeError(error)) }
            return .success(["ok": true])
        case .togglePin(let id):
            let index = state.togglePin(id)
            web.send(.pinState(id: id, pinned: index != nil, pinIndex: index))
            if id == currentID { panel.strip.setPinned(index != nil) }
            return .success(["pinned": index != nil, "pinIndex": index.map { $0 as Any } ?? NSNull()])
        case .copyNote(_, let markdown, let html, let images):
            var output = ClipboardExport.build(markdown: markdown, html: html, images: images, folder: store.folder) { [store] in store.resolve(relativePath: $0) }
            // A note with images: one picture of the whole note instead of the separate images (chat apps paste only an image).
            if !output.attachments.isEmpty {
                switch await noteSnapshot.png(html: output.html) {
                case .success(let png): output.snapshot = png
                case .failure(let error): Log.warn("copy note: snapshot failed (\(error.message)) — attaching the images instead")
                }
            }
            ClipboardExport.write(output)
            seenPasteboardChange = NSPasteboard.general.changeCount
            // Kept for vim's `p` in case the pasteboard moves on before the panel next becomes key (see `.pasteOwnCopy`).
            lastOwnCopy = output.images.isEmpty ? nil : ClipboardExport.OwnCopy(markdown: output.original, folder: output.folder, images: output.images, exported: output.markdown)
            // Vim's `p` pastes what ⌘V would: the note's own Markdown, not the self-contained export.
            if prefs.vimEnabled, output.original.utf8.count <= 1_000_000 {
                web.send(.systemClipboard(text: output.original, ownCopy: !output.images.isEmpty))
            }
            Log.info("copied note: md \(output.markdown.utf8.count)b, html \(output.html.utf8.count)b, \(output.inlinedImages) image(s) inlined, "
                + (output.snapshot.map { "snapshot \($0.count)b" } ?? "\(output.attachments.count) image(s) attached"))
            return .success(["ok": true])
        case .copyImage(let src, let folder):
            guard folder == folderKey else { return .failure(BridgeError("the notes folder changed")) }
            switch await ClipboardExport.copyImage(src, folder: store.folder) {
            case .success:
                lastOwnCopy = nil
                syncSystemClipboard()
                return .success(["ok": true])
            case .failure(let error): return .failure(error)
            }
        case .hide:
            hide()
            return .success(nil)
        case .zoom(let step):
            let zoom = EditorWebView.zoom(web.webView.pageZoom, step: step)
            web.webView.pageZoom = zoom
            prefs.pageZoom = zoom
            return .success(nil)
        case .searchOpen(let open):
            web.webView.searchOpen = open
            return .success(nil)
        case .pasteResult(let token, let inserted):
            pasteResult(token: token, inserted: inserted)
            return .success(nil)
        case .pasteOwnCopy(let token, let text):
            // Vim's register holds our own copy — as of when the panel last became key. Paste what the clipboard holds
            // now (clipboard=unnamed): our copy (its images come along, like ⌘V); other text copied since, by another app
            // while the panel stayed key; or, when the pasteboard has no text (or an empty string), the copy as
            // remembered from ⌘⇧C.
            let pb = NSPasteboard.general
            putReadPasteboardChange = pb.changeCount
            if let copy = ClipboardExport.ownCopy(pb) {
                pasteOwnCopy(copy, reservation: token)
            } else if let current = pb.string(forType: .string), !current.isEmpty, current != text, current.utf8.count <= 1_000_000 {
                Log.info("vim paste: the clipboard changed since the note copy — pasting its text")
                web.send(.insertText(current, block: false, token: token))
            } else if let copy = lastOwnCopy, copy.markdown == text {
                pasteOwnCopy(copy, reservation: token)
            } else {
                web.send(.insertText(text, block: false, token: token))
            }
            // (The register isn't refreshed here — Visual `p` is about to put the replaced text in it; each `p` resolves again.)
            return .success(nil)
        case .setClipboard(let text, let replaced):
            let pb = NSPasteboard.general
            // The text a Visual put replaced, from a put that went by a stale mirror (the pasteboard moved on before the
            // editor heard of it — the put didn't read it live either): the newer copy stays, and the editor hears of it.
            if replaced, pb.changeCount != seenPasteboardChange, pb.changeCount != putReadPasteboardChange {
                Log.info("vim put: the clipboard changed before the put saw it — keeping it, not the replaced text")
                syncSystemClipboard()
                return .success(nil)
            }
            pb.clearContents()
            pb.setString(text, forType: .string)
            seenPasteboardChange = pb.changeCount
            return .success(nil)
        case .openURL(let raw):
            openURL(raw)
            return .success(nil)
        case .openSettings:
            onOpenSettings?()
            return .success(nil)
        case .log(let level, let message):
            Log.level(level, "js: \(message)")
            return .success(nil)
        }
    }

    private func pageReady() {
        web.send(.`init`(settings: prefs.editorSettings))
        // A fresh page has an empty vim register: hand it the clipboard now if the panel is already key.
        seenPasteboardChange = -1
        if panel.isKey { syncSystemClipboard() }
        enqueue { [self] in
            if let id = currentID, !currentIsNew, case .success(let content) = editorText(id) {
                present(id, isNew: false, content: content)
            } else if let id = currentID, currentIsNew {
                present(id, isNew: true, content: currentContent)
            } else if let id = recoveredToOpen, case .success(let content) = store.read(id) {
                // Launch imported unsaved text: that's what the user is looking for.
                state.recordOpen(id)
                present(id, isNew: false, content: content)
            } else {
                presentInitial()
            }
            recoveredToOpen = nil
            reportUnreadable(store.skipped)
            deliverQueuedToasts()
        }
    }

    /// Last open note, else newest, else a fresh one.
    private func presentInitial() {
        if let id = state.lastOpenID, case .success(let content) = editorText(id) {
            present(id, isNew: false, content: content)
        } else if let id = newestID(excluding: nil), case .success(let content) = editorText(id) {
            present(id, isNew: false, content: content)
        } else {
            present(store.makeNewID(), isNew: true, content: "")
        }
    }

    private func save(id rawID: NoteID, content: String) -> BridgeReply {
        var id = renamed[rawID] ?? rawID
        guard presentedIDs.contains(rawID) || presentedIDs.contains(id) else {
            Log.warn("save \(rawID): rejected — stale editor session from before the folder switch")
            return .failure(BridgeError("stale: \(rawID) isn't a note in this folder's session"))
        }
        // Renamed elsewhere a moment ago, before the watcher reported it: the save follows the file to its new name (the
        // rename is taken now) — it never writes the old name back or takes the renamed file for an unseen edit.
        if !(id == currentID && currentIsNew), !store.existsExactly(id), let to = store.adoptRename(of: id) {
            Log.info("save \(id): its file was renamed to \(to) — saving there")
            handleStoreEvent(.renamed(from: id, to: to))
            id = to
        }
        if id == currentID {
            currentContent = content
            panel.setStrip(content: content)
            if currentIsNew && content.isBlank { return .success(["ok": true]) }
        } else if !store.exists(id), content.isBlank || trashedIDs.contains(id) {
            // Late save for a note we trashed, or one that's gone and had nothing to keep — don't resurrect it.
            return .success(["ok": true])
        }
        // The file was removed/renamed away elsewhere while the editor still had edits: those edits are only in the
        // editor — write them back (the note reappears) rather than acknowledge bytes that were never written.
        let recreating = !(id == currentID && currentIsNew) && !store.exists(id)
        let restoring = id == currentID && resaves[id] != nil
        switch store.write(id, content: content) {
        case .success(let result):
            if failedSave?.id == id { failedSave = nil }
            // The open note's session started from any text held for it (see `editorText`): it's in the folder now.
            if id == currentID { dropHeld(id) }
            if recreating {
                trashedIDs.remove(id)
                Log.warn("note \(id) was removed elsewhere with unsaved edits — re-saved it")
                toast("Note was removed elsewhere — kept your edits", .info)
            }
            if id == currentID {
                currentIsNew = false
            }
            knownIDs.insert(id)
            state.recordEdit(id)
            let note = IndexedNote(id: id, content: content, modified: result.meta.modified)
            let search = search
            Task { await search.upsert(note) }
            if let copy = result.conflictCopy { keptConflictCopy(copy, of: id, restored: restoring) }
            return .success(["ok": true])
        case .failure(let error):
            // A pending re-save of the open note: this text supersedes it (one held copy, not two).
            if id == currentID, resaves[id] != nil { resaves[id] = content }
            failedSave = (id, content)
            Log.error("save \(id): \(error)")
            return .failure(BridgeError(saveErrorMessage(error)))
        }
    }

    private func saveErrorMessage(_ error: StoreError? = nil) -> String {
        if case .folderMissing? = error { return "Notes folder is missing" }
        if !store.folderExists { return "Notes folder is missing" }
        return "Couldn't save — check the notes folder"
    }

    /// A disk version we hadn't seen was kept as its own note. `restored`: it came back with the notes folder.
    private func keptConflictCopy(_ copy: NoteMeta, of id: NoteID, restored: Bool = false) {
        knownIDs.insert(copy.id)
        if case .success(let content) = store.peek(copy.id) {
            let search = search
            let note = IndexedNote(id: copy.id, content: content, modified: copy.modified)
            Task { await search.upsert(note) }
        }
        Log.warn("conflict on \(id): disk version kept as \(copy.id)")
        toast(restored ? "Restored note differs — kept both versions" : "Edited elsewhere — kept both versions", .info)
    }

    /// Flush before replacing the editor's note. false (after telling the user) when the editor's buffer couldn't be
    /// saved: the caller must keep it on screen.
    private func flushBeforeLeaving(toast: Bool = true) async -> Bool {
        guard case .failed = await web.flush() else { return true }
        if toast { self.toast(saveErrorMessage(), .error) }
        return false
    }

    // MARK: Navigation

    enum Destination: Equatable { case note(NoteID, passage: SearchPassage? = nil), new, back, forward }

    func navigate(_ destination: Destination, then: (() -> Void)? = nil) {
        enqueue { [self] in
            guard await flushBeforeLeaving() else {
                then?()
                return
            }
            let previous = currentID
            switch destination {
            case .new:
                // Already on a blank new note: still a fresh id (the blank one is forgotten below), so the editor
                // seeds a create-from-search query instead of keeping the empty buffer.
                let id = store.makeNewID()
                state.visit(from: previous, to: id)
                cleanupIfEmpty(previous)
                present(id, isNew: true, content: "")
            case .note(let id, let passage):
                guard id != previous else {
                    if let passage { present(id, isNew: currentIsNew, content: currentContent, passage: passage) }
                    else { web.send(.focus) }
                    break
                }
                let read = editorText(id)
                guard case .success(let content) = read else {
                    Log.warn("open: can't read \(id): \(read)")
                    if case .failure(.io(let reason)) = read { reportUnreadable([reason.replacingOccurrences(of: "unreadable: ", with: "")]) }
                    break
                }
                state.visit(from: previous, to: id)
                cleanupIfEmpty(previous)
                state.recordOpen(id)
                present(id, isNew: false, content: content, passage: passage)
            case .back, .forward:
                let step = { (current: NoteID?) in destination == .back ? self.state.goBack(current: current) : self.state.goForward(current: current) }
                var target = step(previous)
                while let t = target, t == previous { target = step(nil) }  // skip self-entries left by forgotten notes
                guard let target else {
                    web.send(.navState(canGoBack: state.canGoBack, canGoForward: state.canGoForward))
                    break
                }
                cleanupIfEmpty(previous)
                if case .success(let content) = editorText(target) {
                    state.recordOpen(target)
                    present(target, isNew: false, content: content)
                } else {
                    state.forget(target)
                    web.send(.navState(canGoBack: state.canGoBack, canGoForward: state.canGoForward))
                }
            }
            then?()
        }
    }

    private func present(_ id: NoteID, isNew: Bool, content: String, passage: SearchPassage? = nil) {
        // Leaving a note whose file went with the missing folder (its buffer was clean — else the flush would have kept it
        // on screen): keep its text for when the folder is back.
        if folderMissing, let previous = currentID, previous != id, !currentIsNew, !store.exists(previous) {
            let text = openText(previous)
            if !text.isBlank { lostWithFolder[previous] = text }
        }
        renamed[id] = nil  // once the editor shows this id, its saves mean this id
        presentedIDs.insert(id)
        if id != currentID { panel.strip.resetHeadingVisibility() }
        currentID = id
        currentIsNew = isNew
        currentContent = content
        state.lastOpenID = id
        let pin = state.pinIndex(id)
        web.send(.loadNote(NotePayload(
            id: id, content: content, pinned: pin != nil, pinIndex: pin, isNew: isNew,
            viewState: isNew ? nil : state.viewState(for: id),
            canGoBack: state.canGoBack, canGoForward: state.canGoForward, folder: folderKey, passage: passage)))
        web.send(.navState(canGoBack: state.canGoBack, canGoForward: state.canGoForward))
        panel.setStrip(content: content, pinned: pin != nil)
        // Showing text that couldn't go into the (restored) folder yet (see `editorText`): it's the editor's now.
        if !isNew, !folderMissing, resaves[id] != nil {
            overRestored.insert(id)
            resaveFailed(id)
        }
    }

    /// Stable per-folder key for the editor (relative `assets/x.png` differs per folder).
    private var folderKey: String { String(Text.hash64(store.folder.standardizedFileURL.path), radix: 36) }

    /// Leaving a note with no real content removes its file (no clutter).
    private func cleanupIfEmpty(_ id: NoteID?) {
        guard let id, id == currentID, currentContent.isBlank else { return }
        if store.exists(id) {
            guard case .success(let disk) = store.peek(id), disk.isBlank else { return }
            if case .failure(let error) = store.removeEmpty(id) { return Log.error("remove empty note \(id): \(error)") }
            Log.info("removed empty note \(id)")
        }
        knownIDs.remove(id)
        state.forget(id)
        let search = search
        Task { await search.remove(id) }
    }

    /// nil on success, else the error message (the bridge reply rejects with it; the editor shows the error).
    private func delete(_ id: NoteID) async -> String? {
        if id == currentID {
            if !(await flushBeforeLeaving(toast: false)) { return saveErrorMessage() }
            // The editor stops saving once it asks for a delete, so edits inside the autosave debounce may not have
            // reached disk: the Trash must hold what was on screen. Write it first; if that fails, don't delete.
            if let live = await web.editorContent(), !live.isBlank {
                let disk = store.exists(id) ? (try? store.peek(id).get()) : nil
                if live != disk {
                    if case .failure(let error) = store.write(id, content: live) {
                        Log.error("delete \(id): couldn't save the latest edits first: \(error)")
                        return saveErrorMessage(error)
                    }
                    Log.info("delete \(id): saved \(live.utf8.count)b of pending edits before trashing")
                }
            }
        }
        if store.exists(id) {
            switch store.trash(id) {
            case .success(let landed): Log.info("trashed \(id)\(landed.map { " → \($0.path)" } ?? "")")
            case .failure(let error):
                Log.error("trash \(id): \(error)")
                return store.folderExists ? "Couldn't move the note to the Trash" : "Notes folder is missing"
            }
        }
        if failedSave?.id == id { failedSave = nil }
        // The open note's text (it started from anything held for it) is what went to the Trash.
        if id == currentID { dropHeld(id) }
        trashedIDs.insert(id)
        knownIDs.remove(id)
        state.forget(id)
        await search.remove(id)
        guard id == currentID else { return nil }
        currentID = nil
        presentNext(excluding: id)
        return nil
    }

    private func presentNext(excluding id: NoteID?) {
        if let next = newestID(excluding: id), case .success(let content) = editorText(next) {
            state.recordOpen(next)
            present(next, isNew: false, content: content)
        } else {
            present(store.makeNewID(), isNew: true, content: "")
        }
    }

    /// Newest note by modification date (cached listing — same file policy as the store).
    private func newestID(excluding: NoteID?) -> NoteID? {
        store.list().first { $0.id != excluding }?.id
    }

    // MARK: External changes

    private func handleStoreEvent(_ event: StoreEvent) {
        // The open note's file may have been replaced by a link elsewhere (or stopped being one).
        watchLinkTarget()
        switch event {
        case .changed(let id, let content):
            let search = search
            Task { await search.upsert(IndexedNote(id: id, content: content, modified: Date())) }
            guard id == currentID else { return }
            enqueue { [self] in await applyDiskChange(id) }
        case .folderAvailable(let available):
            folderMissing = !available
            if available {
                Log.info("notes folder is back: \(store.folder.path)")
                queuedToasts.removeAll { $0.message == "Notes folder is missing" }
                // Came back without the open note (recreated/emptied): the editor's copy is the note — put it back. A
                // moment later, so a restore that copies file by file (`cp -R`, a sync client) gets to write it first; if
                // it still turns up mid-write, the store won't replace it unseen (see `NoteRegistry.write`). Notes left
                // while it was missing too, and the open one even if another is opened meanwhile: the text is taken now.
                // The open note also when its file came back: an older copy (a backup, a sync client) must not
                // silently replace the editor's text (`keepResaves` / `.changed` keep both).
                resaves.merge(lostWithFolder) { _, lost in lost }
                lostWithFolder = [:]
                if let id = currentID, !currentIsNew { takeOpenText(id) }
                guard !resaves.isEmpty else { return }
                let folder = store.folder
                Task { [self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    enqueue { [self] in
                        // Switched away meanwhile: the switch wrote them (`keepResaves(leaving:)`).
                        guard store.folder == folder else { return }
                        _ = keepResaves(leaving: false)
                    }
                }
            } else {
                Log.error("notes folder is missing: \(store.folder.path)")
                toast("Notes folder is missing", .error)
            }
        case .added(let id):
            renamed[id] = nil  // a file at a renamed-away id is a different note now
            knownIDs.insert(id)
            trashedIDs.remove(id)
            if case .success(let content) = store.peek(id) {
                let note = IndexedNote(id: id, content: content, modified: store.meta(id)?.modified ?? Date())
                let search = search
                Task { await search.upsert(note) }
            }
            // The open note's file came back with the folder (reported as new when its removal was seen first): as a change.
            if id == currentID, resaves[id] != nil { enqueue { [self] in await applyDiskChange(id) } }
        case .removed(let id):
            knownIDs.remove(id)
            let search = search
            Task { await search.remove(id) }
            guard id == currentID, !currentIsNew else { return state.forget(id) }
            enqueue { [self] in
                guard id == currentID, !store.exists(id) else { return }
                // Edits the editor hasn't saved yet go through the save path first: for the open note that writes the
                // file back (see `save`), and it stays open. If they can't be written, the editor keeps them.
                guard await flushBeforeLeaving() else { return }
                guard id == currentID, !store.exists(id) else { return }
                state.forget(id)
                currentID = nil
                presentNext(excluding: id)
            }
        case .assetsChanged(let paths):
            // Open notes showing these files reload them (or show the missing-image chip).
            web.send(.assetsChanged(paths: paths))
        case .unreadable(let reason):
            Log.warn("skipping note file \(reason)")
            reportUnreadable([reason])
        case .renamed(let from, let to):
            state.rename(from: from, to: to)
            knownIDs.remove(from)
            knownIDs.insert(to)
            // Only in-flight saves of the session that had `from` open may be redirected. `to` is now a real note under
            // its own id, and chains collapse (A→B then B→A must leave saves for A in A).
            renamed[to] = nil
            for (key, value) in renamed where value == from { renamed[key] = key == to ? nil : to }
            renamed[from] = to
            if presentedIDs.contains(from) {
                presentedIDs.insert(to)
                web.send(.retarget(from: from, to: to))
            }
            // Unsaved text that failed to save under `from` belongs to `to` now (a later save there clears it).
            if failedSave?.id == from { failedSave?.id = to }
            if let text = handedToRecovery.removeValue(forKey: from) { handedToRecovery[to] = text }
            let editors = overRestored.contains(from)
            if let text = resaves.removeValue(forKey: from) {
                resaves[to] = text
                if editors { overRestored.insert(to) }
            }
            if let text = lostWithFolder.removeValue(forKey: from) { lostWithFolder[to] = text }
            let search = search
            Task { await search.rename(from: from, to: to) }
            guard from == currentID else { return }
            // The editor goes on as `to` (`retarget`): nothing reloads, so keys typed meanwhile, the undo history and pending
            // saves stay — saves already sent for `from` land in the renamed file (see `renamed`).
            currentID = to
            web.send(.navState(canGoBack: state.canGoBack, canGoForward: state.canGoForward))
            // Text held for it from the folder's return goes on as `to`'s (as when it's opened, see `editorText`).
            if !folderMissing, resaves[to] != nil {
                _ = settleResave(to, leaving: false)
                if resaves[to] != nil { resaveFailed(to) }
            }
            // Renamed with other content than we knew (written as it was moved): the same as an external edit.
            if store.unacknowledgedChange(to) != nil { enqueue { [self] in await applyDiskChange(to) } }
        }
    }

    /// The open note's file changed on disk (an external edit, a restored folder): applied when the editor is clean,
    /// else kept as a conflict copy.
    private func applyDiskChange(_ id: NoteID) async {
        guard id == currentID else { return }
        // Pending edits go through the save path first (it keeps the disk version as a copy if needed);
        // then only a disk revision nobody has handled yet is left to apply.
        await web.flush()
        guard id == currentID, let disk = store.unacknowledgedChange(id) else { return }
        if disk == currentContent { return store.acknowledge(id, content: disk) }
        // The folder came back with this note at another version than the editor's (a re-save is pending, see
        // `keepResaves`): the editor's text stays the note — written over it, the restored file kept next to it as a
        // copy — the same as when an edit was pending (the save path). If that can't be written, nothing is applied:
        // the editor keeps its text and the re-save stays pending.
        if resaves[id] != nil {
            _ = settleResave(id, leaving: false)
            return
        }
        switch await web.applyExternal(id: id, content: disk) {
        case true?:
            store.acknowledge(id, content: disk)
            currentContent = disk
            panel.setStrip(content: disk)
            Log.info("applied external change to \(id)")
        case false?:
            // Editor has unsaved edits: it wins, the disk version is kept as a separate note.
            guard store.unacknowledgedChange(id) == disk else { return }  // a save already kept it
            switch store.saveConflictCopy(of: id, content: disk) {
            case .success(let copy):
                store.acknowledge(id, content: disk)
                keptConflictCopy(copy, of: id)
            case .failure(let error):
                Log.error("conflict copy for \(id) failed: \(error)")
            }
        case nil:
            Log.warn("external change to \(id) not applied (page unavailable)")
        }
    }

    // MARK: Folder

    /// The open note's latest text (edits since a failed save went through the save path).
    private func openText(_ id: NoteID) -> String {
        failedSave?.id == id ? failedSave?.content ?? currentContent : currentContent
    }

    /// Writes the notes taken when the missing folder came back (`resaves`) into it. A note whose file is there again (the
    /// restore brought it back, or a save wrote it) is left alone when it has the same text; at another version (an older
    /// backup, a sync client's copy) the file stays and our text is kept next to it as a conflict copy — never dropped
    /// unseen. The open note uses its latest text, and stays what's on screen: its text is written over the restored
    /// file, which is kept as the copy instead. Text that can't go into the folder stays held (and in its recovery
    /// file) — in `lostWithFolder` if the folder is gone again, else here; a switch or quit tries again. `leaving`
    /// (folder switch, quit): it must at least be in recovery. `skipping`: a note already kept elsewhere (carried into
    /// the new folder) — left for the caller. false = some text couldn't be kept anywhere.
    private func keepResaves(leaving: Bool, skipping: NoteID? = nil) -> Bool {
        var kept = true
        for id in resaves.keys.sorted() where id != skipping { kept = settleResave(id, leaving: leaving) && kept }
        return kept
    }

    /// One `resaves` entry (see `keepResaves`). false = its text is in neither the folder nor recovery.
    private func settleResave(_ id: NoteID, leaving: Bool) -> Bool {
        guard let taken = resaves[id] else { return true }
        // The open note's session started from this text (`editorText`): its latest text supersedes it.
        let content = id == currentID ? openText(id) : taken
        if content.isBlank {
            resaves[id] = nil
            return true
        }
        // The open note's edits that didn't save go through the save path (the store keeps a disk version it hasn't
        // seen as a copy) — also over a restored file.
        let unsaved = id == currentID && failedSave?.id == id
        // The editor's text (the open note, or what it showed when the folder came back): it stays the note.
        let ours = id == currentID || overRestored.contains(id)
        var write = !folderMissing
        if !folderMissing, store.exists(id), !unsaved {
            // Its file is there again. With this text (or, for the editor's, at a version already handled — saved
            // over): done. Otherwise a note left before the folder came back keeps the restored file and gets this text
            // next to it as a copy; the editor's is written (the store keeps the restored version as the copy).
            let disk = try? store.peek(id).get()
            if disk == content || (ours && store.unacknowledgedChange(id) == nil) || (!ours && keepTakenAsCopy(id, content)) {
                resaves[id] = nil
                if id == currentID { web.send(.unsavedText(id: id, unsaved: false)) }
                return true
            }
            write = ours
        }
        if write {
            switch store.write(id, content: content) {
            case .success(let result):
                if failedSave?.id == id, failedSave?.content == content { failedSave = nil }
                resaves[id] = nil
                if id == currentID { web.send(.unsavedText(id: id, unsaved: false)) }
                knownIDs.insert(id)
                Log.info("re-saved \(id == currentID ? "open " : "")note \(id) into the restored folder")
                if let copy = result.conflictCopy { keptConflictCopy(copy, of: id, restored: true) }
                let note = IndexedNote(id: id, content: content, modified: result.meta.modified)
                let search = search
                Task { await search.upsert(note) }
                return true
            case .failure(let error):
                Log.error("re-saving \(id) into the restored folder failed: \(error)")
            }
        }
        if folderMissing, !leaving {
            lostWithFolder[id] = content  // back with the folder's next return (held before it leaves `resaves`)
            resaves[id] = nil
            return true
        }
        resaves[id] = content
        if write, !leaving, id == currentID { resaveFailed(id) }
        return !leaving || writeRecovery(id: id, content: content)
    }

    /// The open note's editor text, taken to be re-saved into the folder (see `overRestored`).
    private func takeOpenText(_ id: NoteID) {
        resaves[id] = openText(id)
        overRestored.insert(id)
    }

    /// The open note's text couldn't go into the restored folder (read-only, say): the failed-save state ("Not saved", an
    /// error toast), and it's tried again (1s, 2s, 5s, then every 10s) while the note stays open — once it can be written
    /// it becomes the note, the restored file the copy. The text stays held (and in recovery) meanwhile.
    private func resaveFailed(_ id: NoteID) {
        web.send(.unsavedText(id: id, unsaved: true))
        guard resaveRetryID != id else { return }  // already said, and being retried
        toast(saveErrorMessage(), .error)
        resaveRetryID = id
        resaveRetry?.cancel()
        resaveRetry = Task { [weak self] in
            for attempt in 0... {
                try? await Task.sleep(for: .seconds([1, 2, 5, 10][min(attempt, 3)]))
                guard let self, !Task.isCancelled else { return }
                let pending = await enqueueAndWait { [self] in
                    guard currentID == id, resaves[id] != nil else { return false }
                    if !folderMissing { _ = settleResave(id, leaving: false) }
                    return currentID == id && resaves[id] != nil
                }
                if !pending { break }
            }
            guard let self, resaveRetryID == id else { return }
            resaveRetryID = nil
            resaveRetry = nil
        }
    }

    /// Reads `id` for the editor. Text still held for it from the folder's return (`resaves`, `lostWithFolder`) is
    /// written into the folder first if it can be now; if not, the editor gets that text — never the folder's version
    /// over it. The restored file stays unacknowledged, so a later save or re-save keeps both versions.
    private func editorText(_ id: NoteID) -> Result<String, StoreError> {
        if !folderMissing, resaves[id] == nil, let lost = lostWithFolder[id] {
            resaves[id] = lost
            lostWithFolder[id] = nil
        }
        if !folderMissing, resaves[id] != nil { _ = settleResave(id, leaving: false) }
        if let pending = resaves[id] ?? lostWithFolder[id], !pending.isBlank {
            Log.warn("open \(id): its text isn't in the notes folder yet — showing it (the folder's version stays)")
            return .success(pending)
        }
        return store.read(id)
    }

    /// The open note's editor text is in the folder (saved, carried, trashed): what was held for it is superseded.
    private func dropHeld(_ id: NoteID) {
        if resaves[id] != nil { resaves[id] = nil }
        if lostWithFolder[id] != nil { lostWithFolder[id] = nil }
        if handedToRecovery[id] != nil { handedToRecovery[id] = nil }
    }

    /// The folder came back with `id` at a version other than `content` (the text we had for it): the file stays as
    /// restored, `content` becomes its own note next to it. false = that copy couldn't be written.
    private func keepTakenAsCopy(_ id: NoteID, _ content: String) -> Bool {
        switch store.saveConflictCopy(of: id, content: content) {
        case .success(let copy):
            knownIDs.insert(copy.id)
            let search = search
            Task { await search.upsert(IndexedNote(id: copy.id, content: content, modified: copy.modified)) }
            Log.warn("\(id) came back with the folder at another version — kept ours as \(copy.id)")
            toast("Restored note differs — kept both versions", .info)
            return true
        case .failure(let error):
            Log.error("copy of \(id) next to its restored file failed: \(error)")
            return false
        }
    }

    /// Every held text is in a recovery file, except possibly `except`'s (the caller keeps that one).
    private func allHeld(except: NoteID? = nil) -> Bool {
        syncHeld()
        let want = heldTexts
        return unheld.allSatisfy { want[$0]?.id == except }
    }

    private func switchFolder(to url: URL) {
        enqueue { [self] in
            let from = store.folder
            guard url.standardizedFileURL != from.standardizedFileURL else { return }  // e.g. the revert below
            // An open note that can't be saved (old folder gone/unwritable) moves into the new folder — written there
            // durably before anything is swapped. If that fails too, the switch is cancelled: same folder, same buffer.
            var carry: String?
            if case .failed = await web.flush() {
                carry = await web.editorContent() ?? (failedSave?.id == currentID ? failedSave?.content : nil)
                if carry == nil { return cancelSwitch(back: from, "Couldn’t read unsaved text — switch cancelled") }
            }
            // A failed save for a note no longer on screen: keep it in recovery (imported on next launch).
            if let failedSave, failedSave.id != currentID, !failedSave.content.isBlank,
               !writeRecovery(id: failedSave.id, content: failedSave.content) {
                return cancelSwitch(back: from, "Couldn’t back up unsaved text — switch cancelled")
            }
            // Notes taken when the old folder came back go into it now (or recovery). The open note too, if its file
            // went with a still-missing folder: the editor's (clean) text is all there is. Notes that went with the old
            // folder while it was missing: recovery has them (imported on next launch). Any that can't be kept anywhere
            // cancel the switch — they stay pending, tried again by the next switch or quit.
            if carry == nil, folderMissing, let id = currentID, !currentIsNew, !store.exists(id) { takeOpenText(id) }
            let resaved = keepResaves(leaving: true, skipping: carry == nil ? nil : currentID)
            guard resaved, allHeld(except: carry == nil ? nil : currentID) else {
                return cancelSwitch(back: from, "Couldn’t save or back up a note — switch cancelled")
            }
            var carriedID: NoteID?
            if let carry, !carry.isBlank {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                switch NoteStore.createNote(in: url, content: carry) {
                case .success(let id): carriedID = id
                case .failure(let error):
                    Log.error("carry unsaved note into \(url.path): \(error)")
                    return cancelSwitch(back: from, "Couldn’t move unsaved text to the new folder — switch cancelled")
                }
            }
            if carry != nil {
                // The buffer now lives in the new folder: the outgoing session must not resave its id — there that
                // id could be a different note. What was held for it is superseded.
                if let id = currentID {
                    if failedSave?.id == id { failedSave = nil }
                    dropHeld(id)
                }
                await web.discardPendingSaves()
            } else {
                cleanupIfEmpty(currentID)
            }
            // Everything pending is kept now (written, in recovery for the next launch, or the open note's text carried /
            // still in the editor).
            handOffHeld()
            folderMissing = false
            state.flush()
            store.setFolder(url)
            presentedIDs = []
            let dir = env.stateDirectory(for: url)
            state = AppState(directory: dir)
            search = SearchService(indexDirectory: dir.appendingPathComponent("index", isDirectory: true))
            currentID = nil
            currentIsNew = false
            currentContent = ""
            renamed = [:]
            knownIDs = []
            Log.info("notes folder → \(url.path)")
            if let id = carriedID, case .success(let content) = store.read(id) {
                knownIDs.insert(id)
                present(id, isNew: false, content: content)
                toast("Unsaved note moved to this folder", .info)
                Log.info("carried unsaved note into the new folder as \(id)")
            } else if web.isReady {
                presentInitial()
            }
            reindexAll()
            reportUnreadable(store.skipped)
        }
    }

    /// Folder switch aborted before anything changed: the open note (and its "Not saved" state) stays; the folder
    /// preference goes back (its change handler lands in `switchFolder`, which ignores the folder we're already in).
    private func cancelSwitch(back from: URL, _ message: String) {
        Log.error("folder switch cancelled: \(message)")
        toast(message, .error)
        if prefs.notesFolder.standardizedFileURL != from.standardizedFileURL { prefs.notesFolder = from }
    }

    private func reindexAll() {
        let folder = store.folder
        let search = search
        Task {
            let notes = await Task.detached(priority: .utility) {
                NoteStore.loadAll(folder).map { IndexedNote(id: $0.id, content: $0.content, modified: $0.modified) }
            }.value
            guard folder == store.folder else { return }
            knownIDs.formUnion(notes.map(\.id))
            let started = Date()
            await search.reindexAll(notes)
            Log.info("indexed \(notes.count) notes in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
    }

    // MARK: Misc

    /// A note file that can't be read (not UTF-8, too big, permissions) is left alone and kept out of the list —
    /// say so once per file per launch. `reasons` are "<file name>: <why>".
    private func reportUnreadable(_ reasons: [String]) {
        let fresh = reasons.filter { reportedUnreadable.insert($0.components(separatedBy: ": ").first ?? $0).inserted }
        guard !fresh.isEmpty else { return }
        if fresh.count == 1, let only = fresh.first {
            let parts = only.components(separatedBy: ": ")
            toast("Can’t read \(parts[0])\(parts.count > 1 ? " — \(parts.dropFirst().joined(separator: ": "))" : "")", .info)
        } else {
            let utf8 = fresh.allSatisfy { $0.hasSuffix("not UTF-8 text") }
            toast("Skipped \(fresh.count) files that \(utf8 ? "aren’t UTF-8 text" : "can’t be read")", .info)
        }
    }

    private func rankingContext() -> RankingContext {
        RankingContext(
            pins: state.pins,
            frecency: Dictionary(uniqueKeysWithValues: knownIDs.map { ($0, state.frecency($0)) }),
            lastOpened: state.lastTouched)
    }

    private func pasteImages(_ images: [PastedImage]) {
        var links: [String] = []
        for image in images {
            switch store.saveAsset(image.data, ext: image.ext) {
            case .success(let path): links.append("![](\(path))")
            case .failure(let error): Log.error("paste image: \(error)")
            }
        }
        guard !links.isEmpty else { return NSSound.beep() }
        Log.info("pasted \(links.count) image(s)")
        web.send(.insertText(links.joined(separator: "\n"), block: true))
    }

    /// Our own copy pasted back (any folder, including its own): its images come from the copy's snapshot, written into
    /// this folder's assets/ where the files here don't already hold those bytes. If they can't be written, nothing is
    /// inserted (no references that don't resolve).
    /// The image work (megabytes of base64, file reads/writes) runs off the main thread; the text goes in when it's done,
    /// unless the folder or note changed meanwhile — where the paste was invoked: the editor reserves the selection now
    /// (`beginPaste`, ordered before any later keystroke) and maps it through whatever is typed meanwhile.
    /// `reservation`: the editor already reserved the paste under this token (vim `p`); else it's reserved here.
    private func pasteOwnCopy(_ copy: ClipboardExport.OwnCopy, reservation reserved: String? = nil) {
        guard !copy.images.isEmpty else { return web.send(.insertText(copy.markdown, block: false, token: reserved)) }
        let folder = store.folder, note = currentID, started = Date()
        let token = UUID()
        let reservation = reserved ?? token.uuidString
        if reserved == nil { web.send(.beginPaste(token: reservation)) }
        // Pastes running at the same time may reuse each other's new files: then none of them removes any on cancel.
        if !ownPastes.isEmpty { ownPastes.keys.forEach { ownPastes[$0] = true } }
        awaitingInsert.keys.forEach { awaitingInsert[$0]?.shared = true }
        ownPastes[token] = !ownPastes.isEmpty
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ClipboardExport.transferAssets(copy, to: folder) { message in Task { @MainActor in Log.warn(message) } }
            }.value
            let overlapped = ownPastes.removeValue(forKey: token) ?? true
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch result {
            case .success(let result):
                store.acknowledgeAssetWrites(result.written)
                guard store.folder == folder, currentID == note else {
                    // Nothing references the files this paste just created: take them back out.
                    if !overlapped { result.written.forEach { try? FileManager.default.removeItem(at: $0) } }
                    web.send(.cancelPaste(token: reservation))
                    Log.warn("paste note copy: note changed while its images were copied — not inserted\(overlapped ? "" : ", \(result.written.count) new file(s) removed")")
                    return toast("Paste cancelled — the note changed", .info)
                }
                Log.info("pasted note copy from \(copy.folder?.path ?? "?"): \(result.written.count) image file(s) written into assets/ (\(ms)ms)")
                // The editor may still drop it (another note was loaded and this one reopened meanwhile): see `pasteResult`.
                awaitingInsert[reservation] = (result.written, overlapped)
                web.send(.insertText(result.markdown, block: false, token: reservation))
            case .failure(let error):
                web.send(.cancelPaste(token: reservation))
                Log.error("paste note copy: \(error.message)")
                toast(error.user, .error)
            }
        }
    }

    /// The editor's answer to a reserved paste: if it didn't go in, nothing references the files written for it.
    private func pasteResult(token: String, inserted: Bool) {
        guard let pending = awaitingInsert.removeValue(forKey: token), !inserted else { return }
        if !pending.shared { pending.files.forEach { try? FileManager.default.removeItem(at: $0) } }
        Log.warn("paste note copy: not inserted by the editor\(pending.shared ? "" : ", \(pending.files.count) new file(s) removed")")
    }

    private func openURL(_ raw: String) {
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            if ["http", "https", "mailto"].contains(scheme) { NSWorkspace.shared.open(url); return }
            if scheme == "nbm", url.host == "notes", let file = store.resolve(relativePath: String(url.path.drop { $0 == "/" })) {
                NSWorkspace.shared.open(file)
                return
            }
            return Log.warn("openURL: blocked \(raw)")
        }
        // Relative link (e.g. assets/x.png) → open the file from the notes folder.
        if let file = store.resolve(relativePath: raw), FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.open(file)
        } else {
            Log.warn("openURL: can't open \(raw)")
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await operation()
        }
    }

    /// Runs `operation` in queue order and waits for its result.
    private func enqueueAndWait<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            enqueue { continuation.resume(returning: await operation()) }
        }
    }

    /// Vim's unnamed register mirrors the system clipboard: when the panel becomes key and something else was copied
    /// since we last looked, hand the text to the editor.
    private func syncSystemClipboard() {
        guard prefs.vimEnabled, web.isReady else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != seenPasteboardChange else { return }
        seenPasteboardChange = pb.changeCount
        // Our own ⌘⇧C copy: the note's Markdown (relative image paths), like ⌘V — not the base64 export.
        let own = ClipboardExport.ownCopy(pb)
        // No text at all (an image-only clipboard) empties the register, like an emptied clipboard.
        let text = own?.markdown ?? pb.string(forType: .string) ?? ""
        guard text.utf8.count <= 1_000_000 else { return }
        web.send(.systemClipboard(text: text, ownCopy: own?.images.isEmpty == false))
    }

    /// While the panel stays key, the pasteboard can change without it becoming key again (a clipboard manager, Universal
    /// Clipboard, `pbcopy`): checked once a second — one changeCount read — until the panel isn't key. Nothing when hidden.
    private func watchClipboard() {
        guard clipboardWatch == nil, prefs.vimEnabled else { return }
        clipboardWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, panel.isVisible, panel.isKey, prefs.vimEnabled else { break }
                syncSystemClipboard()
            }
            self?.clipboardWatch = nil
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: Introspection (automation)

    var debugState: [String: Any] {
        [
            "currentNoteID": currentID.map { $0 as Any } ?? NSNull(),
            "currentIsNew": currentIsNew,
            "currentTitle": panel.strip.title,
            "folderMissing": folderMissing,
            "failedSaveID": failedSave.map { $0.id as Any } ?? NSNull(),
            "pinned": panel.strip.isPinned,
            "pins": state.pins,
            "canGoBack": state.canGoBack,
            "canGoForward": state.canGoForward,
            "knownNotes": knownIDs.count,
            "webReady": web.isReady,
            "recoveryDirs": env.recoveryDirectories.map(\.path),
            "pendingIDs": Array(Set(resaves.keys).union(lostWithFolder.keys)).sorted(),
            "heldRecoveryFiles": heldFiles.values.map(\.url.path).sorted(),
            "unheldCount": unheld.count,
        ]
    }
}

extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}
