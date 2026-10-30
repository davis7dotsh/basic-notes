import { ensureSyntaxTree, language, syntaxTree } from '@codemirror/language'
import { EditorSelection, StateCommand, Text, Transaction } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import './styles.css'
import { installWebAPI, send } from './bridge/client'
import type { FromSwift, NoteId, NotePayload, Settings, ViewState } from './bridge/protocol'
import { renderHTML } from './copy'
import { insertLink, toggleEmphasis, toggleHeading, toggleInline, toggleList } from './editor/commands'
import { cancelPaste, completePaste, guardWindowDrops, insertBlock, insertInline, newDropSession, reservePaste } from './editor/dnd'
import { createEditor, createState, External, isVimOn, setVim } from './editor/editor'
import { collectImages } from './editor/imageNodes'
import { bumpAssets, images, refreshImages, setImageFolder } from './editor/images'
import { clusterStart, normalCaret } from './editor/unicode'
import { locatePassage, revealPassage } from './editor/searchPassage'
import { clearVimSearch, enterNormal, noteCopiedToClipboard, setVimClipboard, vimWantsEscape } from './editor/vimMode'
import { createSearch } from './search/overlay'
import { type Action, createActions } from './ui/actions'
import { setUnsaved, toast } from './ui/toast'

const SAVE_DEBOUNCE = 300
const VIEWSTATE_DEBOUNCE = 400

const app = document.getElementById('app')!
const host = document.createElement('div')
host.className = 'editor-host'
app.appendChild(host)

type Session = {
  headingVisible?: boolean
  id: NoteId
  isNew: boolean
  /** Content known to be on disk. */
  saved: string
  /** Local edits not yet acknowledged by Swift. */
  dirty: boolean
  version: number
  pinned: boolean
  pinIndex: number | null
  /** A trash request is in flight: no saves (they'd resurrect the file). */
  deleting: boolean
  deleted: boolean
  /** The last save attempt failed; retrying. */
  failed: boolean
  /** Swift couldn't put this text into the notes folder (a re-save into a restored folder failed; Swift retries it). */
  notInFolder: boolean
  inflight: { content: string; done: Promise<void> } | null
  /** NotePayload.folder of the folder this note lives in. */
  folder: string
}

let session: Session | null = null
let nav = { canGoBack: false, canGoForward: false }
let saveTimer: ReturnType<typeof setTimeout> | undefined
let viewTimer: ReturnType<typeof setTimeout> | undefined
/** Saves run strictly in order; this never rejects. */
let saveQueue: Promise<unknown> = Promise.resolve()
let lastViewState = ''
let pendingNewText: string | null = null
/** Content of notes we navigated away from whose last save failed. Retried, and restored if reopened. */
const orphans = new Map<NoteId, string>()

const log = (level: 'debug' | 'info' | 'warn' | 'error', message: string) => void send({ type: 'log', level, message }).catch(() => {})

// The label fades only while the leading rendered heading is on screen. Measure the
// block, including wrapped rows, in the same layout pass as CodeMirror's viewport.
const headingMeasure = {
  read(editor: EditorView) {
    if (!session || search.isOpen() || menu.isOpen()) return false
    const heading = syntaxTree(editor.state).topNode.firstChild
    if (!heading || !/^(ATX|Setext)Heading[1-6]$/.test(heading.name)) return false
    const viewport = editor.scrollDOM.getBoundingClientRect()
    const top = editor.documentTop
    return top + editor.lineBlockAt(heading.from).top < viewport.bottom
      && top + editor.lineBlockAt(heading.to).bottom > viewport.top
  },
  write(visible: boolean) {
    if (!session || visible === session.headingVisible) return
    session.headingVisible = visible
    void send({ type: 'headingVisible', id: session.id, visible })
  },
}
const view = createEditor(host, {
  layoutChanged: editor => editor.requestMeasure(headingMeasure),
  docChanged(external) {
    if (external || !session || session.deleted) return
    session.dirty = true
    session.version++
    scheduleSave()
  },
  viewChanged() {
    clearTimeout(viewTimer)
    viewTimer = setTimeout(sendViewState, VIEWSTATE_DEBOUNCE)
  },
})
guardWindowDrops()

