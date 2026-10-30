import ServiceManagement

/// "Open at login" via SMAppService (the app itself as a login item).
enum LoginItem {
    /// On, or waiting for the user's approval in System Settings › Login Items.
    static var isEnabled: Bool { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notRegistered: "notRegistered"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    @discardableResult
    static func set(_ on: Bool) -> Result<Void, BridgeError> {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.info("open at login \(on ? "on" : "off") (\(statusDescription))")
            return .success(())
        } catch {
            Log.error("open at login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
            return .failure(BridgeError(error.localizedDescription))
        }
    }
}
