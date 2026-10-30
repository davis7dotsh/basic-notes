# Raycast extension

Commands: **Toggle Notes**, **New Note**, **Search Notes** (in-app ⌘P search), **Open Note** (pick a note from the notes folder). Each fires a `basicnotes://` deeplink with `open -g`, so the panel gets focus, not Raycast.

## Install

```sh
cd raycast && npm install && npm run dev
```

Once. `npm run dev` imports it into Raycast as a dev extension; it stays after you stop dev (Ctrl-C).

## Hotkeys

Raycast Settings → Extensions → Basic Notes → pick a command → Record Hotkey. E.g. Hyper+`\` for Toggle Notes (unbind it from Raycast Notes first).

Open Note reads `~/Notes` by default; change it under the extension's preferences if you moved the notes folder.

Author is `bmdavis419` (Raycast handle; `ray lint` checks it).

Deeplinks: `basicnotes://toggle` · `show` · `hide` · `new` · `search` · `settings` · `open?id=<note id>`