// Top fade while scrolled (class flips on change only).
let scrolled = false
const syncScrolled = () => {
  view.requestMeasure(headingMeasure)
  const on = view.scrollDOM.scrollTop > 0
  if (on === scrolled) return
  scrolled = on
  host.classList.toggle('scrolled', on)
}
view.scrollDOM.addEventListener('scroll', syncScrolled, { passive: true })

// ---------- autosave ----------
function scheduleSave() {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(() => void save().catch(() => {}), SAVE_DEBOUNCE)
}

/** Send the current note if it has unsaved edits. Rejects if that write fails (the buffer stays dirty). */
function save(): Promise<void> {
  clearTimeout(saveTimer)
  saveTimer = undefined
  const s = session
  if (!s || s.deleted || s.deleting || !s.dirty) return Promise.resolve()
  const content = view.state.doc.toString()
  if (content === s.saved) {
    s.dirty = false
    if (s.failed) {
      s.failed = false
      saveStatusChanged()
    }
    return Promise.resolve()
  }
  // A brand-new note isn't created on disk until it has content.
  if (s.isNew && content.trim() === '') return Promise.resolve()
  if (s.inflight?.content === content) return s.inflight.done
  const version = s.version
  const done: Promise<void> = saveQueue
    .then(() => send({ type: 'save', id: s.id, content }))
    .then(
      () => {
        if (s.inflight?.done === done) s.inflight = null
        s.saved = content
        s.isNew = false
        s.failed = false
        s.notInFolder = false
        if (s.version === version) s.dirty = false
        if (s !== session && orphans.get(s.id) === content) orphans.delete(s.id)
        saveStatusChanged()
      },
      (err: unknown) => {
        if (s.inflight?.done === done) s.inflight = null
        // Swift rejects saves for a note from before a folder switch: its content was already carried. Terminal.
        if (isStale(err)) {
          s.dirty = false
          s.failed = false
          orphans.delete(s.id)
          saveStatusChanged()
          return
        }
        log('error', `save failed: ${String(err)}`)
        if (s === session) s.failed = true
        // Navigated away meanwhile: keep this content so it can still reach disk.
        else if (!s.deleted) orphans.set(s.id, content)
        saveStatusChanged()
        throw err instanceof Error ? err : new Error(String(err))
      },
    )
  s.inflight = { content, done }
  saveQueue = done.catch(() => {})
  return done
}

const isStale = (err: unknown) => String(err instanceof Error ? err.message : err).includes('stale:')

function saveOrphans() {
  return Promise.all(
    [...orphans].map(([id, content]) =>
      saveQueue
        .then(() => send({ type: 'save', id, content }))
        .then(
          () => {
            if (orphans.get(id) === content) orphans.delete(id)
          },
          (err: unknown) => {
            if (!isStale(err)) throw err
            orphans.delete(id)
          },
        ),
    ),
  ).finally(saveStatusChanged)
}

// Failed saves retry with backoff (and on the next edit) until they land; a quiet "Not saved" shows meanwhile.
const RETRY_MS = [1000, 2000, 5000, 10000]
let retryAttempt = 0
let retryTimer: ReturnType<typeof setTimeout> | undefined

function saveStatusChanged() {
  const failing = Boolean(session?.failed) || orphans.size > 0
  setUnsaved(failing || Boolean(session?.notInFolder))
  if (!failing) {
    retryAttempt = 0
    clearTimeout(retryTimer)
    retryTimer = undefined
  } else if (retryTimer === undefined) {
    retryTimer = setTimeout(retry, RETRY_MS[Math.min(retryAttempt++, RETRY_MS.length - 1)])
  }
}

function retry() {
  retryTimer = undefined
  if (session?.failed) session.dirty = true
  void Promise.allSettled([save(), saveOrphans()]).then(saveStatusChanged)
}

function sendViewState() {
  clearTimeout(viewTimer)
  const s = session
  if (!s || s.deleted || (s.isNew && view.state.doc.length === 0)) return
  const { anchor, head } = view.state.selection.main
  const viewState: ViewState = { anchor, head, scrollTop: Math.round(view.scrollDOM.scrollTop) }
  const key = `${s.id}:${anchor}:${head}:${viewState.scrollTop}`
  if (key === lastViewState) return
  lastViewState = key
  void send({ type: 'viewState', id: s.id, viewState })
}

