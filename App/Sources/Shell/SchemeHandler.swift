import Foundation
import UniformTypeIdentifiers
import WebKit

/// `nbm://app/<path>` → bundled Web/ resources. `nbm://notes/<path>` → files inside the notes folder (images).
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private let webRoot: URL?
    private let resolveNote: (String) -> URL?
    private var active = Set<ObjectIdentifier>()

    init(resolveNote: @escaping (String) -> URL?) {
        webRoot = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true).standardizedFileURL
        self.resolveNote = resolveNote
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        active.insert(key)
        defer { active.remove(key) }
        guard let url = task.request.url else { return fail(task, 400) }
        let path = String(url.path.drop(while: { $0 == "/" }))
        let file: URL? = switch url.host {
        case "app": appFile(path) ?? (path.hasPrefix("assets/") ? resolveNote(path) : nil)
        case "notes": resolveNote(path)
        default: nil
        }
        guard let file, let data = try? Data(contentsOf: file) else { return fail(task, 404) }
        guard active.contains(key) else { return }
        let headers = [
            "Content-Type": Self.mimeType(file.pathExtension),
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-cache",
            "Access-Control-Allow-Origin": "*",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: Self.mimeType(file.pathExtension), expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    private func appFile(_ path: String) -> URL? {
        guard let webRoot else { return nil }
        let file = webRoot.appendingPathComponent(path.isEmpty ? "index.html" : path).standardizedFileURL
        guard file.path.hasPrefix(webRoot.path + "/"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    private func fail(_ task: any WKURLSchemeTask, _ status: Int) {
        guard let url = task.request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        task.didReceive(response)
        task.didFinish()
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json", "map": "application/json"
        case "svg": "image/svg+xml"
        case "wasm": "application/wasm"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "tif", "tiff": "image/tiff"
        default: UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
