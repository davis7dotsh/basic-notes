import Foundation

/// basicnotes://toggle | show | hide | new | search | settings | open?id=<id>
enum URLRoutes {
    static func handle(_ url: URL, coordinator: Coordinator, openSettings: (() -> Void)? = nil) {
        guard url.scheme?.lowercased() == "basicnotes" else { return }
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        Log.info("url: \(url.absoluteString)")
        switch action {
        case "toggle", "": coordinator.toggle()
        case "show": coordinator.show()
        case "hide": coordinator.hide()
        case "new": coordinator.newNote()
        case "search": coordinator.openSearch()
        case "settings": (openSettings ?? coordinator.onOpenSettings)?()
        case "open":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            if let id, !id.isEmpty { coordinator.open(id) } else { coordinator.show() }
        default: Log.warn("unknown url action \(action)")
        }
    }
}
