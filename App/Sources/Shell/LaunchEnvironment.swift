import CryptoKit
import Foundation

/// Process-level configuration. Env overrides keep test runs isolated from real data:
/// NBM_NOTES_DIR, NBM_STATE_DIR, NBM_DEFAULTS_SUITE, NBM_AUTOMATION=1, NBM_AUTOMATION_PORT.
struct LaunchEnvironment {
    var notesDirOverride: URL?
    var stateRoot: URL
    var defaults: UserDefaults
    var automationPort: UInt16?
    /// Dev/test run (NBM_AUTOMATION=1 or a custom defaults suite): don't touch system-wide state like login items.
    var isIsolated = false

    static func current() -> LaunchEnvironment {
        let env = ProcessInfo.processInfo.environment
        let path: (String) -> URL? = { key in
            env[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let suite = env["NBM_DEFAULTS_SUITE"].flatMap { $0.isEmpty ? nil : UserDefaults(suiteName: $0) }
        let automation = env["NBM_AUTOMATION"] == "1"
        return LaunchEnvironment(
            notesDirOverride: path("NBM_NOTES_DIR"),
            stateRoot: path("NBM_STATE_DIR") ?? appSupport.appendingPathComponent("BasicNotes", isDirectory: true),
            defaults: suite ?? .standard,
            automationPort: automation ? UInt16(env["NBM_AUTOMATION_PORT"] ?? "") ?? 47823 : nil,
            isIsolated: automation || !(env["NBM_DEFAULTS_SUITE"] ?? "").isEmpty)
    }

    var isAutomation: Bool { automationPort != nil }

    /// Where unsaved text goes when it can't be saved (quit): `<state>/recovery`, then fallbacks for an unwritable
    /// state dir — `~/Library/Caches/<bundle id>/recovery/<key>`, then the temporary directory. Keyed by the state
    /// root so isolated (test) instances never import each other's text. Launch imports from all of them.
    var recoveryDirectories: [URL] {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleIdentifier ?? "sh.davis7.basicnotes"
        let key = Self.key(stateRoot.standardizedFileURL.path)
        var dirs = [stateRoot.appendingPathComponent("recovery", isDirectory: true)]
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            dirs.append(caches.appendingPathComponent("\(bundle)/recovery/\(key)", isDirectory: true))
        }
        dirs.append(fm.temporaryDirectory.appendingPathComponent("\(bundle)-recovery/\(key)", isDirectory: true))
        return dirs
    }

    private static func key(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// State + search index are per notes folder (note ids are only unique within a folder).
    func stateDirectory(for notesFolder: URL) -> URL {
        let key = Self.key(notesFolder.standardizedFileURL.path)
        let dir = stateRoot.appendingPathComponent("folders/\(key)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