/** Swift awaits this before hide/switch/quit. Rejects if anything couldn't be written. */
async function flush() {
  sendViewState()
  const results = await Promise.allSettled([save(), saveOrphans()])
  const failed = results.find((r) => r.status === 'rejected')
  if (failed) throw failed.reason
}

// ---------- notes ----------
function finishLoad() {
  view.requestMeasure(headingMeasure)
  if (!search.consumeExpectedLoad()) search.close(false)
  menu.close(false)
  if (search.isOpen()) search.refresh()
  else view.focus()
}

function loadNote(note: NotePayload) {
  const folder = note.folder ?? ''
  // Re-sent for the note that's already open (e.g. panel re-shown): keep the live editor state — undo
  // history, cursor, and above all any edits Swift hasn't seen yet. (The same id in another folder is another note.)
  if (session && !session.deleted && session.id === note.id && session.folder === folder) {
    session.pinned = note.pinned
    session.pinIndex = note.pinIndex
    nav = { canGoBack: note.canGoBack, canGoForward: note.canGoForward }
    if (note.content !== view.state.doc.toString() && !session.dirty && saveTimer === undefined) applyExternal(note.id, note.content)
    enterNormal(view)
    applyPendingSeed()
    const match = locatePassage(view.state.doc, note.content, note.passage)
    if (match) revealPassage(view, match)
    finishLoad()
    return
  }
  if (session && !session.deleted) {
    sendViewState()
    // A failing save that's still failing when we leave becomes an orphan (kept + retried).
    if (session.dirty) void save().catch(() => {})
  }
  clearTimeout(saveTimer)
  saveTimer = undefined
  newDropSession()

  let content = note.content
  let seeded = false
  if (pendingNewText !== null && note.isNew && content === '') {
    content = pendingNewText ? `${pendingNewText}\n` : ''
    seeded = content !== ''
  }
  pendingNewText = null
  // Edits that never reached disk win over the stale file.
  const orphan = orphans.get(note.id)
  if (orphan !== undefined) {
    orphans.delete(note.id)
    if (orphan !== content) {
      content = orphan
      seeded = true
    }
  }

  session = {
    id: note.id,
    isNew: note.isNew,
    saved: note.content,
    dirty: false,
    version: 0,
    pinned: note.pinned,
    pinIndex: note.pinIndex,
    deleting: false,
    deleted: false,
    failed: false,
    notInFolder: false,
    inflight: null,
    folder,
  }
  nav ={ canGoBack: note.canGoBack, canGoForward: note.canGoForward }
  lastViewState = ''

  const doc = Text.of(content.split(/\r\n?|\n/))
  const len = doc.length
  // (Offsets saved against an older version of the file can fall inside an emoji: whole characters only.)
  const clamp = (n: number) => clusterStart(doc, Math.max(0, Math.min(len, n)))
  const vs = seeded ? null : note.viewState
  // First open (no saved view state): caret at the end, so typing appends and the title's `#` stays hidden.
  // Vim never restores a Visual selection on re-entering a buffer: Normal gets a caret where the range ended.
  const selection = !vs ? EditorSelection.single(len) : isVimOn() ? normalCaret(doc, clamp(vs.anchor), clamp(vs.head)) : EditorSelection.single(clamp(vs.anchor), clamp(vs.head))
  setImageFolder(folder)
  view.setState(createState(content, selection))
  enterNormal(view)

  const match = locatePassage(view.state.doc, note.content, note.passage)
  if (match) {
    revealPassage(view, match)
  } else if (vs && vs.scrollTop > 0) {
    view.requestMeasure({
      read: () => null,
      write: () => {
        view.scrollDOM.scrollTop = vs.scrollTop
      },
    })
  } else if (!vs && len > 0) view.dispatch({ effects: EditorView.scrollIntoView(len, { y: 'nearest' }) })

  if (seeded && session) {
    session.dirty = true
    session.version++
    void save().catch(() => {})
  }
  saveStatusChanged()
  finishLoad()
}

