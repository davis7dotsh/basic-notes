# Basic Notes — spec

Status: **Final** — accepted by Davis on 2026-10-25 ("vim opens in normal, names is fine, hide from capture is toggle start with it off, deeplink yes, and yes", helm T3 thread). This document is the input for a separate implementation stage on servitor, initiated by Davis.

## Goal

Minimal, clean, local-only macOS floating-notes app inspired by Raycast Notes.
Fix the gaps Davis hits in Raycast Notes without building a second Obsidian/Notion.

## Known requirements (from Davis, 2026-10-25)

- Paste images inline (missing in Raycast Notes)
- Vim-mode hotkeys for writing (missing in Raycast Notes)
- Easy copy-to-clipboard of the full note as Markdown, including its images (missing/awkward in Raycast Notes)
- Local only for now (no sync, no account)

## What Raycast Notes does today

Verified against the official manual/product pages plus third-party reports where noted.

- Floating only, one note visible at a time (a "stack"), auto-sizing window. Commands: toggle window (suggested `⌥N`), Create Note, Search Notes. Optional menu-bar button.
- Live-render WYSIWYG editor driven by Markdown shortcuts, `/` menu, hotkeys, `⌘K` Format, or format bar. H1–H3, bold/italic/strike/underline/inline code/links, bullet/ordered/task lists, code blocks, blockquote, hr, emoji via `:`, snippets expand inline. First line becomes the title. No tables/H4+/math/footnotes documented.
- No inline images or attachments documented anywhere; third-party reports say text-only, pasting an image yields a filename/path. Still requested by users in 2026.
- Vim: only a "Vim Motions" setting that adds `⌃H/J/K/L` navigation in lists. No modal editing in the editor.
- Organization: `⌘P` browse/search (title + content), pins with `⌘0`–`⌘9` jump, back/forward history, Recently Deleted (60 days), deeplinks/quicklinks per note. No tags/folders/archive documented.
- Storage: encrypted proprietary database, not `.md` files on disk. Cloud Sync + unlimited notes require Pro (free tier: 5 notes). Per-note export to plain text / Markdown / HTML exists; no export-all-to-Markdown. No one-keystroke "copy whole note as Markdown."
- AI (Pro): send note to AI Chat (`⌘J`), AI commands, AI can create/edit notes.
- Implementation note: Raycast's own editor is a React app in WKWebView inside a native window.

Sources: https://manual.raycast.com/notes · https://www.raycast.com/core-features/notes · https://www.raycast.com/blog/raycast-notes · https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast · https://www.macstories.net/reviews/raycast-overhauls-its-notes-feature/

## Decisions

