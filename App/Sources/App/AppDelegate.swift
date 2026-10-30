import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: Coordinator?
    private var menuBar: MenuBar?
    private var settings: SettingsWindowController?
    private var automation: HTTPServer?
    private var pendingURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Markdown editor: no smart quotes/dashes, autocorrect, or text replacement from WebKit's text checker.
        UserDefaults.standard.register(defaults: [
            "WebAutomaticDashSubstitutionEnabled": false,
            "WebAutomaticQuoteSubstitutionEnabled": false,
            "WebAutomaticTextReplacementEnabled": false,
            "WebAutomaticSpellingCorrectionEnabled": false,
            "WebAutomaticLinkDetectionEnabled": false,
        ])
        // Handle URLs from launch onward (Raycast `open -g basicnotes://toggle`).
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = LaunchEnvironment.current()
        let prefs = Preferences(defaults: env.defaults, notesFolderOverride: env.notesDirOverride)
        try? FileManager.default.createDirectory(at: prefs.notesFolder, withIntermediateDirectories: true)
        let firstLaunch = prefs.isFirstLaunch

        let coordinator = Coordinator(env: env, prefs: prefs)
        let settings = SettingsWindowController(prefs: prefs)
        coordinator.onOpenSettings = { settings.show() }
        self.coordinator = coordinator
        self.settings = settings

        menuBar = MenuBar(prefs: prefs, actions: .init(
            toggle: { coordinator.toggle() },
            newNote: { coordinator.newNote() },
            search: { coordinator.openSearch() },
            settings: { settings.show() },
            quit: { NSApp.terminate(nil) }))

        prefs.onChange = { [weak self] change in
            coordinator.settingsChanged(change)
            if change == .hotkeys { self?.registerHotkeys(prefs) }
        }
        Hotkeys.shared.onAvailabilityChange = { prefs.unavailableHotkeys = $0 }
        registerHotkeys(prefs)

        // Open at login defaults to on: register once; after that the user's choice (Settings) sticks.
        if !env.isIsolated, !prefs.loginItemAutoRegistered {
            prefs.loginItemAutoRegistered = true
            LoginItem.set(true)
        }
        prefs.markLaunched()

        if let port = env.automationPort {
            let routes = AutomationRoutes(coordinator: coordinator, prefs: prefs, settings: settings)
            let server = HTTPServer { await routes.handle($0) }
            if case .failure(let error) = server.start(port: port) { Log.error(error.message) }
            automation = server
        }

        coordinator.start()
        // First launch: show what was installed — the panel with a fresh note.
        if firstLaunch { coordinator.newNote() }
        Log.info("launched\(firstLaunch ? " (first launch)" : ""); notes folder \(prefs.notesFolder.path)")
        pendingURLs.forEach { URLRoutes.handle($0, coordinator: coordinator) }
        pendingURLs = []
    }

    private func registerHotkeys(_ prefs: Preferences) {
        guard let coordinator else { return }
        var bindings: [(KeyCombo, () -> Void)] = []
        if let combo = prefs.toggleHotkey { bindings.append((combo, { coordinator.toggle() })) }
        if let combo = prefs.newNoteHotkey { bindings.append((combo, { coordinator.newNote() })) }
        Hotkeys.shared.set(bindings)
        menuBar?.refreshHotkeys()
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: raw) else { return }
        if let coordinator { URLRoutes.handle(url, coordinator: coordinator) } else { pendingURLs.append(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        let reply = TerminateReply { quit in if !quit { coordinator.quitCancelled() } }
        Task { reply.send(await coordinator.prepareForQuit()) }
        // Never hang on quit: a run-loop timer still fires if the main queue can't be drained. It still won't quit
        // while known-unsaved text can't be written anywhere.
        let fallback = Timer(timeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated { if !reply.sent { reply.send(coordinator.recoverForForcedQuit()) } }
        }
        RunLoop.main.add(fallback, forMode: .common)
        return .terminateLater
    }

    /// Reopen (e.g. launching the app again from Finder/Spotlight) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.show()
        return false
    }
}

/// Replies to applicationShouldTerminate exactly once (true = quit, false = cancel).
private final class TerminateReply {
    private(set) var sent = false
    private let onReply: (Bool) -> Void
    init(onReply: @escaping (Bool) -> Void) { self.onReply = onReply }
    func send(_ quit: Bool) {
        guard !sent else { return }
        sent = true
        NSApp.reply(toApplicationShouldTerminate: quit)
        onReply(quit)
    }
}
