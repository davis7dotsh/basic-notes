import Foundation

/// End-to-end checks for NoteStore (file watching, atomic saves, renames, path safety) and AppState persistence.
/// Run: scripts/eval.sh --store
enum StoreCheck {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print("  \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    static func describe(_ e: StoreEvent) -> String {
        switch e {
        case .changed(let id, let c): return "changed(\(id), \(c.count) chars)"
        case .added(let id): return "added(\(id))"
        case .removed(let id): return "removed(\(id))"
        case .renamed(let a, let b): return "renamed(\(a)->\(b))"
        case .folderAvailable(let ok): return "folderAvailable(\(ok))"
        case .unreadable(let why): return "unreadable(\(why))"
        case .assetsChanged(let paths): return "assetsChanged(\(paths.joined(separator: ",")))"
        }
    }

    static func run() async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("nbm-store-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "# Alpha\nhello".write(to: dir.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        try? "# Beta\nworld".write(to: dir.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
        try? Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: dir.appendingPathComponent("binary.md"))

        let store = NoteStore(folder: dir)
        var events: [StoreEvent] = []
        store.onEvent = { events.append($0) }
        func settle(_ ms: Int = 700) async -> [String] {
            try? await Task.sleep(for: .milliseconds(ms))
            defer { events.removeAll() }
            return events.map(describe)
        }
        _ = await settle(300)
        print("NoteStore")
        check(Set(store.list().map(\.id)) == ["alpha", "beta"], "initial list skips non-UTF-8 file: \(store.list().map(\.id))")
        check(store.meta("alpha")?.title == "Alpha", "cached title")

