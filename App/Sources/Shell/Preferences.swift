import AppKit
import Observation

/// User settings, persisted in UserDefaults (suite overridable via NBM_DEFAULTS_SUITE).
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: ((Change) -> Void)?

    enum Change { case notesFolder, hotkeys, vim, hideFromCapture }

    var notesFolder: URL { didSet { defaults.set(notesFolder.path, forKey: K.notesFolder); onChange?(.notesFolder) } }
    var toggleHotkey: KeyCombo? { didSet { saveHotkeys() } }
    var newNoteHotkey: KeyCombo? { didSet { saveHotkeys() } }
    var vimEnabled: Bool { didSet { defaults.set(vimEnabled, forKey: K.vim); onChange?(.vim) } }
    var hideFromCapture: Bool { didSet { defaults.set(hideFromCapture, forKey: K.hideFromCapture); onChange?(.hideFromCapture) } }
    /// Hotkeys that are set but won't fire (taken by the system/another app). Not persisted.
    var unavailableHotkeys: Set<KeyCombo> = []

    /// Nothing of ours was in this defaults domain at launch (captured before anything is written).
    @ObservationIgnored let isFirstLaunch: Bool
    func markLaunched() { defaults.set(true, forKey: K.launched) }

    /// Open-at-login is registered automatically once; after that the user's choice sticks.
    @ObservationIgnored var loginItemAutoRegistered: Bool {
        get { defaults.bool(forKey: K.loginAuto) }
        set { defaults.set(newValue, forKey: K.loginAuto) }
    }

    /// Panel geometry: x, top edge (screen coords), width, height.
    @ObservationIgnored var panelGeometry: PanelGeometry? {
        get { Self.decode(defaults.data(forKey: K.panel)) }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: K.panel) }
    }

    /// Editor zoom (⌘= / ⌘-), 1 = 100%.
    @ObservationIgnored var pageZoom: Double {
        get { defaults.double(forKey: K.zoom) > 0 ? defaults.double(forKey: K.zoom) : 1 }
        set { defaults.set(newValue, forKey: K.zoom) }
    }

    private enum K {
        static let notesFolder = "notesFolder", hotkeys = "hotkeys", vim = "vimEnabled"
        static let hideFromCapture = "hideFromCapture", panel = "panelGeometry", zoom = "pageZoom"
        static let launched = "hasLaunched", loginAuto = "loginItemAutoRegistered"
    }

    private struct Hotkeys: Codable { var toggle: KeyCombo?; var new: KeyCombo? }

    init(defaults: UserDefaults, notesFolderOverride: URL?) {
        self.defaults = defaults
        isFirstLaunch = [K.launched, K.panel, K.hotkeys, K.notesFolder].allSatisfy { defaults.object(forKey: $0) == nil }
        let defaultFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Notes", isDirectory: true)
        notesFolder = notesFolderOverride
            ?? defaults.string(forKey: K.notesFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultFolder
        vimEnabled = defaults.bool(forKey: K.vim)
        hideFromCapture = defaults.bool(forKey: K.hideFromCapture)
        // Defaults apply until the user edits hotkeys; a cleared hotkey stays cleared.
        let stored: Hotkeys? = Self.decode(defaults.data(forKey: K.hotkeys))
        toggleHotkey = stored == nil ? .defaultToggle : stored?.toggle
        newNoteHotkey = stored == nil ? .defaultNew : stored?.new
    }

    var editorSettings: EditorSettings { EditorSettings(vimEnabled: vimEnabled) }

    private func saveHotkeys() {
        defaults.set(try? JSONEncoder().encode(Hotkeys(toggle: toggleHotkey, new: newNoteHotkey)), forKey: K.hotkeys)
        onChange?(.hotkeys)
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? { data.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
}

struct PanelGeometry: Codable, Equatable {
    var x: Double
    var top: Double
    var width: Double
    /// nil in geometry saved before the panel had a fixed height (it auto-grew up to a cap): the default height.
    var height: Double?
}
