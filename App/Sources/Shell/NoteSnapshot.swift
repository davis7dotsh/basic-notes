import AppKit
import WebKit

/// ⌘⇧C of a note with images: the whole note (text + images) rendered offscreen as one PNG, so apps that take only an
/// image from the pasteboard (chat apps) get all of it. One hidden web view, reused; renders run one at a time.
final class NoteSnapshot: NSObject, WKNavigationDelegate {
    static let width: CGFloat = 640
    static let scale: CGFloat = 2
    /// Tallest PNG in pixels: a longer note is scaled down to fit, never cropped.
    static let maxPixelsHigh: CGFloat = 10_000

    private var webView: WKWebView?
    private var window: NSWindow?
    private var loading: CheckedContinuation<Void, any Error>?
    private var tail: Task<Void, Never>?

    /// `html`: the note as a full document (ClipboardExport's, images as data URIs). Fails after `timeout`.
    func png(html: String, timeout: Duration = .seconds(3)) async -> Result<Data, BridgeError> {
        let previous = tail
        let run = Task { () -> Result<Data, BridgeError> in
            await previous?.value
            return await withTimeout(timeout) { await self.render(html) }
        }
        tail = Task { _ = await run.value }
        return await run.value
    }

    private func render(_ html: String) async -> Result<Data, BridgeError> {
        let (view, window) = webView.flatMap { v in self.window.map { (v, $0) } } ?? make()
        view.appearance = NSApp.effectiveAppearance
        window.setContentSize(NSSize(width: Self.width, height: 100))
        do {
            try await withCheckedThrowingContinuation { c in
                loading = c
                view.loadHTMLString(Self.head + html + "</body></html>", baseURL: nil)
            }
            let measured = try await view.callAsyncJavaScript(Self.measure, contentWorld: .defaultClient) as? Double ?? 0
            guard measured > 0 else { return .failure(BridgeError("empty page")) }
            let height = measured.rounded(.up)
            window.setContentSize(NSSize(width: Self.width, height: height))
            let scale = min(Self.scale, Self.maxPixelsHigh / height)
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: Self.width, height: height)
            config.afterScreenUpdates = true
            // The snapshot comes out at the screen's backing scale times snapshotWidth / rect width.
            config.snapshotWidth = NSNumber(value: Double(Self.width * scale / max(window.backingScaleFactor, 1)))
            let image = try await view.takeSnapshot(configuration: config)
            return Self.encode(image, width: Int((Self.width * scale).rounded()), height: Int((height * scale).rounded()))
        } catch {
            return .failure(BridgeError(error.localizedDescription))
        }
    }

    /// PNG at exactly `width`×`height` pixels (redrawn when the backing scale didn't come out as asked).
    private static func encode(_ image: NSImage, width: Int, height: Int) -> Result<Data, BridgeError> {
        guard var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .failure(BridgeError("no image")) }
        if cg.width != width || cg.height != height {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return .failure(BridgeError("bitmap allocation failed")) }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = ctx.makeImage() else { return .failure(BridgeError("bitmap allocation failed")) }
            cg = scaled
        }
        guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            return .failure(BridgeError("png encoding failed"))
        }
        return .success(png)
    }

    /// The web view lays out (and paints) in a window that is never shown.
    private func make() -> (WKWebView, NSWindow) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false  // the note's own HTML never runs scripts
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100), configuration: config)
        view.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: Self.width, height: 100), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = view
        webView = view
        self.window = window
        return (view, window)
    }

    /// Timed out: drop the web view (whatever it's stuck on) — the next render makes a fresh one.
    private func reset() {
        loading?.resume(throwing: BridgeError("reset"))
        loading = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.contentView = nil
        window?.close()
        webView = nil
        window = nil
    }

    private func withTimeout(_ timeout: Duration, _ work: @escaping () async -> Result<Data, BridgeError>) async -> Result<Data, BridgeError> {
        let once = Once()
        return await withCheckedContinuation { c in
            once.continuation = c
            let job = Task { once.finish(await work()) }
            once.timer = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, once.finish(.failure(BridgeError("timed out after \(timeout)"))) else { return }
                job.cancel()
                self.reset()
            }
        }
    }

    private final class Once {
        var continuation: CheckedContinuation<Result<Data, BridgeError>, Never>?
        var timer: Task<Void, Never>?
        @discardableResult func finish(_ result: Result<Data, BridgeError>) -> Bool {
            guard let c = continuation else { return false }
            continuation = nil
            timer?.cancel()
            c.resume(returning: result)
            return true
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading?.resume()
        loading = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loading?.resume(throwing: error)
        loading = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loading?.resume(throwing: error)
        loading = nil
    }

    /// Only the note itself loads in here (links in it never navigate).
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.navigationType == .other ? .allow : .cancel
    }

    // MARK: Page

    /// Every image decoded, then the laid-out height of the page.
    private static let measure = """
    await Promise.all([...document.images].map(i => i.decode().catch(() => {})))
    return Math.ceil(document.body.getBoundingClientRect().height)
    """

    /// Wraps the note's document (its own doctype/html/head/body tags inside are ignored or merged by the parser).
    private static let head = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><style>
    :root { color-scheme: light dark; --bg: #f4f5f9; --fg: #252933; --muted: #555e71; --rule: rgba(0,0,0,.12);
      --code-bg: rgba(0,0,0,.04); --inline-code-bg: rgba(0,0,0,.055); --link: #455b7b }
    @media (prefers-color-scheme: dark) { :root { --bg: #191b20; --fg: #e9edf4; --muted: #b5b8c2;
      --rule: rgba(255,255,255,.14); --code-bg: rgba(255,255,255,.05); --inline-code-bg: rgba(255,255,255,.075); --link: #c0cfe7 } }
    html { background: var(--bg) }
    html, body { margin: 0 }
    body { padding: 24px; color: var(--fg); font: 15px/1.55 -apple-system, BlinkMacSystemFont, sans-serif;
      overflow-wrap: anywhere; -webkit-font-smoothing: antialiased }
    body > :first-child, body > meta:first-child + * { margin-top: 0 }
    body > :last-child { margin-bottom: 0 }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.1em 0 .45em; font-weight: 650 }
    h1 { font-size: 1.6em } h2 { font-size: 1.35em } h3 { font-size: 1.15em } h4, h5, h6 { font-size: 1em }
    p, ul, ol, pre, blockquote, table { margin: 0 0 .75em }
    ul, ol { padding-left: 1.5em }
    li > ul, li > ol, li > p { margin: .1em 0 }
    li:has(> input[type=checkbox]) { list-style: none }
    li > input[type=checkbox] { appearance: none; width: 14px; height: 14px; margin: 0 .5em 0 -1.35em; vertical-align: -2px;
      border: 1.3px solid var(--muted); border-radius: 4px; box-sizing: border-box }
    li > input[type=checkbox]:checked { background: var(--link); border-color: var(--link) }
    li > input[type=checkbox]:checked::after { content: ""; display: block; width: 6px; height: 3px; margin: 3px 2px;
      border: solid var(--bg); border-width: 0 0 2px 2px; transform: rotate(-45deg) }
    a { color: var(--link); text-decoration-color: color-mix(in srgb, var(--link) 35%, transparent); text-underline-offset: 2px }
    code { font: .86em ui-monospace, 'SF Mono', Menlo, monospace; background: var(--inline-code-bg); border-radius: 4px; padding: .12em .32em }
    pre { background: var(--code-bg); border-radius: 8px; padding: 12px 14px; white-space: pre-wrap }
    pre code { background: none; padding: 0; font-size: .84em; line-height: 1.5 }
    blockquote { margin-left: 0; padding-left: 14px; border-left: 3px solid var(--rule); color: var(--muted) }
    hr { border: 0; border-top: 1px solid var(--rule); margin: 1.2em 0 }
    img { max-width: 100%; height: auto; border-radius: 6px; vertical-align: middle }
    table { border-collapse: collapse }
    th, td { border: 1px solid var(--rule); padding: 4px 10px; text-align: left }
    </style></head><body>
    """
}