1. **Storage: folder of `.md` files** (Davis, 2026-10-25). Plain Markdown on disk, not a database; the files are the source of truth. Notes folder location should be user-pickable (exact default is an implementation choice, e.g. `~/Notes`). External edits to the files should be reflected, not overwritten.
2. **Editor: hybrid live-preview** (Davis, 2026-10-25). Obsidian-style: Markdown renders in place, syntax reveals on the cursor line/block. The file underneath stays plain `.md`. Not raw-always-visible, not full WYSIWYG.
3. **Vim: core modal, opt-in, opens in Normal** (Davis, 2026-10-25). Off by default; normal Mac editing is the default experience. When enabled: Normal/Insert/Visual, motions, operators, `.` repeat, counts, `/` search, block cursor in Normal — and notes open in **Normal** mode (not Insert). No ex commands, macros, or custom remaps in v1.
4. **Images: single `assets/` folder in the notes folder** (Davis, 2026-10-25). Pasted/dropped images are saved there and referenced with relative Markdown links (`![](assets/…)`), rendered inline in the editor. Orphaned images after note deletion are acceptable for now — no cleanup/GC in v1.
5. **Copy note: `⌘⇧C` copies the full note, multi-format** (Davis, 2026-10-25). One keybind puts every representation on the clipboard at once: plain text = Markdown with images inlined as base64 data URIs (self-contained), plus rich HTML with embedded images. Normal `⌘C` copies the current selection only. Verify against Davis's real paste targets during the build (primary target not yet named — multi-format is the hedge).
6. **Invocation: toggle + new-note + menu bar, triggerable from Raycast** (Davis, 2026-10-25). Customizable global hotkeys for toggle (reopen last note) and new-note quick capture, plus a menu-bar icon. Must be summonable from Raycast so Davis's existing Hyper+`\` binding toggles this app instead of Raycast Notes, via deeplinks: app registers a URL scheme (e.g. `toggle`, `new` actions) bindable in a Raycast Quicklink or Script Command. Ship the Raycast-side setup (quicklink/script snippet + one-line instruction) with the app. When toggled on, the window floats and stays open like Raycast Notes (decision 7).
7. **Window: single floating panel, Raycast-faithful** (Davis, 2026-10-25). One window / one note at a time, always on top, follows across Spaces, stays visible when unfocused, hides on toggle/Esc. Remembers position/size, auto-grows vertically to a cap then scrolls (since 2026-10-29: fixed 300×700 default, freely resizable, the editor scrolls inside). Settings toggle "hide from screen capture" exists and starts **off**. Pop-out multi-window stickies are out for v1.
8. **Organization: flat, search is the organization** (Davis, 2026-10-25). No folders/tags UI. Flat `.md` folder, list/search sorted with strong recency ranking, pins as in Raycast. Filenames: stable date-based names (confirmed fine); a note's first line is its displayed title. **Hard quality bar: search must be excellent** — fuzzy, ranked with recency context, and semantic enough that a vague lookup still finds the right note (local vectorizing or equivalent; depth settled in decision 9).
9. **Search: hybrid from day one, fully local** (Davis, 2026-10-25). Fuzzy title + full-text (BM25-style) + recency/frecency boosts blended with local semantic/vector results in one ranked list, with match context. A small embedding model is bundled with the app and runs entirely on-device (powerful Macs assumed; no embedding API, no account). The search/vector index is derived and rebuildable; `.md` files remain the source of truth. Concrete model/index tech is an implementation choice under the stack decision.
10. **Markdown: Raycast parity + images** (Davis, 2026-10-25). H1–H3, bold/italic/strikethrough, inline code, links, inline images, bullet/ordered/task lists (clickable checkboxes), fenced code blocks with per-language syntax highlighting, blockquotes, horizontal rules. Typed-Markdown formatting plus standard format shortcuts; no toolbar or slash menu in v1. Tables/highlight/footnotes/math/wikilinks are out for v1.
11. **Stack: native Swift/AppKit shell + WKWebView editor** (Davis, 2026-10-25). Swift/AppKit owns the floating panel, menu bar, global hotkeys, multi-format pasteboard, Raycast deeplinks/URL scheme, file watching, and the local search/vector index (SQLite + bundled CoreML-class embedding model as the proposed implementation). TypeScript + CodeMirror 6 (with its vim layer) inside WKWebView owns the hybrid live-preview editor and search UI. Not Tauri, not Electron, not pure-native TextKit.

## Confirmed defaults (Davis, 2026-10-25)

- Vim enabled → notes open in **Normal** mode.
- "Hide from screen capture" is a settings toggle, starting **off**.
- Stable date-based filenames are fine; first line = displayed title.
- Deeplink integration with Raycast: yes (see decision 6).
- `⌘C` copies selection; `⌘⇧C` copies the whole note.

## Build-time implementation choices (builders decide; must not widen scope)