function applySettings(settings: Settings) {
  setVim(view, settings.vimEnabled)
  document.documentElement.classList.toggle('vim', settings.vimEnabled)
}

function applyExternal(id: NoteId, content: string) {
  const s = session
  if (!s || s.id !== id || s.deleted) return !orphans.has(id)
  const current = view.state.doc.toString()
  if (content === current) {
    s.saved = content
    s.dirty = false
    return true
  }
  if (s.dirty || s.failed || saveTimer !== undefined) return false
  // Replace only the differing middle so the cursor/scroll stay put.
  let start = 0
  const max = Math.min(current.length, content.length)
  while (start < max && current.charCodeAt(start) === content.charCodeAt(start)) start++
  let endCur = current.length
  let endNew = content.length
  while (endCur > start && endNew > start && current.charCodeAt(endCur - 1) === content.charCodeAt(endNew - 1)) {
    endCur--
    endNew--
  }
  view.dispatch({
    changes: { from: start, to: endCur, insert: content.slice(start, endNew) },
    annotations: [External.of(true), Transaction.addToHistory.of(false)],
  })
  s.saved = content
  s.isNew = false
  return true
}

/** The open note is a brand-new one with nothing in it: Swift reuses it for "new note" instead of minting another. */
const onBlankNewNote = () => Boolean(session && session.isNew && !session.deleted && view.state.doc.toString().trim() === '')

/** Seed the blank new note with a search query: the query is the first line, the caret on the line below. */
function seedBlank(text: string) {
  if (!session) return
  const content = `${text}\n`
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: content },
    selection: { anchor: content.length },
    scrollIntoView: true,
    userEvent: 'input',
  })
  enterNormal(view)
  void save().catch(() => {})
}

/** A create-from-search is waiting and Swift kept us on the same blank note (it sent `focus` or the same id). */
function applyPendingSeed() {
  const text = pendingNewText
  pendingNewText = null
  if (text && onBlankNewNote()) seedBlank(text)
}

function newNote(withText: string | null = null) {
  // Already on a blank new note: Swift would keep it, so seed it right here.
  if (withText && onBlankNewNote()) {
    pendingNewText = null
    seedBlank(withText)
    view.focus()
    return
  }
  pendingNewText = withText
  void send({ type: 'newNote' })
}

async function togglePin(id: NoteId) {
  try {
    const r = await send<{ pinned: boolean; pinIndex: number | null }>({ type: 'togglePin', id })
    if (!r) return
    if (session && session.id === id) {
      session.pinned = r.pinned
      session.pinIndex = r.pinIndex
    }
    toast(r.pinned ? (r.pinIndex !== null && r.pinIndex <= 9 ? `Pinned · ⌘${(r.pinIndex + 1) % 10}` : 'Pinned') : 'Unpinned')
  } catch (err) {
    log('error', `togglePin failed: ${String(err)}`)
  }
}

/** Resolves true once the note is in the Trash. Nothing optimistic happens before Swift confirms. */
async function deleteNote(id: NoteId) {
  const s = session && session.id === id ? session : null
  if (s) {
    // The Trash must get what's on screen: land pending edits first (keystrokes during the save go too).
    try {
      for (let i = 0; i < 5 && s.dirty && !s.deleted && session === s; i++) await save()
    } catch (err) {
      log('error', `deleteNote: save before trash failed: ${String(err)}`)
      toast('Couldn’t move to Trash', 'error')
      return false
    }
    if (s.deleted) return false
    s.deleting = true
    clearTimeout(saveTimer)
    saveTimer = undefined
  }
  try {
    await send({ type: 'deleteNote', id })
    if (s) s.deleted = true
    orphans.delete(id)
    saveStatusChanged()
    toast('Moved to Trash')
    return true
  } catch (err) {
    log('error', `deleteNote failed: ${String(err)}`)
    if (s) {
      s.deleting = false
      if (s.dirty && session === s) scheduleSave()
    }
    toast('Couldn’t move to Trash', 'error')
    return false
  }
}

