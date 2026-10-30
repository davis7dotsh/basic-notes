import AppKit

/// Menu-bar status item + the (hidden, LSUIElement) main menu that makes ⌘C/⌘V/⌘X/⌘Z/⌘⇧Z/⌘A work in the web view.
final class MenuBar: NSObject, NSMenuDelegate {
    struct Actions {
        var toggle: () -> Void
        var newNote: () -> Void
        var search: () -> Void
        var settings: () -> Void
        var quit: () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let actions: Actions
    private let prefs: Preferences
    private let toggleItem = NSMenuItem(title: "Toggle Notes", action: #selector(toggle), keyEquivalent: "")
    private let newItem = NSMenuItem(title: "New Note", action: #selector(newNote), keyEquivalent: "")

    init(prefs: Preferences, actions: Actions) {
        self.prefs = prefs
        self.actions = actions
        super.init()
        if let button = statusItem.button {
            let image = NSImage(named: "StatusIcon")
            image?.isTemplate = true
            image?.accessibilityDescription = "Basic Notes"
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        let searchItem = NSMenuItem(title: "Search Notes", action: #selector(search), keyEquivalent: "")
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settings), keyEquivalent: ",")
        let quitItem = NSMenuItem(title: "Quit Basic Notes", action: #selector(quit), keyEquivalent: "q")
        for item in [toggleItem, newItem, searchItem, settingsItem, quitItem] { item.target = self }
        menu.items = [toggleItem, newItem, searchItem, .separator(), settingsItem, .separator(), quitItem]
        statusItem.menu = menu
        refreshHotkeys()
        Self.installMainMenu(settingsTarget: self)
    }

    func refreshHotkeys() {
        apply(prefs.toggleHotkey, to: toggleItem)
        apply(prefs.newNoteHotkey, to: newItem)
    }

    func menuWillOpen(_ menu: NSMenu) { refreshHotkeys() }

    private func apply(_ combo: KeyCombo?, to item: NSMenuItem) {
        guard let combo else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = KeyCodes.menuEquivalent(for: combo.keyCode)
        item.keyEquivalentModifierMask = combo.flags
    }

    @objc private func toggle() { actions.toggle() }
    @objc private func newNote() { actions.newNote() }
    @objc private func search() { actions.search() }
    @objc func settings() { actions.settings() }
    @objc private func quit() { actions.quit() }

    private static func installMainMenu(settingsTarget: MenuBar) {
        let main = NSMenu()

        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuBar.settings), keyEquivalent: ",")
        settings.target = settingsTarget
        appMenu.items = [settings]
        let appItem = NSMenuItem()
        appItem.submenu = appMenu

        let edit = NSMenu(title: "Edit")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        let pastePlain = NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.items = [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            redo,
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            pastePlain,
            NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]
        let editItem = NSMenuItem()
        editItem.submenu = edit

        main.items = [appItem, editItem]
        NSApp.mainMenu = main
    }
}
