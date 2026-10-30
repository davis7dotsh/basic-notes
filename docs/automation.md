# Automation

Drive the real app without screen access. With `NBM_AUTOMATION=1` the app serves a JSON HTTP API on `127.0.0.1:47823` (`NBM_AUTOMATION_PORT`). Snapshots render in-process, so they work with the display asleep, the screen locked, and no Screen Recording / Accessibility permission.

## Launch an isolated instance

```sh
DERIVED=build/dd-test scripts/run-test-app.sh --build --register --exclusive   # build (web + app), launch, wait for the server
scripts/run-test-app.sh --app build/dd-shell/Build/Products/Debug/BasicNotes.app   # reuse an existing build
```

Each run uses a fresh temp notes folder, state dir, and UserDefaults suite, prints the paths, and stops the previous test instance first. `--notes DIR` reuses a folder. `--register` registers the bundle with LaunchServices so `open -g basicnotes://…` reaches it (LaunchServices ignores app copies under `/tmp`); `--exclusive` also quits any other running copy so deeplinks have exactly one target.

Env overrides (any launch): `NBM_NOTES_DIR`, `NBM_STATE_DIR`, `NBM_DEFAULTS_SUITE`, `NBM_AUTOMATION=1`, `NBM_AUTOMATION_PORT`.

## CLI: `scripts/nbm`

```sh
scripts/nbm state                      # panel visible/key/frame, current note, settings, web focus/vim probe
scripts/nbm snap /tmp/a.png 2          # PNG of the panel (native strip + editor), scale 2
scripts/nbm snap-settings /tmp/s.png   # PNG of the settings window (after `nbm settings`)
scripts/nbm show | hide | toggle | new | search | settings | close-settings | reload | quit
scripts/nbm open <note-id>
scripts/nbm type "# Title\nbody"       # real key events per character (\n = return)
scripts/nbm key cmd+shift+c            # one combo
scripts/nbm keys esc j j d d           # sequence
scripts/nbm click 120 60 [right] [2]   # panel content coords, top-left origin, points
scripts/nbm js "document.title"        # expressions auto-return; use return/await for bodies
scripts/nbm vim on|off
scripts/nbm action setHideFromCapture true | setNotesDir /path | url basicnotes://new
scripts/nbm action setToggleHotkey cmd+shift+3   # or setNewNoteHotkey; "" clears. Taken combos show in state.settings.unavailableHotkeys
scripts/nbm paste-image shot.png && scripts/nbm key cmd+v    # native image paste → assets/
scripts/nbm paste-file photo.jpg && scripts/nbm key cmd+v    # Finder-style file copy
scripts/nbm key cmd+shift+c && scripts/nbm pasteboard        # types, sizes, data-URI image counts, per-item types (`pasteboard full` for everything)
scripts/nbm resize 600 500             # top-anchored, clamped to the screen, persisted like a manual resize
scripts/nbm logs 50                    # bridge + app log ring buffer
scripts/nbm url basicnotes://toggle  # through LaunchServices (needs --register)
```

## HTTP API

| Method | Path | Body / query |
| --- | --- | --- |
| GET | `/state` | |
| GET | `/snapshot` | `?scale=1`, `&window=settings` |
| POST | `/js` | `{"code": "..."}` → `{"result": …}` |
| POST | `/key` | `{"combo": "cmd+shift+c"}` |
| POST | `/keys` | `{"sequence": ["esc","j"], "delayMs"?: 0}` |
| POST | `/type` | `{"text": "hi\n"}` |
| POST | `/click` | `{"x":…, "y":…, "button":"left", "clickCount":1}` |
| POST | `/action` | `{"name": "toggle|show|hide|new|search|open|settings|closeSettings|setVim|setHideFromCapture|setNotesDir|setToggleHotkey|setNewNoteHotkey|reload|url|quit", "value"?: …}` |
| POST | `/pasteboard` | `{"text"?, "html"?, "imagePath"?, "filePath"?}` |
| GET | `/pasteboard` | `?full=1` |
| POST | `/resize` | `{"width"?, "height"?}` |
| GET | `/logs` | `?n=200` |

## Notes