- Concrete bundled embedding model + vector index (constraints: bundled, fully on-device, small, fast on Apple Silicon).
- Exact default notes folder and filename pattern (date-based, collision-safe).
- Where the derived search index lives (recommended: Application Support, so the notes folder stays clean and portable). It must be deletable/rebuildable from the `.md` files alone.
- Default global hotkey values, if any (must not clash with Raycast; Davis's real trigger is Hyper+`\` via Raycast).
- `⌘⇧C` must be verified against Davis's real paste targets during the build; ask him for the top targets early.
- Esc mapping, derived rule (confirm in daily use): vim on → Esc in Insert goes to Normal, Esc in Normal hides the panel. Vim off → Esc hides the panel.

## Data layout

```text
<notes folder>/
  2026-10-25-2130-xxxx.md
  2026-10-25-2145-yyyy.md
  assets/
    pasted-20261025-2130-zzzz.png
```

App state that is not note content (pins, frecency, settings, search index) lives outside the note files. Editing any `.md` with another editor must be picked up cleanly (file watching); autosave as the user types (debounced), no save button, no proprietary fields injected into the Markdown.

## V1 build checklist (derived from the decisions above; observable behavior)

Capture & window:

- [ ] Toggle hotkey / Raycast Hyper+`\` deeplink shows the floating panel with the last note, cursor where it was left; toggling again hides it
- [ ] New-note hotkey / deeplink / menu-bar action opens a fresh blank note, ready to type (in Normal first if vim is on)
- [ ] Panel floats above other apps and across Spaces, stays visible when unfocused, remembers position/size (300×700 default, resizable), editor scrolls
- [ ] Menu-bar icon present; app has no Dock presence requirement beyond what builders choose for a panel utility
- [ ] Settings: notes folder picker, toggle/new hotkey recorders, vim on/off, hide-from-screen-capture on/off (starts off)

Writing:

- [ ] Hybrid live-preview for the full decision-10 Markdown set, rendering inline images from `assets/`
- [ ] `⌘V` with an image on the clipboard saves it into `assets/`, inserts a relative Markdown link, renders it inline; drag-drop of an image file does the same
- [ ] Task list checkboxes toggle by click and persist as `- [x]`
- [ ] Vim (when enabled): Normal/Insert/Visual, motions, operators, `.`, counts, `/` search; opens in Normal; disabling vim restores plain Mac editing
- [ ] Notes autosave to their `.md` file as you type; external edits appear without clobbering

Copy:

- [ ] `⌘⇧C` puts the entire note on the clipboard at once: Markdown-with-base64-images as text plus rendered HTML with embedded images
- [ ] `⌘C` copies just the selection as usual

Find:

- [ ] `⌘P` search: fuzzy title + full-text + semantic results merged into one ranked list with match context, recent/frequent notes boosted, pins on top
- [ ] A vague concept query (no shared words) finds the intended note
- [ ] Switch, pin/unpin, back/forward, delete (to Trash), and new note all work without leaving the panel

## Non-goals for v1

- Sync, accounts, cloud anything, sharing links, mobile, Windows/Linux
- AI writing/chat features (the only "AI" is the local search embedder)
- Tags, folders, graph/backlinks, wikilinks
- Tables, footnotes, math, highlight syntax
- Multi-window/pop-out sticky notes
- Orphaned-image cleanup
- Vim ex commands, macros, custom remaps/vimrc
- Toolbar / slash-menu formatting UI

## Risks

- Hybrid live-preview + vim interplay (cursor math on revealed/hidden syntax) is the main editor risk.
- Swift↔JS bridge adds surface for focus, paste, and performance bugs; keep it thin.
- Clipboard behavior varies by destination: some targets (e.g. GitHub) strip base64 data-URI images regardless of what we copy.
- Raycast Hyper-key triggering via deeplink must toggle focus reliably and instantly, or the core workflow feels broken.
- Embedding quality on short, vague notes varies by model; keyword/frecency ranking must be strong on its own.
- External edits/renames of `.md` files while a note is open need a sane conflict behavior.

## Validation sketch for the eventual build

- Actually use it daily-driver style: capture via Hyper+`\`, paste a screenshot inline, write with vim on and off.
- `⌘⇧C`, then paste into each real target (LLM chat, GitHub, docs) and check text + images.
- Search with vague/concept queries that share no words with the target note, plus exact-name/code queries.
- Edit a note's `.md` in another editor and confirm the app picks it up cleanly.

## Scope contract

- **The interview's deliverable was this document only** (`SPEC.md`), committed on helm. It is now Final (accepted 2026-10-25; see Status).
- **Implementation is the next, separate stage:** Davis is transferring this project to servitor and will run the build there (agent swarm/council, organized by Davis). Builders treat the Decisions + Non-goals above as the contract and the Build-time choices as the only open implementation freedom.
- Builders must not silently widen v1 beyond the decisions/non-goals recorded here. Anything extra goes back to Davis first.
- Provenance: authored on helm (this machine) in a T3 Code thread, "raycast-notes-but-mine", 2026-10-25.
