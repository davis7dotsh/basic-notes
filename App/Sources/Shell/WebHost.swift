import AppKit
import WebKit

struct BridgeError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

typealias BridgeReply = Result<Any?, BridgeError>

/// Hosts the editor page and implements the Swift side of the bridge (see Core/BridgeProtocol.swift).
final class WebHost: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    let webView: EditorWebView
    /// True between the page's `ready` message and the next navigation/crash.
    private(set) var isReady = false
    var onMessage: ((ToSwift) async -> BridgeReply)?
    var onWebProcessCrash: (() -> Void)?
    private let encoder = JSONEncoder()

    init(resolveNote: @escaping (String) -> URL?, automation: Bool) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler(resolveNote: resolveNote), forURLScheme: "nbm")
        config.suppressesIncrementalRendering = true
        config.preferences.isElementFullscreenEnabled = false
        webView = EditorWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "bridge")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Transparent: the panel's glass shows through the page (and there's no white flash before first paint).
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        if automation {
            webView.isInspectable = true
            // Keep rendering when the window is occluded / the display is asleep (automation snapshots).
            Self.setPrivateBool(webView, "_setWindowOcclusionDetectionEnabled:", false)
        }
    }

    func load() {
        isReady = false
        guard let url = URL(string: "nbm://app/index.html") else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: Swift -> JS

    func send(_ message: FromSwift) {
        if case .toast = message { Log.info("→ \(Self.describe(message))") }
        guard isReady else {
            Log.debug("drop \(Self.describe(message)) (page not ready)")
            return
        }
        guard let data = try? encoder.encode(message), let json = String(data: data, encoding: .utf8) else {
            Log.error("encode failed: \(Self.describe(message))")
            return
        }
        webView.evaluateJavaScript("window.__nbm && window.__nbm.receive(\(json))") { _, error in
            if let error { Log.error("receive failed: \(error.localizedDescription)") }
        }
    }

    enum FlushOutcome: Equatable {
        case ok
        /// The editor's save was rejected: its buffer is the only copy — don't replace it.
        case failed(String)
        case timedOut
        case notReady
    }

    /// Ask the editor to send any pending save; returns when done (or after a timeout).
    @discardableResult
    func flush(timeout: Double = 1.5) async -> FlushOutcome {
        guard isReady else { return .notReady }
        let result: Result<Void, BridgeError>? = await withTimeout(timeout) { [webView] in
            do {
                _ = try await webView.callAsyncJavaScript("if (window.__nbm) await window.__nbm.flush(); return true", contentWorld: .page)
                return .success(())
            } catch {
                return .failure(BridgeError(Self.jsErrorMessage(error)))
            }
        }
        switch result {
        case .success?: return .ok
        case .failure(let error)?:
            Log.warn("flush failed: \(error.message)")
            return .failed(error.message)
        case nil:
            Log.warn("flush timed out")
            return .timedOut
        }
    }

    /// Drop every dirty session / pending retry in the editor without saving (its buffer was carried elsewhere).
    func discardPendingSaves() async {
        guard isReady else { return }
        let done: Bool? = await withTimeout(1.5) { [webView] in
            (try? await webView.callAsyncJavaScript(
                "if (window.__nbm && window.__nbm.discardPendingSaves) { window.__nbm.discardPendingSaves(); return true } return false",
                contentWorld: .page)) as? Bool ?? false
        }
        if done != true { Log.warn("discardPendingSaves unavailable or timed out") }
    }

    /// The editor's current text, read straight from CodeMirror (recovery when saving failed). nil if unavailable.
    func editorContent() async -> String? {
        let js = """
        const el = document.querySelector('.cm-content');
        const view = el && ((el.cmTile && el.cmTile.view) || (el.cmView && el.cmView.view));
        return view ? view.state.doc.toString() : null;
        """
        guard case .success(let data) = await evaluate(body: js, timeout: 1) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }

    /// true = applied, false = editor dirty (keep editor), nil = page unavailable/timeout.
    func applyExternal(id: NoteID, content: String) async -> Bool? {
        guard isReady else { return nil }
        return await withTimeout(1.5) { [webView] in
            (try? await webView.callAsyncJavaScript(
                "return window.__nbm ? window.__nbm.applyExternal(id, content) : null",
                arguments: ["id": id, "content": content], contentWorld: .page)) as? Bool
        } ?? nil
    }

    /// Evaluate an async function body in the page; result serialized as JSON data.
    func evaluate(body: String, arguments: [String: String] = [:], timeout: Double = 10) async -> Result<Data, BridgeError> {
        let outcome: Result<Data, BridgeError>? = await withTimeout(timeout) { [webView] in
            do {
                let value = try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
                return .success(Self.json(value ?? NSNull()))
            } catch {
                return .failure(BridgeError(Self.jsErrorMessage(error)))
            }
        }
        return outcome ?? .failure(BridgeError("timed out after \(timeout)s"))
    }

    // MARK: JS -> Swift

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let decoded: ToSwift
        do {
            let data: Data
            if let plain = try? JSONSerialization.data(withJSONObject: message.body, options: [.fragmentsAllowed]) {
                data = plain
            } else {
                // A JS string with a lone UTF-16 surrogate (half an emoji) has no UTF-8 form, so the message can't be read
                // at all — a save would fail on every retry. Take it with U+FFFD in place of each one: the note stays saveable.
                data = try JSONSerialization.data(withJSONObject: Self.replacingLoneSurrogates(message.body), options: [.fragmentsAllowed])
                Log.warn("bridge message had unpaired UTF-16 surrogates — replaced with U+FFFD")
            }
            decoded = try JSONDecoder().decode(ToSwift.self, from: data)
        } catch {
            Log.error("bad bridge message: \(error)")
            return (nil, "bad message: \(error)")
        }
        if case .ready = decoded { isReady = true }
        if Self.shouldLog(decoded) { Log.debug("js→ \(Self.describe(decoded))") }
        guard let onMessage else { return (nil, nil) }
        switch await onMessage(decoded) {
        case .success(let value): return (value, nil)
        case .failure(let error):
            Log.error("bridge \(Self.describe(decoded)) failed: \(error.message)")
            return (nil, error.message)
        }
    }

    // MARK: Navigation / UI delegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == "nbm" { return .allow }
        // Never navigate the editor away; links open externally via the openURL bridge message.
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isReady = false
        self.webView.searchOpen = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.error("web content process terminated; reloading")
        isReady = false
        self.webView.searchOpen = false
        onWebProcessCrash?()
        load()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Log.error("navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Log.error("provisional navigation failed: \(error.localizedDescription)")
    }

    // MARK: Helpers

    /// The message body with every string's lone UTF-16 surrogates replaced by U+FFFD (Swift's UTF-16 decoding repairs them).
    static func replacingLoneSurrogates(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues(replacingLoneSurrogates)
        case let array as [Any]: return array.map(replacingLoneSurrogates)
        case let string as NSString:
            var units = [unichar](repeating: 0, count: string.length)
            string.getCharacters(&units, range: NSRange(location: 0, length: string.length))
            return String(decoding: units, as: UTF16.self)
        default: return value
        }
    }

    private static func shouldLog(_ msg: ToSwift) -> Bool {
        switch msg {
        case .viewState, .log: false
        default: true
        }
    }

    static func describe(_ msg: ToSwift) -> String {
        switch msg {
        case .save(let id, let content): "save \(id) (\(content.utf8.count)b)"
        case .saveImage(_, let mime, _): "saveImage \(mime)"
        case .search(let q): "search \"\(q)\""
        case .open(let id): "open \(id)"
        case .deleteNote(let id): "deleteNote \(id)"
        case .togglePin(let id): "togglePin \(id)"
        case .openPin(let i): "openPin \(i)"
        case .copyNote(let id, let md, let html, let images): "copyNote \(id) (md \(md.utf8.count)b, html \(html.utf8.count)b, \(images.count) image ref(s))"
        case .openURL(let url): "openURL \(url)"
        case .setClipboard(let text, let replaced): "setClipboard (\(text.utf8.count)b\(replaced ? ", replaced" : ""))"
        default: String(describing: msg).components(separatedBy: "(").first ?? "?"
        }
    }

    static func describe(_ msg: FromSwift) -> String {
        switch msg {
        case .loadNote(let note): "loadNote \(note.id) isNew=\(note.isNew)"
        case .insertText(let text, let block, let token): "insertText\(block ? " block" : "")\(token.map { " [\($0.prefix(8))]" } ?? "") \(text.prefix(60))"
        case .toast(let message, let tone): "toast \(tone.rawValue) \(message)"
        case .unsavedText(let id, let unsaved): "unsavedText \(id) \(unsaved)"
        case .retarget(let from, let to): "retarget \(from) → \(to)"
        case .systemClipboard(let text, let ownCopy): "systemClipboard (\(text.utf8.count)b\(ownCopy ? ", own copy" : ""))"
        case .assetsChanged(let paths): "assetsChanged \(paths.prefix(5).joined(separator: ", "))\(paths.count > 5 ? " +\(paths.count - 5)" : "")"
        default: String(describing: msg).components(separatedBy: "(").first ?? "?"
        }
    }

    static func json(_ value: Any) -> Data {
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) { return data }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) { return data }
        return (try? JSONSerialization.data(withJSONObject: String(describing: value), options: [.fragmentsAllowed])) ?? Data("null".utf8)
    }

    private static func jsErrorMessage(_ error: any Error) -> String {
        let ns = error as NSError
        let message = ns.userInfo["WKJavaScriptExceptionMessage"] as? String
        let line = ns.userInfo["WKJavaScriptExceptionLineNumber"].map { " (line \($0))" } ?? ""
        return (message ?? ns.localizedDescription) + line
    }

    private static func setPrivateBool(_ object: NSObject, _ selectorName: String, _ value: Bool) {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector) else {
            Log.warn("\(selectorName) unavailable")
            return
        }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(object, selector, value)
    }
}

/// Runs `operation`, returning nil if it doesn't finish within `seconds` (the operation keeps running).
func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @MainActor () async -> T) async -> T? {
    let once = OnceFlag()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        Task { @MainActor in
            let value = await operation()
            guard !once.done else { return }
            once.done = true
            continuation.resume(returning: value)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !once.done else { return }
            once.done = true
            continuation.resume(returning: nil)
        }
    }
}

private final class OnceFlag { var done = false }