/** A complete parse of the current doc (the live tree may stop short of the end on long notes). */
function fullTree() {
  const { state } = view
  return ensureSyntaxTree(state, state.doc.length, 2000) ?? state.facet(language)?.parser.parse(state.doc.toString()) ?? null
}

async function copyNote() {
  if (!session) return
  const markdown = view.state.doc.toString()
  const tree = fullTree()
  const images = tree ? collectImages(view.state.doc, tree) : []
  try {
    noteCopiedToClipboard()
    await send({ type: 'copyNote', id: session.id, markdown, html: renderHTML(markdown), images })
    toast('Copied note')
  } catch (err) {
    log('error', `copyNote failed: ${String(err)}`)
    toast('Couldn’t copy note', 'error')
  }
}

const search = createSearch(app, {
  open: ({ id, passage }) => {
    if (session && id === session.id) {
      view.focus()
      const match = locatePassage(view.state.doc, session.saved, passage)
      if (match) revealPassage(view, match)
    } else void send({ type: 'open', id, passage })
  },
  create: (query) => newNote(query || null),
  remove: deleteNote,
  togglePin,
  closed: () => view.focus(),
  openChanged: (open) => {
    view.requestMeasure(headingMeasure)
    if (open) menu.close(false) // one overlay at a time (its `searchOpen: false` goes out first)
    void send({ type: 'searchOpen', open }).catch(() => {})
  },
})

// ---------- actions ----------
// Shortcuts, the ⌘K menu, and native header buttons all run these.
function startNewNote() {
  search.close(false)
  menu.close(false)
  newNote()
}
const goBack = () => {
  if (nav.canGoBack) void send({ type: 'back' })
}
const goForward = () => {
  if (nav.canGoForward) void send({ type: 'forward' })
}
const pinCurrent = () => {
  if (session) void togglePin(session.id)
}
const deleteCurrent = () => {
  if (session) void deleteNote(session.id)
}
const zoom = (step: 1 | -1 | 0) => void send({ type: 'zoom', step })
const hidePanel = () => void send({ type: 'hide' })
const openSettings = () => void send({ type: 'openSettings' })
const format = (cmd: StateCommand) => () => void cmd(view)

const menu = createActions(app, {
  actions() {
    const note: Action[] = session
      ? [
          { section: 'Note', title: 'Copy Note', keys: ['⌘', '⇧', 'C'], keywords: 'export clipboard', run: () => void copyNote() },
          { section: 'Note', title: session.pinned ? 'Unpin Note' : 'Pin Note', keys: ['⌘', '⇧', 'P'], run: pinCurrent },
          { section: 'Note', title: 'Delete Note', keys: ['⌘', '⇧', '⌫'], keywords: 'trash remove', run: deleteCurrent },
        ]
      : []
    const go: Action[] = [{ section: 'Go', title: 'Search Notes', keys: ['⌘', 'P'], keywords: 'find open', run: () => void search.open() }]
    if (nav.canGoBack) go.push({ section: 'Go', title: 'Back', keys: ['⌘', '['], run: goBack })
    if (nav.canGoForward) go.push({ section: 'Go', title: 'Forward', keys: ['⌘', ']'], run: goForward })
    const fmt = (title: string, keys: string[], cmd: StateCommand): Action => ({ section: 'Format', title, keys, run: format(cmd) })
    return [
      { section: 'Note', title: 'New Note', keys: ['⌘', 'N'], keywords: 'create', run: startNewNote },
      ...note,
      ...go,
      { section: 'App', title: 'Zoom In', keys: ['⌘', '+'], keywords: 'bigger larger text', run: () => zoom(1) },
      { section: 'App', title: 'Zoom Out', keys: ['⌘', '−'], keywords: 'smaller text', run: () => zoom(-1) },
      { section: 'App', title: 'Reset Zoom', keywords: 'actual size text', run: () => zoom(0) },
      { section: 'App', title: 'Settings', keys: ['⌘', ','], keywords: 'preferences', run: openSettings },
      { section: 'App', title: 'Hide', keys: ['⌘', 'W'], keywords: 'close', run: hidePanel },
      fmt('Insert Link', ['⌘', '⇧', 'K'], insertLink),
      fmt('Bold', ['⌘', 'B'], toggleEmphasis('bold')),
      fmt('Italic', ['⌘', 'I'], toggleEmphasis('italic')),
      fmt('Strikethrough', ['⌘', '⇧', 'X'], toggleInline('~~')),
      fmt('Code', ['⌘', 'E'], toggleInline('`')),
      fmt('Heading 1', ['⌘', '⌥', '1'], toggleHeading(1)),
      fmt('Heading 2', ['⌘', '⌥', '2'], toggleHeading(2)),
      fmt('Heading 3', ['⌘', '⌥', '3'], toggleHeading(3)),
      fmt('Bulleted List', ['⌘', '⇧', '8'], toggleList('bullet')),
      fmt('Numbered List', ['⌘', '⇧', '7'], toggleList('ordered')),
      fmt('Task List', ['⌘', '⇧', '9'], toggleList('task')),
    ]
  },
  closed: () => view.focus(),
  openChanged: (open) => {
    view.requestMeasure(headingMeasure)
    if (open) search.close(false)
    void send({ type: 'searchOpen', open }).catch(() => {})
  },
})

