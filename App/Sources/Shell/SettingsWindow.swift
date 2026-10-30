import AppKit
import SwiftUI

/// Settings in a normal titled window. The app becomes a regular (Dock) app while it's open.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let prefs: Preferences

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var contentView: NSView? { window?.contentView }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Automation snapshots: a fresh view tree so controls show their current state. (Switch/state animations are
    /// display-driven and never finish while the display sleeps, so the live tree can lag behind prefs.)
    func rebuildContent() {
        guard let window else { return }
        let size = window.contentLayoutRect.size
        window.contentViewController = hostingController()
        window.setContentSize(size)
    }

    private func makeView(measuring: Bool = false) -> SettingsView {
        SettingsView(
            prefs: prefs,
            chooseFolder: { [weak self] in self?.chooseFolder() },
            measuring: measuring)
    }

    /// The window sets its own size (below); the form scrolls inside it.
    private func hostingController() -> NSHostingController<SettingsView> {
        let host = NSHostingController(rootView: makeView())
        host.sizingOptions = []
        return host
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: hostingController())
        window.title = "Basic Notes Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The whole form when it fits; capped to the screen (13" laptops) with the rest a scroll away.
        let full = NSHostingView(rootView: makeView(measuring: true)).fittingSize
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        let titleBar = window.frame.height - window.contentLayoutRect.height
        window.setContentSize(NSSize(width: SettingsView.width, height: min(full.height, visible - titleBar - 40)))
        window.center()
        return window
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = prefs.notesFolder
        panel.prompt = "Use Folder"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [prefs] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                if url.standardizedFileURL != prefs.notesFolder.standardizedFileURL { prefs.notesFolder = url }
            }
        }
    }
}

private struct SettingsView: View {
    @Bindable var prefs: Preferences
    var chooseFolder: () -> Void
    /// Laid out at full height (no scrolling) to measure the form's natural size.
    var measuring = false
    @State private var openAtLogin = LoginItem.isEnabled
    static let width: CGFloat = 460

    var body: some View {
        Form {
            Section {
                LabeledContent("Notes folder") {
                    HStack(spacing: 8) {
                        SwiftUI.Text((prefs.notesFolder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
            Section {
                LabeledContent("Toggle notes") { HotkeyRecorder(combo: $prefs.toggleHotkey, unavailable: prefs.unavailableHotkeys) }
                LabeledContent("New note") { HotkeyRecorder(combo: $prefs.newNoteHotkey, unavailable: prefs.unavailableHotkeys) }
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { on in
                    LoginItem.set(on)
                    openAtLogin = LoginItem.isEnabled
                }))
                Toggle("Vim mode", isOn: $prefs.vimEnabled)
                Toggle("Hide from screen capture", isOn: $prefs.hideFromCapture)
            }
            Section {
                DeeplinkRow(label: "Toggle", link: "basicnotes://toggle")
                DeeplinkRow(label: "New note", link: "basicnotes://new")
            }
            Section("Shortcuts") {
                ForEach(Self.shortcuts, id: \.0) { name, keys in
                    LabeledContent(name) { SwiftUI.Text(keys).foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear { openAtLogin = LoginItem.isEnabled }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: measuring)
    }
}

extension SettingsView {
    /// In-panel shortcuts (handled by the editor).
    static let shortcuts: [(String, String)] = [
        ("Search", "⌘P"),
        ("New note", "⌘N"),
        ("Back / forward", "⌘[  ⌘]"),
        ("Pin", "⌘⇧P"),
        ("Open pin", "⌘1 – ⌘0"),
        ("Copy note", "⌘⇧C"),
        ("Delete note", "⌘⇧⌫"),
        ("Toggle task", "⌘↩"),
        ("Bold / italic / strikethrough", "⌘B  ⌘I  ⌘⇧X"),
        ("Code / link", "⌘E  ⌘K"),
        ("Heading 1–3", "⌘⌥1 – ⌘⌥3"),
        ("Numbered / bullet / task list", "⌘⇧7  ⌘⇧8  ⌘⇧9"),
        ("Move line / duplicate line", "⌥↑  ⌥↓  ⇧⌥↓"),
        ("Hide", "Esc"),
    ]
}

private struct DeeplinkRow: View {
    var label: String
    var link: String
    @State private var copied = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                SwiftUI.Text(link).font(.system(.body, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 14)
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }
}

/// Click → press a combo (needs ⌘, ⌥ or ⌃) → saved. Esc cancels. ✕ clears.
private struct HotkeyRecorder: View {
    @Binding var combo: KeyCombo?
    /// Combos that are set but won't fire (taken by the system or another app).
    var unavailable: Set<KeyCombo>
    @State private var recording = false
    @State private var monitor: Any?

    private var taken: Bool { !recording && combo.map(unavailable.contains) == true }

    var body: some View {
        HStack(spacing: 6) {
            if taken {
                SwiftUI.Text("In use elsewhere").font(.callout).foregroundStyle(.red)
            }
            Button {
                recording ? stop() : start()
            } label: {
                SwiftUI.Text(recording ? "Press keys…" : combo?.display ?? "Record")
                    .frame(minWidth: 96)
                    .foregroundStyle(recording ? Color.accentColor : taken ? .red : combo == nil ? .secondary : .primary)
            }
            if combo != nil && !recording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        Hotkeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, flags.isEmpty { return stop() }  // Esc cancels
        let candidate = KeyCombo(keyCode: event.keyCode, flags: flags)
        guard candidate.isValidHotkey else { return NSSound.beep() }
        combo = candidate
        stop()
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Hotkeys.shared.resume()
    }
}