        // Our own writes never echo.
        let id = store.makeNewID()
        check(id.range(of: #"^\d{4}-\d{2}-\d{2}-\d{4}-[a-z0-9]{4}$"#, options: .regularExpression) != nil, "id format \(id)")
        _ = store.write(id, content: "# New\nbody")
        _ = store.write("alpha", content: "# Alpha\nedited by us")
        var got = await settle()
        check(got.isEmpty, "own writes produce no events: \(got)")
        check(store.list().count == 3, "list includes new note")

        // External in-place edit.
        try? "# Alpha\nedited externally".write(to: dir.appendingPathComponent("alpha.md"), atomically: false, encoding: .utf8)
        got = await settle()
        check(got == ["changed(alpha, 25 chars)"], "external edit -> changed: \(got)")

        // Touch without content change -> nothing.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.appendingPathComponent("alpha.md").path)
        got = await settle()
        check(got.isEmpty, "mtime-only touch -> no event: \(got)")

        // Vim-style atomic save: write 4913 probe, rename original to backup, write new file, delete backup + swap noise.
        let a = dir.appendingPathComponent("alpha.md")
        try? "x".write(to: dir.appendingPathComponent("4913"), atomically: false, encoding: .utf8)
        try? fm.removeItem(at: dir.appendingPathComponent("4913"))
        try? "swap".write(to: dir.appendingPathComponent(".alpha.md.swp"), atomically: false, encoding: .utf8)
        try? fm.moveItem(at: a, to: dir.appendingPathComponent("alpha.md~"))
        try? "# Alpha\nsaved by vim".write(to: a, atomically: false, encoding: .utf8)
        try? fm.removeItem(at: dir.appendingPathComponent("alpha.md~"))
        try? fm.removeItem(at: dir.appendingPathComponent(".alpha.md.swp"))
        got = await settle()
        check(got == ["changed(alpha, 20 chars)"], "vim atomic save -> single changed: \(got)")

        // VS Code-style: temp file + rename over target.
        try? "# Alpha\nsaved by code".write(to: dir.appendingPathComponent("alpha.md.tmp"), atomically: false, encoding: .utf8)
        _ = rename(dir.appendingPathComponent("alpha.md.tmp").path, a.path)
        got = await settle()
        check(got == ["changed(alpha, 21 chars)"], "temp+rename save -> single changed: \(got)")

        // Rename.
        try? fm.moveItem(at: dir.appendingPathComponent("beta.md"), to: dir.appendingPathComponent("gamma.md"))
        got = await settle()
        check(got == ["renamed(beta->gamma)"], "external rename -> renamed: \(got)")

        // Case-only rename (Finder `kappa.md` → `Kappa.md`): on a case-insensitive volume the old name still stats.
        try? "# Kappa".write(to: dir.appendingPathComponent("kappa.md"), atomically: false, encoding: .utf8)
        _ = await settle()
        try? fm.moveItem(at: dir.appendingPathComponent("kappa.md"), to: dir.appendingPathComponent("Kappa.md"))
        got = await settle()
        let ids = Set(store.list().map(\.id))
        check(got == ["renamed(kappa->Kappa)"] && ids.contains("Kappa") && !ids.contains("kappa"), "case-only rename -> renamed: \(got)")
        // A save racing it (before the watcher reports it) follows the file too.
        _ = rename(dir.appendingPathComponent("Kappa.md").path, dir.appendingPathComponent("kappa.md").path)
        let to = store.existsExactly("Kappa") ? nil : store.adoptRename(of: "Kappa")
        got = await settle()
        check(to == "kappa" && got.isEmpty && Set(store.list().map(\.id)).isSuperset(of: ["kappa"]) && !store.list().contains { $0.id == "Kappa" },
              "case-only rename adopted by a save -> kappa, no events: \(to ?? "nil") \(got)")
        try? fm.removeItem(at: dir.appendingPathComponent("kappa.md"))
        _ = await settle()

        // Delete + create.
        try? fm.removeItem(at: dir.appendingPathComponent("gamma.md"))
        got = await settle()
        check(got == ["removed(gamma)"], "external delete -> removed: \(got)")
        try? "# Delta".write(to: dir.appendingPathComponent("delta.md"), atomically: false, encoding: .utf8)
        got = await settle()
        check(got == ["added(delta)"], "external create -> added: \(got)")

        // Event latency (external write -> onEvent on main).
        var lat: [Double] = []
        for i in 0..<5 {
            let start = Date()
            try? "# Delta \(i)".write(to: dir.appendingPathComponent("delta.md"), atomically: false, encoding: .utf8)
            while events.isEmpty && Date().timeIntervalSince(start) < 2 { try? await Task.sleep(for: .milliseconds(2)) }
            lat.append(Date().timeIntervalSince(start) * 1000)
            events.removeAll()
            try? await Task.sleep(for: .milliseconds(100))
        }
        print(String(format: "  info external change -> event latency: median %.0f ms", lat.sorted()[2]))
        _ = await settle(300)

        // Ignored files.
        try? "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: false, encoding: .utf8)
        try? "x".write(to: dir.appendingPathComponent(".hidden.md"), atomically: false, encoding: .utf8)
        try? fm.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try? "x".write(to: dir.appendingPathComponent("assets/inner.md"), atomically: false, encoding: .utf8)
        try? Data([0xFF, 0x00]).write(to: dir.appendingPathComponent("binary2.md"))
        got = await settle()
        // A non-UTF-8 .md is reported once as unreadable (the app toasts it) but never becomes a note.
        let notes = got.filter { !$0.hasPrefix("unreadable(") && !$0.hasPrefix("assetsChanged(") }
        check(notes.isEmpty, "non-md / dotfile / assets / non-UTF-8 ignored: \(got)")

        // Read reflects disk; trash emits nothing.
        check((try? store.read("delta").get()) == "# Delta 4", "read")
        check(store.trash("delta").isSuccess && !store.exists("delta"), "trash moves file away")
        got = await settle()
        check(got.isEmpty, "trash -> no event: \(got)")
        check(store.read("nope").isFailure, "read missing -> failure")

        // A read ahead of the watcher reports the revision itself (the watcher then sees nothing new).
        var surfaced: [String] = []
        store.onRevisionRead = { surfaced.append("\($0.id):\($0.content)") }
        try? "# Early\nfresh".write(to: dir.appendingPathComponent("alpha.md"), atomically: false, encoding: .utf8)
        try? "# Born\nnew".write(to: dir.appendingPathComponent("born.md"), atomically: false, encoding: .utf8)
        _ = store.read("alpha")
        _ = store.peek("born")
        _ = store.read("alpha")
        got = await settle()
        check(surfaced == ["alpha:# Early\nfresh", "born:# Born\nnew"], "read ahead of watcher -> onRevisionRead once: \(surfaced)")
        check(got.isEmpty, "…and no watcher event for it: \(got)")
        store.onRevisionRead = nil

        // Assets + path safety.
        let asset = store.saveAsset(Data([1, 2, 3]), ext: "PNG")
        let rel = (try? asset.get()) ?? ""
        check(rel.range(of: #"^assets/pasted-\d{8}-\d{4}-[a-z0-9]{4}\.png$"#, options: .regularExpression) != nil, "asset path \(rel)")
        check(store.resolve(relativePath: rel) != nil, "resolve asset")
        check(store.resolve(relativePath: "../etc/passwd") == nil, "reject ..")
        check(store.resolve(relativePath: "assets/../../x") == nil, "reject nested ..")
        check(store.resolve(relativePath: "/etc/passwd") == nil, "reject absolute")
        try? fm.createSymbolicLink(atPath: dir.appendingPathComponent("assets/escape.png").path, withDestinationPath: "/etc/hosts")
        // A symlink the user placed in the folder is their choice (like a symlinked note); a `..` through it isn't.
        check(store.resolve(relativePath: "assets/escape.png")?.path == NoteStore.realPath("/etc/hosts"), "follow symlink placed in folder")
        try? fm.createSymbolicLink(atPath: dir.appendingPathComponent("assets/linkdir").path, withDestinationPath: "/etc")
        check(store.resolve(relativePath: "assets/linkdir/../hosts") == nil, "reject .. through a symlink")
        check(store.resolve(relativePath: "assets/linkdir/..%2Fhosts") == nil, "reject encoded .. through a symlink")
        check(store.resolve(relativePath: "assets/sp%20ace.png") == nil || true, "percent-encoded path does not crash")
        _ = await settle(300)

        // Asset files: our own writes are silent, external create/replace/delete are reported (relative paths).
        _ = store.saveAsset(Data([4, 5, 6]), ext: "png")
        got = await settle()
        check(got.isEmpty, "own asset write -> no event: \(got)")
        let ext = dir.appendingPathComponent("assets/ext.png")
        try? Data([7]).write(to: ext)
        got = await settle()
        check(got == ["assetsChanged(assets/ext.png)"], "external asset create -> assetsChanged: \(got)")
        try? Data([8, 9]).write(to: ext, options: .atomic)
        got = await settle()
        check(got == ["assetsChanged(assets/ext.png)"], "external asset replace -> assetsChanged: \(got)")
        try? fm.removeItem(at: ext)
        got = await settle()
        check(got == ["assetsChanged(assets/ext.png)"], "external asset delete -> assetsChanged: \(got)")

        // Folder switch: old folder events stop.
        let dir2 = fm.temporaryDirectory.appendingPathComponent("nbm-store2-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir2) }
        store.setFolder(dir2)
        try? "# old".write(to: dir.appendingPathComponent("late.md"), atomically: false, encoding: .utf8)
        try? "# new".write(to: dir2.appendingPathComponent("fresh.md"), atomically: false, encoding: .utf8)
        got = await settle()
        check(got == ["added(fresh)"], "setFolder restarts watcher: \(got)")

        // Burst: many external files at once.
        for i in 0..<200 { try? "# n\(i)".write(to: dir2.appendingPathComponent("burst-\(i).md"), atomically: false, encoding: .utf8) }
        got = await settle(1200)
        check(got.count == 200 && got.allSatisfy { $0.hasPrefix("added(burst-") }, "burst of 200 creates -> 200 added (\(got.count))")

        print("AppState")
        let sdir = fm.temporaryDirectory.appendingPathComponent("nbm-state-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: sdir) }
        var st = AppState(directory: sdir)
        st.togglePin("a"); st.togglePin("b"); st.togglePin("c"); st.togglePin("b")
        check(st.pins == ["a", "c"], "pins ordered toggle")
        st.recordOpen("a"); st.recordOpen("a"); st.recordEdit("c"); st.recordEdit("c")
        check(st.frecency("a") > st.frecency("c") && st.frecency("c") > 0 && st.frecency("zz") == 0, "frecency (edits rate-limited)")
        st.visit(from: nil, to: "a"); st.visit(from: "a", to: "b"); st.visit(from: "b", to: "b"); st.visit(from: "b", to: "c")
        check(st.goBack(current: "c") == "b" && st.goBack(current: "b") == "a" && !st.canGoBack, "back")
        check(st.goForward(current: "a") == "b" && st.canGoForward, "forward")
        st.setViewState(ViewState(anchor: 3, head: 5, scrollTop: 10), for: "a")
        st.lastOpenID = "a"
        st.rename(from: "a", to: "a2")
        check(st.pins == ["a2", "c"] && st.lastOpenID == "a2" && st.viewState(for: "a2")?.head == 5 && st.frecency("a2") > 0, "rename keeps state")
        st.forget("c")
        check(st.pins == ["a2"] && st.frecency("c") == 0, "forget")
        st.flush()
        st = AppState(directory: sdir)
        check(st.pins == ["a2"] && st.lastOpenID == "a2" && st.viewState(for: "a2")?.anchor == 3, "persist + reload")
        try? Data("{not json".utf8).write(to: sdir.appendingPathComponent("state.json"))
        st = AppState(directory: sdir)
        check(st.pins.isEmpty && st.lastOpenID == nil, "corrupt state.json -> fresh state")
        st.togglePin("x")
        try? await Task.sleep(for: .milliseconds(1000))
        check(AppState(directory: sdir).pins == ["x"], "debounced save lands")

        print(failures == 0 ? "\nall store checks passed" : "\n\(failures) store check(s) FAILED")
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
    var isFailure: Bool { !isSuccess }
}