- Key events are real `NSEvent`s sent through `NSApp.sendEvent`, so the main menu (⌘V paste path), key equivalents, and WebKit text input behave like real typing. Combo names: `cmd shift alt/opt ctrl` + a character or `esc return tab space backspace delete forwarddelete up down left right home end pageup pagedown f1…f12 plus`.
- When the session can't make the panel key (screen locked), automation mode fakes key status for the panel (`state.panel.keyForced: true`) so WebKit treats the page as focused. That only happens with `NBM_AUTOMATION=1`.
- Input endpoints need the panel visible (`nbm show`). Each call waits for WebKit to drain before returning.
- A fresh defaults suite is a first launch: the panel opens with a new blank note (every `run-test-app.sh` run). Open-at-login is never auto-registered for test instances (`NBM_AUTOMATION=1` or `NBM_DEFAULTS_SUITE`).
- `state.panel.pageZoom` is the editor zoom (⌘= / ⌘-). `state.note` also reports `folderMissing` (notes folder gone), `failedSaveID` (last save that failed and hasn't been retried successfully), `pendingIDs` (notes whose text is waiting to go back into a restored folder), `heldRecoveryFiles` (recovery files mirroring held text) and `unheldCount` (held texts no recovery directory took). Toasts sent to the page are logged (`nbm logs | grep toast`). Native toasts raised while the panel is hidden are held (`toast queued until shown`) and sent on the next show.
- `snap-settings` rebuilds the settings view before capturing, so it reflects current prefs even with the display asleep.
- Text the app holds outside the notes folder (a failed save, a note pending re-save into a restored folder, a note left while the folder was missing, unsaved text at quit) is mirrored right away into a recovery file `<id>-<yyyyMMdd-HHmmss>[-n].md` (one per held text, rewritten when it changes) and removed once that text is in the notes folder (saved, re-saved, kept as a conflict copy) or superseded by a later save. Reopening a note with a pending re-save shows the pending text (the folder's version stays unacknowledged, so both are kept), unless it can be written as a copy first. Recovery files go to the first writable of `state.note.recoveryDirs`: `<state>/recovery/`, then `~/Library/Caches/<bundle id>/recovery/<key>`, then `$TMPDIR/<bundle id>-recovery/<key>` (`<key>` = hash of the state root, so isolated instances don't share). Launch imports from all of them as `<id>-recovered-<yyyyMMdd-HHmmss>.md` in the current notes folder, presents the newest one, and toasts (on the first show if launched hidden); a recovery file is removed only after its import is written (or when a note there already holds exactly its text). If none is writable, quit is cancelled (error toast, panel shown, buffer kept); the 3s quit fallback won't force it either.
- Notes folder back but read-only: the open note's failed re-save shows "Not saved" + an error toast right away and is retried (1s, 2s, 5s, then every 10s) while it stays open. Text that was the editor's when the folder came back ends as the note wherever it lands (that retry, reopening, a save, quit/switch); the restored file becomes the `-conflict-` copy, as with a writable folder.
- Folder switch with an unsaveable buffer: the text is written into the destination as a new note before anything swaps. If that write fails, the switch is cancelled — same folder/note, still "Not saved", error toast, and the folder preference reverts.
- `nbm pasteboard full` → `stringDataURIImages` counts every `data:image/` in the text (inline, `<…>` and reference-definition destinations).
- External removal of the open note (deleted, or renamed to a non-note name) while the editor has unsaved edits: the save writes the file back, the note stays open, and an info toast says so. With nothing unsaved, the newest other note opens.
- External rename of the open note (Finder, another app; another `.md` name in the folder): the editor goes on under the new id (`retarget`) — nothing reloads, so typing, undo and pending saves carry on into the renamed file. A save that beats the watcher to the rename finds the file by its inode and writes there (logged `save <id>: its file was renamed to <new>`).
- Delete (`⌘⇧⌫`) writes the editor's text first if it differs from disk, so the Trash holds what was on screen; the log line `trashed <id> → <path>` gives the Trash location (atomic writes replace the inode, so an fd held on the pre-delete file sees the old bytes).
- Note files that can't be read (not UTF-8, over 20MB, permissions) are left untouched and skipped; each is reported once per launch with an info toast.
