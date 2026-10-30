// Swift <-> JS bridge contract. Mirror: App/Sources/Core/BridgeProtocol.swift
// Keep this thin. Every JS->Swift message goes through `window.webkit.messageHandlers.bridge.postMessage(msg)`
// (WKScriptMessageHandlerWithReply), which resolves with the reply value or rejects with an error string.
// Every Swift->JS message is delivered by calling `window.__nbm.receive(msg)`.

/** Stable note id = filename stem, e.g. "2026-10-25-2130-a1b2" (file is `<id>.md` in the notes folder). */
export type NoteId = string

export type ViewState = {
  /** CodeMirror selection anchor/head as document offsets. */
  anchor: number
  head: number
  scrollTop: number
}

export type NotePayload = {
  id: NoteId
  content: string
  pinned: boolean
  /** Index in the pin list (0-based) if pinned, used for ⌘1…⌘9 hints. */
  pinIndex: number | null
  /** true = brand-new blank note (not on disk yet until it has content). */
  isNew: boolean
  /** Restored cursor/scroll; null => start of doc (or end for isNew). */
  viewState: ViewState | null
  canGoBack: boolean
  canGoForward: boolean
  /** Opaque key of the notes folder this note lives in (absent = unknown/mock). Relative image URLs and image caches
   *  are namespaced by it (the same `assets/x.png` is a different file in another folder), and a same-id load from a
   *  different folder is a different note. */
  folder?: string
}

export type Settings = {
  vimEnabled: boolean
}

export type SearchHit = {
  id: NoteId
  title: string
  /** One-line match context (or first body line when no query). */
  snippet: string
  /** [start, end) UTF-16 ranges into `snippet` to highlight. */
  snippetHighlights: [number, number][]
  /** [start, end) UTF-16 ranges into `title` to highlight. */
  titleHighlights: [number, number][]
  /** ms since epoch */
  modified: number
  pinned: boolean
  pinIndex: number | null
  /** Why this hit matched; for subtle UI hints/debugging. */
  matchKind: 'recent' | 'title' | 'text' | 'semantic'
  score: number
}

/** A real Markdown image node found by the Lezer parser (never inside code, never escaped). */
export type ImageRef = {
  /** [from, to) UTF-16 offsets into `markdown` of the image DESTINATION text only (inside the parens / angle brackets). */
  from: number
  to: number
  /** Unescaped destination, e.g. "assets/r2-(literal).png". Swift replaces markdown[from,to) with a data URI when it resolves to a local file. */
  src: string
  /** UTF-16 offset of the image's first use in `markdown` (for `![x][ref]`, the first image using that definition, while
   *  from/to are the definition's destination). Orders the attached image items. Absent = `from`. */
  at?: number
}

// ---------- JS -> Swift ----------
export type ToSwift =
  | { type: 'ready' }
  /** Debounced autosave (~300ms) and on flush. Reply: { ok: true }. REJECTS (promise error) when the write fails —
   *  JS must keep the buffer dirty, show a persistent "not saved" state, retry with backoff, and make flush() reject. */
  | { type: 'save'; id: NoteId; content: string }
  /** Fire-and-forget; remember cursor/scroll per note. */
  | { type: 'viewState'; id: NoteId; viewState: ViewState }
  /** Save an image (drag-drop, or a JS-side paste). Reply: { path: "assets/pasted-....png" } */
  | { type: 'saveImage'; base64: string; mime: string; filename: string | null }
  /** Reply: SearchHit[] (empty query => recents with pins on top). */
  | { type: 'search'; query: string }
  | { type: 'open'; id: NoteId }
  | { type: 'newNote' }
  /** Moves the note's file to the macOS Trash. Swift then loads another note. Reply { ok: true }; REJECTS if trashing failed (show nothing optimistic before the reply). */
  | { type: 'deleteNote'; id: NoteId }
  /** Reply: { pinned: boolean, pinIndex: number | null } */
  | { type: 'togglePin'; id: NoteId }
  /** ⌘1…⌘9 => index 0…8 */
  | { type: 'openPin'; index: number }
  | { type: 'back' }
  | { type: 'forward' }
  /** ⌘⇧C. `html` is rendered from markdown with image src left as relative `assets/...`; Swift inlines everything. Reply: { ok: true } */
  | { type: 'copyNote'; id: NoteId; markdown: string; html: string; images: ImageRef[] }
  | { type: 'hide' }
  /** An overlay with a text input (⌘P search or ⌘K action menu; one at a time) opened/closed. While open, a native ⌘V
   *  never touches the note: plain text pastes into the overlay's input as usual, our own ⌘⇧C copy arrives as `searchText` (its first readable line), images/files are ignored. */
  | { type: 'searchOpen'; open: boolean }
  /** Answer to every `insertText` with a `token`: whether the reserved paste went in. false (its reservation was dropped by
   *  a note load in between) → Swift removes the files it wrote for that paste. Fire-and-forget. */
  | { type: 'pasteResult'; token: string; inserted: boolean }
  /** Vim `p`/`P` (Normal or Visual, unnamed or `"+`/`"*`) of our own ⌘⇧C copy (`text` = the Markdown `systemClipboard` handed over with `ownCopy`): paste it like ⌘V —
   *  images written into this folder first — into the paste the editor already reserved under `token` (no `beginPaste`).
   *  Answered with a tokened `insertText` (or `cancelPaste`); if the pasteboard no longer holds that copy, `text` as is. */
  | { type: 'pasteOwnCopy'; token: string; text: string }
  /** Vim yank/delete/Visual `p` → system clipboard (the unnamed register and `"+`/`"*` mirror NSPasteboard; vim never touches navigator.clipboard).
   *  `replaced`: the text a Visual put of the unnamed/`"+` register replaced — written only if the pasteboard is still what the
   *  editor last heard of (a put by a stale mirror must not clobber a newer copy). */
  | { type: 'setClipboard'; text: string; replaced?: boolean }
  | { type: 'openURL'; url: string }
  | { type: 'openSettings' }
  /** ⌘= / ⌘- / reset (action menu): text zoom step. Swift applies it to the web view and remembers it. */
  | { type: 'zoom'; step: 1 | -1 | 0 }
  | { type: 'log'; level: 'debug' | 'info' | 'warn' | 'error'; message: string }

