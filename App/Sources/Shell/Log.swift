import Foundation
import os

/// os_log + an in-memory ring buffer (served by the automation server at GET /logs).
enum Log {
    private static let logger = Logger(subsystem: "sh.davis7.basicnotes", category: "app")
    private static var ring: [String] = []
    private static let capacity = 600
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { append("info", message); logger.info("\(message, privacy: .public)") }
    static func debug(_ message: String) { append("debug", message); logger.debug("\(message, privacy: .public)") }
    static func warn(_ message: String) { append("warn", message); logger.warning("\(message, privacy: .public)") }
    static func error(_ message: String) { append("error", message); logger.error("\(message, privacy: .public)") }

    static func level(_ level: String, _ message: String) {
        switch level {
        case "error": error(message)
        case "warn": warn(message)
        case "debug": debug(message)
        default: info(message)
        }
    }

    static func recent(_ n: Int) -> [String] { Array(ring.suffix(max(0, n))) }

    private static func append(_ level: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(level)] \(message.count > 400 ? String(message.prefix(400)) + "…" : message)"
        ring.append(line)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
    }
}
