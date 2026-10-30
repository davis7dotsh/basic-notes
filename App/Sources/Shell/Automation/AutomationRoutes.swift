import AppKit
import UniformTypeIdentifiers

/// Routes for the automation server (see docs/automation.md). Everything runs on the main actor.
final class AutomationRoutes {
    private let coordinator: Coordinator
    private let prefs: Preferences
    private let settings: SettingsWindowController
    private var panel: PanelController { coordinator.panel }
    private var web: WebHost { coordinator.web }

    init(coordinator: Coordinator, prefs: Preferences, settings: SettingsWindowController) {
        self.coordinator = coordinator
        self.prefs = prefs
        self.settings = settings
    }

    typealias Response = HTTPServer.Response

    func handle(_ req: HTTPServer.Request) async -> Response {
        Log.debug("automation \(req.method) \(req.path)")
        switch (req.method, req.path) {
        case ("GET", "/state"): return await state()
        case ("GET", "/snapshot"): return await snapshot(scale: Double(req.query["scale"] ?? "") ?? 1, window: req.query["window"])
        case ("POST", "/js"): return await js(req.json()["code"] as? String ?? "")
        case ("POST", "/key"): return await keys([req.json()["combo"] as? String ?? ""], delayMs: req.json()["delayMs"] as? Int)
        case ("POST", "/keys"): return await keys(req.json()["sequence"] as? [String] ?? [], delayMs: req.json()["delayMs"] as? Int)
        case ("POST", "/type"): return await type(req.json()["text"] as? String ?? "", delayMs: req.json()["delayMs"] as? Int)
        case ("POST", "/click"): return await click(req.json())
        case ("POST", "/action"): return await action(req.json())
        case ("POST", "/pasteboard"): return setPasteboard(req.json())
        case ("GET", "/pasteboard"): return getPasteboard(full: req.query["full"] == "1")
        case ("POST", "/resize"): return await resize(req.json())
        case ("GET", "/logs"): return .json(["lines": Log.recent(Int(req.query["n"] ?? "") ?? 200)])
        case ("GET", "/"), ("GET", "/help"):
            return .json(["endpoints": [
                "GET /state", "GET /snapshot?scale=1[&window=settings]", "POST /js {code}", "POST /key {combo}", "POST /keys {sequence:[...]}",
                "POST /type {text}", "POST /click {x,y,button,clickCount}", "POST /action {name,value}",
                "POST /pasteboard {text?,html?,imagePath?,filePath?}", "GET /pasteboard?full=1", "POST /resize {width,height}", "GET /logs?n=200",
            ]])
        default: return .error("no route \(req.method) \(req.path)", status: 404)
        }
    }

    // MARK: State

