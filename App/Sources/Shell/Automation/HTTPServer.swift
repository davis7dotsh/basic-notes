import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1 (one request per connection). Only started when NBM_AUTOMATION=1.
final class HTTPServer {
    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var body: Data

        func json() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    struct Response {
        var status: Int = 200
        var contentType = "application/json"
        var body: Data

        static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])) ?? Data("null".utf8)
            return Response(status: status, body: data + Data("\n".utf8))
        }

        static func error(_ message: String, status: Int = 400) -> Response { .json(["error": message], status: status) }
    }

    private var listener: NWListener?
    private let handler: (Request) async -> Response

    init(handler: @escaping (Request) async -> Response) {
        self.handler = handler
    }

    func start(port: UInt16) -> Result<Void, BridgeError> {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failure(BridgeError("bad port \(port)")) }
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: Log.info("automation server on 127.0.0.1:\(port)")
                    case .failed(let error): Log.error("automation server failed: \(error)")
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            return .success(())
        } catch {
            return .failure(BridgeError("listen: \(error)"))
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    Task { @MainActor in
                        let response = await self.handler(request)
                        self.send(response, on: connection)
                    }
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error"][response.status] ?? "Status"
        let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Returns a request once headers + Content-Length bytes of body have arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" { length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        let components = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: components?.path ?? String(parts[1]), query: query, body: Data(body.prefix(length)))
    }
}