// ---------- keys ----------
function onKeyDown(e: KeyboardEvent) {
  if (e.isComposing) return
  if (e.key === 'Escape') {
    if (search.isOpen()) {
      search.close()
    } else if (menu.isOpen()) {
      menu.close()
    } else {
      const active = document.activeElement
      if (active instanceof Element && active.closest('.cm-panel, .cm-vim-panel')) return // vim `/` prompt
      if (isVimOn() && vimWantsEscape(view)) return
      // Stray extra ranges in Normal: Esc collapses them first instead of hiding.
      if (view.state.selection.ranges.length > 1) {
        view.dispatch({ selection: EditorSelection.create([view.state.selection.main]) })
        e.preventDefault()
        e.stopPropagation()
        return
      }
      if (isVimOn()) clearVimSearch(view)
      hidePanel()
    }
    e.preventDefault()
    e.stopPropagation()
    return
  }
  if (!e.metaKey || e.ctrlKey) return
  const run = shortcut(e)
  if (!run) return
  e.preventDefault()
  e.stopPropagation()
  // Any other app shortcut closes the ⌘K menu first, then runs as it would from the editor.
  if (run !== menu.toggle) menu.close()
  run()
}

/** The app-level ⌘ shortcut for this key, if any. */
function shortcut(e: KeyboardEvent) {
  const { shiftKey: shift, altKey: alt, code } = e
  const digit = /^Digit(\d)$/.exec(code)
  if (code === 'KeyK' && !shift && !alt) return menu.toggle
  if (code === 'KeyP' && !alt) {
    if (!shift) return search.toggle
    return search.isOpen() ? () => void search.togglePinSelected() : pinCurrent
  }
  if (code === 'KeyN' && !shift && !alt) return startNewNote
  if (code === 'BracketLeft' && !shift && !alt) return goBack
  if (code === 'BracketRight' && !shift && !alt) return goForward
  if (digit && !shift && !alt) {
    const n = Number(digit[1])
    return () => void send({ type: 'openPin', index: n === 0 ? 9 : n - 1 })
  }
  if (code === 'KeyC' && shift && !alt) return search.isOpen() ? () => {} : () => void copyNote()
  if (code === 'Backspace' && shift && !alt) return search.isOpen() ? () => void search.deleteSelected() : deleteCurrent
  if (code === 'Comma' && !shift && !alt) return openSettings
  // ⌘= / ⌘+ (either side of Shift), ⌘-; reset is menu-only (⌘0 is pin 10).
  if ((code === 'Equal' || code === 'NumpadAdd') && !alt) return () => zoom(1)
  if ((code === 'Minus' || code === 'NumpadSubtract') && !shift && !alt) return () => zoom(-1)
  if (code === 'KeyW' && !shift && !alt) return hidePanel
  return null
}
window.addEventListener('keydown', onKeyDown, true)