    private func state() async -> Response {
        let f = panel.panel.frame
        let probe = """
        const ed = document.querySelector('.cm-editor');
        const custom = window.__nbm && typeof window.__nbm.debugState === 'function' ? window.__nbm.debugState() : null;
        return {
          hasFocus: document.hasFocus(),
          editorFocused: !!(ed && ed.classList.contains('cm-focused')),
          activeElement: document.activeElement ? (document.activeElement.className || document.activeElement.tagName) : null,
          vimFatCursor: !!document.querySelector('.cm-fat-cursor'),
          vimPanel: document.querySelector('.cm-vim-panel') ? document.querySelector('.cm-vim-panel').textContent : null,
          debug: custom,
        };
        """
        var webState: Any = NSNull()
        if web.isReady, case .success(let data) = await web.evaluate(body: probe, timeout: 1.5) {
            webState = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? NSNull()
        }
        let frame: [String: Any] = ["x": f.minX, "y": f.minY, "width": f.width, "height": f.height, "top": f.maxY]
        var screenFrame: Any = NSNull()
        if let v = (panel.panel.screen ?? NSScreen.main)?.visibleFrame {
            screenFrame = ["x": v.minX, "y": v.minY, "width": v.width, "height": v.height] as [String: Any]
        }
        let panelInfo: [String: Any] = [
            "visible": panel.isVisible,
            "key": panel.isKey,
            "keyForced": panel.panel.isKeyWindow && !panel.panel.isReallyKey,
            "frame": frame,
            "pageZoom": web.webView.pageZoom,
            "sharingType": panel.panel.sharingType == .none ? "none" : "readOnly",
            "screenVisibleFrame": screenFrame,
        ]
        let appInfo: [String: Any] = [
            "active": NSApp.isActive,
            "activationPolicy": NSApp.activationPolicy() == .regular ? "regular" : "accessory",
            "keyWindow": NSApp.keyWindow?.title ?? NSNull(),
            "settingsVisible": settings.isVisible,
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull(),
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        let settingsInfo: [String: Any] = [
            "notesFolder": prefs.notesFolder.path,
            "vimEnabled": prefs.vimEnabled,
            "hideFromCapture": prefs.hideFromCapture,
            "toggleHotkey": prefs.toggleHotkey?.display ?? NSNull(),
            "newNoteHotkey": prefs.newNoteHotkey?.display ?? NSNull(),
            "unavailableHotkeys": prefs.unavailableHotkeys.map(\.display).sorted(),
            "openAtLogin": LoginItem.statusDescription,
        ]
        return .json([
            "panel": panelInfo,
            "app": appInfo,
            "note": coordinator.debugState,
            "settings": settingsInfo,
            "stateDir": coordinator.env.stateDirectory(for: prefs.notesFolder).path,
            "web": webState,
        ])
    }

    private func snapshot(scale: Double, window: String?) async -> Response {
        let scale = CGFloat(min(max(scale, 0.25), 4))
        if window == "settings" {
            guard settings.isVisible else { return .error("settings window is not open") }
            settings.rebuildContent()
            try? await Task.sleep(for: .milliseconds(50))
            guard let view = settings.contentView else { return .error("settings window has no content") }
            switch Snapshot.png(view: view, scale: scale) {
            case .success(let png): return Response(contentType: "image/png", body: png)
            case .failure(let error): return .error(error.message, status: 500)
            }
        }
        switch await Snapshot.png(panel: panel, webView: web.webView, scale: scale) {
        case .success(let png): return Response(contentType: "image/png", body: png)
        case .failure(let error): return .error(error.message, status: 500)
        }
    }

    private func js(_ code: String) async -> Response {
        guard !code.isEmpty else { return .error("missing code") }
        guard web.isReady else { return .error("page not ready", status: 500) }
        // Expressions get an implicit `return`; anything using return/await runs as an async function body.
        let usesBody = code.range(of: #"\b(return|await)\b"#, options: .regularExpression) != nil
        var result = await web.evaluate(body: usesBody ? code : "return (\(code)\n)")
        if !usesBody, case .failure(let error) = result, error.message.contains("SyntaxError") {
            result = await web.evaluate(body: code)
        }
        switch result {
        case .success(let data):
            return .json(["result": (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? NSNull()])
        case .failure(let error): return .error(error.message, status: 500)
        }
    }

    // MARK: Input

    /// Panel must be visible; make it key so events route like real typing.
    private func ensureKey() -> Response? {
        guard panel.isVisible else { return .error("panel is hidden (POST /action {\"name\":\"show\"} first)") }
        if !panel.isKey { panel.show() }
        return nil
    }

    private func keys(_ combos: [String], delayMs: Int?) async -> Response {
        guard !combos.isEmpty else { return .error("no keys") }
        var strokes: [EventSynth.Stroke] = []
        for combo in combos {
            switch EventSynth.parse(combo) {
            case .success(let s): strokes.append(s)
            case .failure(let e): return .error(e.message)
            }
        }
        if let error = ensureKey() { return error }
        for stroke in strokes {
            EventSynth.send(stroke, to: panel.panel)
            await settle(delayMs)
        }
        await settle(60)
        return .json(["ok": true, "count": strokes.count, "key": panel.isKey])
    }

    private func type(_ text: String, delayMs: Int?) async -> Response {
        guard !text.isEmpty else { return .error("missing text") }
        if let error = ensureKey() { return error }
        var pending = ""  // non-ASCII run → insertText fallback
        func flushPending() async {
            guard !pending.isEmpty else { return }
            _ = await web.evaluate(body: "document.execCommand('insertText', false, t); return true", arguments: ["t": pending])
            pending = ""
        }
        for ch in text {
            if let stroke = EventSynth.stroke(for: ch) {
                await flushPending()
                EventSynth.send(stroke, to: panel.panel)
                await settle(delayMs)
            } else {
                pending.append(ch)
            }
        }
        await flushPending()
        await settle(60)
        return .json(["ok": true, "chars": text.count])
    }

    private func click(_ body: [String: Any]) async -> Response {
        guard let x = (body["x"] as? NSNumber)?.doubleValue, let y = (body["y"] as? NSNumber)?.doubleValue else { return .error("need x, y") }
        guard panel.isVisible else { return .error("panel is hidden") }
        let result = EventSynth.click(
            x: x, y: y, right: (body["button"] as? String) == "right", clickCount: body["clickCount"] as? Int ?? 1, in: panel.panel)
        if case .failure(let e) = result { return .error(e.message) }
        await settle(60)
        return .json(["ok": true])
    }

    /// Lets queued WebKit work drain: a JS round trip after an optional delay.
    private func settle(_ ms: Int?) async {
        if let ms, ms > 0 { try? await Task.sleep(for: .milliseconds(ms)) }
        if web.isReady { _ = await web.evaluate(body: "return 1", timeout: 1) }
    }

    // MARK: Actions

    private func action(_ body: [String: Any]) async -> Response {
        let name = body["name"] as? String ?? ""
        let value = body["value"]
        switch name {
        case "toggle": coordinator.toggle()
        case "show": coordinator.show()
        case "hide": coordinator.hide()
        case "new": coordinator.newNote()
        case "search": coordinator.openSearch()
        case "open":
            guard let id = value as? String else { return .error("open needs value: <note id>") }
            coordinator.open(id)
        case "settings": settings.show()
        case "closeSettings": settings.close()
        case "setVim": prefs.vimEnabled = Self.bool(value) ?? !prefs.vimEnabled
        case "setHideFromCapture": prefs.hideFromCapture = Self.bool(value) ?? !prefs.hideFromCapture
        case "setNotesDir":
            guard let path = value as? String, !path.isEmpty else { return .error("setNotesDir needs value: <path>") }
            prefs.notesFolder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        case "setToggleHotkey", "setNewNoteHotkey":
            // value: "ctrl+alt+n" or "" to clear
            let raw = value as? String ?? ""
            var combo: KeyCombo?
            if !raw.isEmpty {
                switch EventSynth.parse(raw) {
                case .success(let stroke): combo = KeyCombo(keyCode: stroke.key.code, flags: stroke.flags)
                case .failure(let e): return .error(e.message)
                }
            }
            if name == "setToggleHotkey" { prefs.toggleHotkey = combo } else { prefs.newNoteHotkey = combo }
        case "pasteWebKit":  // WebKit's own paste, bypassing native interception (what a Safari page would get)
            if let error = ensureKey() { return error }
            web.webView.pasteThroughWebKit()
        case "reload": web.load()
        case "quit":
            // Run-loop timer, not GCD: terminate's nested run loop must be able to drain the main queue.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05)
            return .json(["ok": true, "quitting": true])
        case "url":
            guard let raw = value as? String, let url = URL(string: raw) else { return .error("url needs value: basicnotes://…") }
            URLRoutes.handle(url, coordinator: coordinator)
        default:
            return .error("unknown action \(name); use toggle|show|hide|new|search|open|settings|closeSettings|setVim|setHideFromCapture|setNotesDir|setToggleHotkey|setNewNoteHotkey|reload|url|quit")
        }
        try? await Task.sleep(for: .milliseconds(120))
        await settle(nil)
        return .json(["ok": true, "visible": panel.isVisible, "key": panel.isKey])
    }

    private func resize(_ body: [String: Any]) async -> Response {
        let w = (body["width"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let h = (body["height"] as? NSNumber).map { CGFloat($0.doubleValue) }
        guard w != nil || h != nil else { return .error("need width and/or height") }
        panel.resize(width: w, height: h)
        await settle(60)
        let f = panel.panel.frame
        return .json(["ok": true, "frame": ["x": f.minX, "y": f.minY, "width": f.width, "height": f.height]])
    }

    // MARK: Pasteboard

    private func setPasteboard(_ body: [String: Any]) -> Response {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        var wrote: [String] = []
        if let text = body["text"] as? String { item.setString(text, forType: .string); wrote.append("string") }
        if let html = body["html"] as? String { item.setString(html, forType: .html); wrote.append("html") }
        if let path = body["imagePath"] as? String {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else { return .error("can't read \(path)") }
            let ext = url.pathExtension.lowercased()
            if ext == "png" { item.setData(data, forType: .png); wrote.append("png") }
            if ext == "jpg" || ext == "jpeg" { item.setData(data, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)); wrote.append("jpeg") }
            if let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff); wrote.append("tiff") }
        }
        if !item.types.isEmpty { pb.writeObjects([item]) }
        if let path = body["filePath"] as? String {
            pb.writeObjects([URL(fileURLWithPath: (path as NSString).expandingTildeInPath) as NSURL])
            wrote.append("file-url")
        }
        return .json(["ok": true, "wrote": wrote, "types": pb.types?.map(\.rawValue) ?? []])
    }

    private func getPasteboard(full: Bool) -> Response {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let string = pb.string(forType: .string)
        let html = pb.string(forType: .html)
        let clip: (String?) -> Any = { s in
            guard let s else { return NSNull() }
            return full || s.count <= 4000 ? s : String(s.prefix(4000)) + "…[truncated, use ?full=1]"
        }
        let count: (String?, String) -> Int = { s, needle in s.map { $0.components(separatedBy: needle).count - 1 } ?? 0 }
        return .json([
            "types": types.map { ["type": $0.rawValue, "bytes": pb.data(forType: $0)?.count ?? 0] },
            "string": clip(string),
            "stringLength": string?.count ?? 0,
            "html": clip(html),
            "htmlLength": html?.count ?? 0,
            "stringDataURIImages": count(string, "data:image/"),  // inline `](data:`, `](<data:` and `[ref]: data:` alike
            "htmlDataURIImages": count(html, "src=\"data:image/"),
            "changeCount": pb.changeCount,
            "items": (pb.pasteboardItems ?? []).map { item in
                ["types": item.types.map(\.rawValue), "fileURL": item.string(forType: .fileURL) ?? NSNull()] as [String: Any]
            },
        ])
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return ["1", "true", "on", "yes"].contains(s.lowercased()) }
        return nil
    }
}