// ---------- Swift -> JS ----------
export type FromSwift =
  | { type: 'init'; settings: Settings }
  /** Show this note in the editor and focus it (vim: Normal mode). */
  | { type: 'loadNote'; note: NotePayload }
  /** Insert text from a native paste. block=true (images): own line(s) after replacing the selection. block=false (text, file paths): replace the selection inline like a normal paste.
   *  With `token` (a paste reserved by `beginPaste`): insert where that paste was invoked, not at the live selection — see `beginPaste`. */
  | { type: 'insertText'; text: string; block: boolean; token?: string }
  /** A native paste whose text arrives later (our own copy: its images are written first). Sent synchronously at ⌘V, so it's
   *  ordered before any later keystroke. Record the current selection under `token` and map it through every edit in this
   *  note session. On `insertText` with the token: if the recorded range still holds the text it held, replace it; otherwise
   *  (typed over, deleted, edited inside) replace nothing and insert at its mapped start — so text typed at the caret meanwhile
   *  ends up after the paste. The caret moves to after the pasted text only if it hasn't moved since; an open search overlay
   *  stays open (the note behind it gets the text, the overlay keeps focus). In the undo history the paste is its own step
   *  where it was invoked: edits made while it was pending are undone before it. A note switch drops the reservation (an
   *  `insertText` for an unknown token inserts nothing). Every tokened `insertText` is answered with `pasteResult`. */
  | { type: 'beginPaste'; token: string }
  /** The reserved paste failed or was cancelled: forget `token`. */
  | { type: 'cancelPaste'; token: string }
  | { type: 'settings'; settings: Settings }
  | { type: 'openSearch' }
  | { type: 'pinState'; id: NoteId; pinned: boolean; pinIndex: number | null }
  | { type: 'navState'; canGoBack: boolean; canGoForward: boolean }
  /** Panel was shown again (toggle). Focus the editor. */
  | { type: 'focus' }
  /** Native-originated notice (conflict copy kept, save error, folder missing…). Show with the existing toast UI. */
  | { type: 'toast'; message: string; tone: 'info' | 'error' }
  /** System pasteboard text changed (sent when the pasteboard changeCount moved — checked when the panel becomes key, before each key press to it, and once a second while it stays key — on vim toggle /
   *  page load, and right after ⌘⇧C). Vim's unnamed register should pick it up for `p`. For our own ⌘⇧C copy it's the
   *  note's original Markdown (relative image paths), never the self-contained export; `ownCopy` when it has images
   *  (vim's `p` then goes through `pasteOwnCopy`, so they come along into another folder). */
  | { type: 'systemClipboard'; text: string; ownCopy?: boolean }
  /** Image files in the current notes folder changed on disk — created, replaced, deleted, renamed — by
   *  someone other than the app: paths relative to the folder, e.g. "assets/shot.png" (a directory path covers
   *  everything under it). Images showing them must reload (cache-busting URL) or turn into the missing-image chip. */
  | { type: 'assetsChanged'; paths: string[] }
  /** Native paste while an overlay is open (`searchOpen`): insert `text` into its input (replacing its selection). */
  | { type: 'searchText'; text: string }
  /** The open note's text isn't in the notes folder (`unsaved`: Swift's re-save into a restored folder failed — it retries)
   *  or now is: show (or clear) "Not saved", as for a failed save. Doesn't make the buffer dirty. */
  | { type: 'unsavedText'; id: NoteId; unsaved: boolean }
  /** A note's file was renamed elsewhere (Finder, another app): it's the same note under id `to` now. If the open
   *  session is `from`, switch its id in place — doc, undo history, selection and pending/queued saves stay (saves not
   *  yet sent go out as `to`; Swift redirects any already sent for `from`). Unsaved text kept for `from` moves to `to`. */
  | { type: 'retarget'; from: NoteId; to: NoteId }
  /** A native header button was clicked: open the ⌘K action menu, copy the note (⌘⇧C), or start a new note (⌘N). */
  | { type: 'runAction'; action: 'actions' | 'copyNote' | 'newNote' }

/** Exposed on window.__nbm by the web app. */
export type WebAPI = {
  receive(msg: FromSwift): void
  /** Swift awaits this before hide/switch/quit: send any pending save, resolve when done. REJECTS if the save failed (Swift then must not discard the buffer). */
  flush(): Promise<void>
  /**
   * The open note's file changed on disk (external editor). If the editor has no unsaved local edits,
   * replace the content (keep cursor/scroll as close as possible, as one transaction) and return true.
   * If it has unsaved edits, change nothing and return false — Swift then preserves the disk version
   * as a separate conflict note and the editor's version wins.
   */
  applyExternal(id: NoteId, content: string): boolean
  /**
   * Swift has already carried any unsaved buffer elsewhere (e.g. into a new note in a different folder):
   * drop every dirty session, stash, and pending retry WITHOUT saving. Called right before the store is swapped.
   */
  discardPendingSaves(): void
}