// Links show a pointer only while ⌘ is held (⌘-click opens them).
const setCmd = (on: boolean) => document.documentElement.classList.toggle('cmd-held', on)
window.addEventListener('keydown', (e) => setCmd(e.metaKey), true)
window.addEventListener('keyup', (e) => setCmd(e.metaKey), true)
window.addEventListener('blur', () => setCmd(false))

// ---------- bridge ----------
function receive(msg: FromSwift) {
  switch (msg.type) {
    case 'init':
    case 'settings':
      applySettings(msg.settings)
      break
    case 'loadNote':
      loadNote(msg.note)
      break
    case 'beginPaste':
      reservePaste(view, msg.token)
      break
    case 'cancelPaste':
      cancelPaste(msg.token)
      break
    case 'insertText': {
      if (msg.token !== undefined) {
        // A reserved paste: goes where it was invoked. A search opened meanwhile stays open (and focused).
        const inserted = completePaste(view, msg.token, msg.text, msg.block)
        // Native cleans up the files it wrote for a paste that didn't go in.
        void send({ type: 'pasteResult', token: msg.token, inserted }).catch(() => {})
        if (!inserted) {
          log('warn', 'paste: reservation gone (note changed) — not inserted')
          toast('Paste cancelled — the note changed')
        } else if (!search.isOpen() && !menu.isOpen()) view.focus()
        break
      }
      if (search.isOpen()) search.close(false)
      menu.close(false)
      const { from, to } = view.state.selection.main
      if (msg.block) insertBlock(view, from, msg.text, to)
      else insertInline(view, msg.text)
      view.focus()
      break
    }
    case 'openSearch':
      void search.open()
      break
    case 'pinState':
      if (session && session.id === msg.id) {
        session.pinned = msg.pinned
        session.pinIndex = msg.pinIndex
      }
      search.refresh()
      break
    case 'navState':
      nav = { canGoBack: msg.canGoBack, canGoForward: msg.canGoForward }
      break
    case 'focus':
      applyPendingSeed()
      if (search.isOpen()) search.focus()
      else if (menu.isOpen()) menu.focus()
      else view.focus()
      break
    case 'toast':
      toast(msg.message, msg.tone)
      break
    case 'systemClipboard':
      setVimClipboard(msg.text, msg.ownCopy === true)
      break
    case 'assetsChanged':
      bumpAssets(msg.paths)
      view.dispatch({ effects: refreshImages.of(null) })
      break
    case 'searchText':
      if (menu.isOpen()) menu.insertText(msg.text)
      else search.insertText(msg.text)
      break
    case 'runAction':
      if (msg.action === 'actions') menu.toggle()
      else if (msg.action === 'copyNote') void copyNote()
      else startNewNote()
      break
    case 'retarget':
      retarget(msg.from, msg.to)
      break
    case 'unsavedText':
      if (session?.id === msg.id && !session.deleted) {
        session.notInFolder = msg.unsaved
        saveStatusChanged()
      }
      break
  }
}

/** The open note was renamed on disk: same note, new id — nothing reloads, so keystrokes in flight and pending saves stay. */
function retarget(from: NoteId, to: NoteId) {
  const orphan = orphans.get(from)
  if (orphan !== undefined) {
    orphans.delete(from)
    orphans.set(to, orphan)
  }
  if (!session || session.deleted || session.id !== from) return
  session.id = to
  lastViewState = ''
}

/** Swift already carried the unsaved buffer elsewhere (folder switch): forget every pending write, save nothing. */
function discardPendingSaves() {
  clearTimeout(saveTimer)
  saveTimer = undefined
  clearTimeout(viewTimer)
  viewTimer = undefined
  clearTimeout(retryTimer)
  retryTimer = undefined
  retryAttempt = 0
  orphans.clear()
  pendingNewText = null
  if (session) {
    // Retire it: its id means nothing in the next folder, so it must never save (or report view state) again.
    session.dirty = false
    session.failed = false
    session.inflight = null
    session.deleted = true
  }
  saveStatusChanged()
}

installWebAPI({ receive, flush, applyExternal, discardPendingSaves })
void send({ type: 'ready' })

// Dev-only handle for scripted testing in the browser.
if (import.meta.env.DEV) Object.assign(window, { __nbmView: view, __nbmImages: images })
