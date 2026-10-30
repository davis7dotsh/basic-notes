import { undoDepth } from '@codemirror/commands'
import { ChangeSet, Compartment, EditorSelection, EditorState, Extension, SelectionRange, Text, Transaction } from '@codemirror/state'
import { EditorView, ViewPlugin, ViewUpdate } from '@codemirror/view'
import { getIndentUnit, indentString } from '@codemirror/language'
import { CodeMirror, Vim, getCM, vim } from '@replit/codemirror-vim'
import { send } from '../bridge/client'
import { listCursorSnap, openLine } from './commands'
import { cancelPaste, type Placement, reservePaste } from './dnd'
import { mergeSince } from './historyEdit'
import { charEnd, charEndIn, charsOf, charStartIn, cursorCol, displayCol, lastCharOffset, offsetAtCol, onCharacter } from './unicode'

// Opt-in modal editing. Lives in a compartment so it can be toggled live; with it off, the editor is
// plain Mac editing (vim's plugin is fully removed).

export const vimCompartment = new Compartment()

/**
 * Outside insert mode, typed text never reaches the document. Vim swallows every printable key it handles; this
 * is the backstop for when it doesn't — a command that throws leaves its keydown unhandled, and WebKit would
 * then insert the key as text (`gg V G` replacing the line with "G"). IME composition is left to vim.
 */
const normalModeGuard = EditorView.inputHandler.of((view) => {
  const s = vimState(view)
  return Boolean(s && !s.insertMode && !view.composing)
})

// Visual-block (⌃V) and its `I`/`A`/`c` are built from one range per line; without multiple selections CodeMirror keeps
// only the main one and the block edits the wrong text.
export const vimExtension = (on: boolean): Extension =>
  on
    ? // Multiple ranges exist only for visual-block; ⌘-click must not add Sublime-style cursors.
      [vim(), EditorState.allowMultipleSelections.of(true), EditorView.clickAddsSelectionRange.of(() => false), normalModeGuard, modeIndicator, copyToRegister]
    : [listCursorSnap]

type ModeEvent = { mode: string; subMode?: string }
type Pos = InstanceType<typeof CodeMirror.Pos>

// ---- `o` / `O` continue lists and quotes ----
// On a list item or quote line, open the line with the marker Return would give (`- `, `- [ ] `, the next number with
// the rest renumbered, `> `) and insert after it; elsewhere vim's own open-line. Same flags as vim's mapping, so
// counts, `.` and undo behave the same.
type ActionFn = Parameters<typeof Vim.defineAction>[1]
type VimRegister = ReturnType<typeof registers.getRegister>
type VimActions = {
  newLineAndEnterInsertMode: ActionFn
  enterInsertMode: ActionFn
  paste: ActionFn
  joinLines: ActionFn
  continuePaste(...args: [...Parameters<ActionFn>, text: string, register: VimRegister]): void
}
Vim.defineAction('nbmOpenLine', function (this: VimActions, cm, actionArgs, vim) {
  const view = cm.cm6
  // The opened line belongs to the insert session that follows (one undo step, like Vim).
  if (view) beginInsertSession(cm, view)
  const spec = view ? openLine(view.state, Boolean(actionArgs.after)) : null
  if (!view || !spec) return this.newLineAndEnterInsertMode(cm, actionArgs, vim)
  vim.insertMode = true
  view.dispatch(view.state.update(spec, { scrollIntoView: true, userEvent: 'input' }))
  this.enterInsertMode(cm, { repeat: actionArgs.repeat }, vim)
})
for (const [keys, after] of [['o', true], ['O', false]] as const) {
  Vim.mapCommand(keys, 'action', 'nbmOpenLine', { after }, { isEdit: true, interlaceInsertRepeat: true, context: 'normal' })
}

// ---- one undo step per insert session ----
// Vim undoes an insert session (`o…<Esc>`, `3o…<Esc>`, `i…<Esc>`) as one change. CodeMirror's history splits it: the
// opened line is its own step, and a pause or a cursor move inside it starts another. Remember the document where the
// session began; on the way back to Normal, fold everything since into one step.
/** (`depth`: the undo history's then — a session that ends where it began, `oX⌫⌫Z⌃U`, still folds into one step.) */
type Start = { doc: Text; depth: number }
const startOf = (state: EditorState): Start => ({ doc: state.doc, depth: undoDepth(state) })
const sessionStart = new WeakMap<object, Start>()
// The document before the key being handled: a change operator (`cw`, `cc`, `C`, `s`, Visual `c`) deletes its range
// before it enters Insert, so the session starts before that key, not at the mode change.
const keyStart = new WeakMap<object, Start>()
// A block `I`/`A` session: the block's top-left, where Vim leaves the cursor at its end. `pad` (a block's `A`): the column
// its text goes in at, which Vim pads shorter lines out to.
const blockOrigin = new WeakMap<object, { line: number; ch: number; pad?: number; toEnd: boolean }>()
/** Insert-mode keys that move the cursor: after one, Vim's `.` repeats only what was typed since, as a plain insert. */
const insertMotion = /^<(?:[SCMA]-)*(?:Left|Right|Up|Down|Home|End|PageUp|PageDown)>$/
/** The last edit (`edit`, vim's record of it) is a block `I`/`A`: `.` repeats it from the cursor's column (for `A`,
 *  `append` columns right of it — the block's width; `toEnd`: a `$` block's `A`, at the end of every line). */
let blockRepeat: { edit: unknown; append: number; toEnd: boolean } | null = null
/** A multi-caret insert (block `I`/`A`/`c`): where each caret started inserting, mapped through the edits since — and
 *  where its inserted text ends. */
const insertStarts = new WeakMap<object, number[]>()
const insertEnds = new WeakMap<object, number[]>()
/** A block insert gone on as a one-caret insert (see `deferBlock`): its first line (`line`, that line's start), the column
 *  its insert began at there, that line's length without what was inserted, and where the other lines get the text.
 *  `origin`: a block `I`/`A`'s left column (`toEnd`: a `$` block's `A`, `widest`: its longest line); `resumed`: where typing
 *  last went on after the cursor moved (Vim's `Insstart`), `moved`: a move not typed after yet. */
type DeferredBlock = {
  line: number
  col: number
  base: number
  rows: number[]
  /** How far below the first line each of `rows` is: Vim goes by line numbers (see `finishDeferredBlock`). */
  offsets: number[]
  always: boolean
  origin?: number
  toEnd: boolean
  widest: number
  resumed?: { line: number; col: number }
  moved?: { line: number; col: number }
}
const deferredBlock = new WeakMap<object, DeferredBlock>()
/** Insert-mode keys that leave the block's column: a block insert goes on as a one-caret insert after them, as in Vim. */
const blockLeaving = /^<(?:[SCMA]-)*(Up|Down|Home|End|PageUp|PageDown)>$/
/** Vim's insert start (`Insstart_orig`) of a one-caret Insert: the line and column where typing began — fixed, not moved
 *  by the edits since (Backspace past it, or the text typed after that, leaves it where it was). A cursor move restarts it
 *  where the cursor lands, unless that's right of it with something typed already. ⌃W and ⌃U stop there once — and fix it
 *  for the rest of the insert (`frozen`: Neovim maps them to `<C-G>u<C-W>`/`<C-G>u<C-U>`, and `<C-G>u` stops moves from
 *  restarting it). */
type InsertStart = { line: number; col: number; typed: boolean; moved?: { line: number; col: number }; frozen?: boolean }
const insertStart = new WeakMap<object, InsertStart>()
const caretAt = (doc: Text, pos: number) => {
  const line = doc.lineAt(pos)
  return { line: line.number, col: pos - line.from }
}
/** After the cursor moved (`moved`), the next edit starts over there — except to the right of the start once something
 *  was typed (Vim's `stop_arrow`). */
const settled = (s: InsertStart): InsertStart => (s.moved ? (s.typed && s.moved.col > s.col ? { ...s, moved: undefined } : { ...s.moved, typed: s.typed }) : s)
/** ⌃W / ⌃U: from here on the insert start stays where it is now (a move not typed after yet doesn't restart it). */
function freezeInsertStart(cm: object) {
  const s = insertStart.get(cm)
  if (s) insertStart.set(cm, { ...s, moved: undefined, frozen: true })
}
/** Backspace (⌃W, ⌃U) at the start of the insert's line joins it onto the one before: the insert now starts at the join,
 *  as in Vim — what's typed after it goes first, then what was there. */
function joinedStart(tr: Transaction, s: InsertStart): InsertStart {
  const old = tr.startState.doc
  if (s.line < 2 || s.line > old.lines) return s
  const from = old.line(s.line).from
  if (tr.startState.selection.main.head !== from) return s
  let joined = false
  tr.changes.iterChangedRanges((a, b) => (joined ||= a <= from - 1 && b >= from))
  return joined ? { ...caretAt(tr.state.doc, tr.changes.mapPos(from, -1)), typed: s.typed } : s
}
/** A fixed insert start (`frozen`) stays put — a line join doesn't carry it along — except that deleting back past it on
 *  its line pulls it back to where the deletion ended (Vim's `ins_bs`). */
function frozenStart(tr: Transaction, s: InsertStart): InsertStart {
  const at = caretAt(tr.state.doc, tr.state.selection.main.head)
  const back = tr.isUserEvent('delete.backward') && at.line === s.line && at.col < s.col
  return { ...s, col: back ? at.col : s.col, moved: undefined }
}
/** The editor handling a Normal/Visual key, and where a yank made by that key starts (see `pushText`). */
let keyView: EditorView | null = null
let yankStart: { from: number; linewise: boolean } | null = null
const takeYankStart = () => {
  const start = yankStart
  yankStart = null
  return start
}
const handleKey = Vim.multiSelectHandleKey
Vim.multiSelectHandleKey = (cm, key, origin) => {
  const view = cm.cm6
  const vim = cm.state.vim
  const deletes = blockDeletes[key]
  const carets = view?.state.selection.ranges ?? []
  if (view && vim?.insertMode && deletes && carets.length > 1 && carets.every((r: SelectionRange) => r.empty) && blockDelete(cm, vim, view, deletes)) {
    if (deletes === 'word' || deletes === 'line') freezeInsertStart(cm)
    return true
  }
  if (view && vim?.insertMode && (deletes === 'word' || deletes === 'line') && carets.length === 1 && carets[0].empty) {
    deleteInInsert(cm, view, deletes)
    recordReplay(deletes)
    return true
  }
  const leaving = blockLeaving.exec(key)?.[1]
  if (view && vim?.insertMode && leaving && carets.length > 1 && carets.every((r: SelectionRange) => r.empty) && insertStarts.has(cm) && !Vim.getVimGlobalState_().macroModeState.isPlaying) {
    // (Up on the first line, Down on the last: Vim's cursor stays, and so does the block.)
    const line = view.state.doc.lineAt(view.state.selection.main.head).number
    if (/Up/.test(leaving) ? line === 1 : /Down/.test(leaving) ? line === view.state.doc.lines : false) return true
    deferBlock(cm, view, null, 'delete')
  }
  if (view && vim?.insertMode && /^<(?:S-)?CR>$/.test(key) && carets.length > 1 && carets.every((r: SelectionRange) => r.empty) && insertStarts.has(cm) && !Vim.getVimGlobalState_().macroModeState.isPlaying) {
    // Return in a block `I`/`A`/`c` breaks the first line only: the insert goes on there as a one-line insert, as in Vim
    // (the other lines get text at the end only if that line has grown, see `finishDeferredBlock`).
    if (deferBlock(cm, view, null, 'delete')) oneLineRedo(vim)
  }
  if (view && vim?.insertMode && (key === '<Left>' || key === '<Right>') && carets.every((r: SelectionRange) => r.empty)) {
    // Vim's Insert Left/Right stop at the line's ends (no 'whichwrap'); CodeMirror's go on to the next line.
    const { head } = view.state.selection.main
    const line = view.state.doc.lineAt(head)
    if (head === (key === '<Left>' ? line.from : line.to)) return true
  }
  if (view && vim?.insertMode && (key === '<Left>' || key === '<Right>') && carets.length > 1 && carets.every((r: SelectionRange) => r.empty) && insertStarts.has(cm) && !Vim.getVimGlobalState_().macroModeState.isPlaying) {
    // Left from where the insert began, or Right from where its text ends, leaves what was inserted: as for the keys
    // that leave the block's column, Vim works out the other lines at the end.
    const { start, end } = blockInserts(cm, view.state)
    const { mainIndex, main } = view.state.selection
    if (start(mainIndex) !== null && main.head === (key === '<Left>' ? start(mainIndex) : end(mainIndex))) deferBlock(cm, view, null, 'delete')
  }
  if (view && vim?.insertMode && (key === '<Up>' || key === '<Down>') && insertVertical(cm, vim, view, key === '<Down>')) return true
  if (view && vim?.insertMode && insertMotion.test(key) && !Vim.getVimGlobalState_().macroModeState.isPlaying) {
    // (CodeMirror moves the cursor once the key is handled.)
    const head = view.state.selection.main.head
    // (Home and End always count as a move in Vim, even where the cursor already is — in a one-caret insert.)
    const always = /(?:Home|End)>$/.test(key) && carets.length === 1 && !deferredBlock.has(cm)
    queueMicrotask(() => (always || view.state.selection.main.head !== head) && vim.insertMode && arrowRestart(vim))
  }
  if (!view || !vim || vim.insertMode) return handleKey(cm, key, origin)
  const goalBefore = normalGoal(view, vim)
  keyStart.set(cm, startOf(view.state))
  keyView = view
  yankStart = null
  const visual = vim.visualMode
  // The key is a command of its own (after a count, if any), not the argument of one (`r.`, `f.`, `"a`).
  const command = /^\d*$/.test(vim.inputState.keyBuffer.join('')) && !vim.inputState.operator
  const sel = vim.visualBlock && command && (key === 'I' || key === 'A') ? vim.sel : null
  // (A `$` corner is on its line's last character, as Vim's cursor: `$` from a short line makes the block start there.)
  const cornerCh = (p: Pos) => (Number.isFinite(p.ch) ? p.ch : charStartIn(cm.getLine(p.line), Math.max(0, cm.getLine(p.line).length - 1)))
  const block = sel && { line: Math.min(sel.anchor.line, sel.head.line), ch: Math.min(cornerCh(sel.anchor), cornerCh(sel.head)), right: Math.max(sel.anchor.ch, sel.head.ch) + 1 }
  // A block's `I`, `c` and `s` (`$` or not) leave the lines that end left of the block alone, as Vim does — a blank line
  // in indented code doesn't get the `// ` (a line that ends right at the block's column does: `cccc` + `X`).
  const skipShortFrom = vim.visualBlock && command && (key === 'I' || key === 'c' || key === 's') ? Math.min(vim.sel.anchor.ch, vim.sel.head.ch) : null
  // `.` of a block edit near the end: the dependency repeats it on as many lines as the block had, and the ones past the
  // last line land at the end of the document (`XfourX`). Only the lines that exist get it, as in Vim.
  const changes = Vim.getVimGlobalState_().macroModeState.lastInsertModeChanges
  const [height, recorded] = [changes.visualBlock, changes.changes]
  const repeat = key === '.' && command && !visual && height && height > 0
  const caret = view.state.selection.main.head
  const edit = vim.lastEditInputState
  const blockEdit = blockRepeat?.edit === edit ? blockRepeat : null
  const before = view.state.doc
  let padded = false
  /** `.` of a block `I`/`c`: its lines that end left of the cursor's column, which Vim leaves alone. */
  let shortLines: number[] = []
  // A block `c`: the block it deletes again is as tall as the one it was made on — only the lines that exist, as `I`/`A`.
  const blockSel = repeat ? edit?.operatorArgs?.lastSel : undefined
  if (repeat) {
    const line = view.state.doc.lineAt(caret)
    changes.visualBlock = Math.min(height, view.state.doc.lines - line.number)
    if (blockSel?.visualBlock && edit?.operatorArgs) {
      const { anchor, head } = blockSel
      edit.operatorArgs.lastSel = { ...blockSel, anchor: new CodeMirror.Pos(0, anchor.ch), head: new CodeMirror.Pos(changes.visualBlock, head.ch) }
    }
    // Vim ignores a count on it (`2.` on the last line is still one insert, not two).
    vim.inputState.keyBuffer.length = 0
    if (vim.lastEditInputState) vim.lastEditInputState.repeatOverride = undefined
    // (`A`: lines that end left of where the text goes are padded out to it first, as in Vim.)
    const append = blockEdit?.append ?? 0
    if (blockSel?.visualBlock || (blockEdit && !append && !blockEdit.toEnd)) {
      const col = caret - line.from
      for (let n = line.number + 1; n <= line.number + changes.visualBlock; n++) if (view.state.doc.line(n).length < col) shortLines.push(n)
    }
    const at = Array.from({ length: changes.visualBlock + 1 }, (_, i) => view.state.doc.line(line.number + i).to)
    padded = append > 0 && padTo(view, at, caret - line.from + append)
    if (append) view.dispatch({ selection: { anchor: Math.min(caret + append, view.state.doc.line(line.number).to) } })
  }
  // `.` of a `$` block's `A`: the dependency repeats it at the cursor's column on every line; Vim appends to each line.
  const appended = repeat && blockEdit?.toEnd ? netInserted(recorded) : null
  const lastEdit = { input: vim.lastEditInputState, action: vim.lastEditActionCommand, expect: changes.expectCursorActivityForChange }
  failedMotion.delete(vim)
  try {
    if (appended === null) return handleKey(cm, key, origin)
    const { doc } = view.state
    const first = doc.lineAt(caret).number
    const lines = Array.from({ length: Math.min(height ?? 0, doc.lines - first) + 1 }, (_, i) => doc.line(first + i))
    view.dispatch({ changes: lines.map((l) => ({ from: l.to, insert: appended })), userEvent: 'input' })
    return true
  } finally {
    // An operator whose motion failed (`dj` on the last line) isn't an edit: `.` still repeats the one before, as in Vim.
    if (failedMotion.has(vim) && vim.lastEditInputState !== lastEdit.input) {
      vim.lastEditInputState = lastEdit.input
      vim.lastEditActionCommand = lastEdit.action
      changes.changes = recorded
      changes.expectCursorActivityForChange = lastEdit.expect
    }
    failedMotion.delete(vim)
    if (blockSel && edit?.operatorArgs) edit.operatorArgs.lastSel = blockSel
    keyStart.delete(cm)
    // (The dependency's repeat put it on every line: the short ones get their text back.)
    const { doc: after } = view.state
    const undo = after.lines === before.lines ? shortLines.flatMap((n) => {
      const [was, now] = [before.line(n), after.line(n)]
      return was.text === now.text ? [] : [{ from: now.from, to: now.to, insert: was.text }]
    }) : []
    if (undo.length) view.dispatch({ changes: undo, userEvent: 'input' })
    if (padded || undo.length) mergeSince(view, before)
    // (Unless the key recorded a new edit: `r.`.)
    if (changes.changes === recorded) changes.visualBlock = height
    if (block && vim.insertMode) {
      const finite = Number.isFinite(block.right)
      blockOrigin.set(cm, { line: block.line, ch: block.ch, pad: key === 'A' && finite ? block.right : undefined, toEnd: key === 'A' && !finite })
      blockRepeat = { edit: vim.lastEditInputState, append: key === 'A' && finite ? block.right - block.ch : 0, toEnd: key === 'A' && !finite }
    }
    if (skipShortFrom !== null && vim.insertMode && view.state.selection.ranges.length > 1) {
      const { doc, selection } = view.state
      const reach = selection.ranges.filter((r: SelectionRange, i: number) => {
        const l = doc.lineAt(r.head)
        return i === selection.mainIndex || !(r.head === l.to && l.length < skipShortFrom)
      })
      if (reach.length < selection.ranges.length) view.dispatch({ selection: EditorSelection.create(reach, reach.indexOf(selection.main)) })
    }
    if (vim.insertMode && view.state.selection.ranges.length > 1) {
      const heads = view.state.selection.ranges.map((r: SelectionRange) => r.head)
      insertStarts.set(cm, heads)
      insertEnds.set(cm, heads)
    }
    // Vim leaves the cursor where a block `I`/`A` repeat started (on its first character, for `I`).
    if (repeat && blockEdit && vim.lastEditInputState === edit) view.dispatch({ selection: { anchor: caret } })
    // … and a block `c`'s on the last character it put on the first line.
    const net = repeat && blockSel?.visualBlock && !vim.insertMode && vim.lastEditInputState === edit ? netInserted(recorded) : null
    if (net !== null) {
      const line = view.state.doc.lineAt(caret)
      const col = caret - line.from + net.length
      view.dispatch({ selection: { anchor: line.from + (col > 0 ? charStartIn(line.text, col - 1) : 0) } })
    }
    wholeVisualEnds(cm, vim)
    if (vim.insertMode && (vim.insertModeRepeat ?? 1) > 1) countedGoal.set(vim, goalBefore)
    else countedGoal.delete(vim)
    keyView = null
    const yank = takeYankStart()
    const { doc } = view.state
    if (yank && !visual && !vim.visualMode && !vim.insertMode && yank.from < caret) {
      // A yank back (`yb`, `yge`, `yiw`, `yk`): the cursor goes to the start of what was yanked, as in Vim — the dependency
      // leaves it where it was. A line yank keeps the column.
      const line = doc.lineAt(yank.from)
      const col = caret - doc.lineAt(caret).from
      view.dispatch({ selection: { anchor: yank.linewise ? line.from + charStartIn(line.text, Math.min(col, line.length)) : yank.from } })
    }
    // Normal mode's cursor is on a character, never past the end of a line (a Visual `x` through the end leaves it there).
    const { main, ranges } = view.state.selection
    const onChar = !vim.insertMode && !vim.visualMode && ranges.length === 1 && main.empty ? onCharacter(doc, main.head) : main.head
    if (onChar !== main.head) view.dispatch({ selection: { anchor: onChar } })
  }
}

/** The cursor moved in Insert mode: as in Vim, `.` now inserts what's typed from here on, at the cursor — not the command
 *  that began the session (`cw`, `A`, a block's `I`/`A`/`c`), and on one line. */
const insertHere = { keys: '', type: 'action' as const, action: 'enterInsertMode', actionArgs: { insertAt: 'inplace' } }
/** Insert `insertRight` columns right of the cursor (a block `A`'s width; a shorter line is padded out to it). */
let insertRight = 0
Vim.defineAction('nbmInsertRight', function (this: VimActions, cm, _actionArgs, vim) {
  const view = cm.cm6
  if (!view) return
  const head = view.state.selection.main.head
  const line = view.state.doc.lineAt(head)
  const col = head - line.from + insertRight
  padTo(view, [line.to], col)
  view.dispatch({ selection: { anchor: view.state.doc.lineAt(head).from + col } })
  this.enterInsertMode(cm, { insertAt: 'inplace', repeat: 1 }, vim)
})
/** `.` of a block `c` that went on as a one-line insert: as in Vim, a block as tall and wide as the one it changed (`toEnd`:
 *  a `$` block's) is deleted again from the cursor — a line ending at or left of its column keeps its text — and the keys
 *  replay on the first line. */
let changeBlock = { height: 0, width: 1, toEnd: false }
Vim.defineAction('nbmChangeBlock', function (this: VimActions, cm, _actionArgs, vim) {
  const view = cm.cm6
  if (!view) return
  const { doc } = view.state
  const head = view.state.selection.main.head
  const first = doc.lineAt(head)
  const col = head - first.from
  const lines = Array.from({ length: Math.min(doc.lines, first.number + changeBlock.height) - first.number + 1 }, (_, i) => doc.line(first.number + i))
  const cuts = lines.flatMap((l) => (l.length > col ? [{ from: l.from + col, to: changeBlock.toEnd ? l.to : l.from + charEndIn(l.text, Math.min(l.length, col + changeBlock.width)) }] : []))
  const changes = ChangeSet.of(cuts, doc.length)
  view.dispatch({ changes, selection: { anchor: head }, userEvent: 'delete' })
  // (When the insert ends, the other lines get what the first one grew by, as for the change itself — see `deferBlock`.)
  const rows = lines.slice(1).map((l) => changes.mapPos(l.from + Math.min(col, l.length), -1))
  const base = view.state.doc.lineAt(head).length
  deferredBlock.set(cm, { line: first.from, col, base, rows, offsets: rows.map((_, i) => i + 1), always: true, toEnd: false, widest: base })
  this.enterInsertMode(cm, { insertAt: 'inplace', repeat: 1 }, vim)
})
function restartRedo(vim: Parameters<ActionFn>[2]) {
  blockRepeat = null
  Vim.getVimGlobalState_().macroModeState.lastInsertModeChanges.visualBlock = 0
  vim.lastEditInputState = new (vim.inputState.constructor as new () => typeof vim.inputState)()
  vim.lastEditActionCommand = insertHere
}
/** An arrow (Home, End…) moved the cursor in Insert mode: besides restarting `.`, it drops the insert's count, as in Vim
 *  (`3iX<Down>Y` inserts `X` and `Y` once each). */
function arrowRestart(vim: Parameters<ActionFn>[2]) {
  restartRedo(vim)
  // (What's typed next starts the recorded text afresh — also after a Home/End that left the cursor where it was.)
  Vim.getVimGlobalState_().macroModeState.lastInsertModeChanges.maybeReset = true
  vim.insertModeRepeat = undefined
  countedGoal.delete(vim)
}

/** The screen column `j`/`k` head for in Normal mode (Vim's `curswant`): kept from the last vertical move (`$`: the end of
 *  every line), else the cursor's. Screen columns, not code units: `é` with its accent is one, `日` two, a tab up to the
 *  next tab stop. */
const verticalMotions = /^(?:moveByLines|moveByDisplayLines|moveByScroll|moveToColumn|moveToEol)$/
/** The goal `j`/`k` last kept, in screen columns — while `lastHPos` is still what it set (a click, `gj`, `|` set their own). */
const keptGoal = new WeakMap<object, { hpos: number; line: number; col: number }>()
function curswant(text: string, head: Pos, vim: Parameters<ActionFn>[2], tabSize: number) {
  // (The bundle drops the name of the `moveByLines` below; the dependency's own motions are named by their keys.)
  if ((vim.lastMotion === moveByLines || verticalMotions.test(vim.lastMotion?.name ?? '')) && vim.lastHPos >= 0) {
    const kept = keptGoal.get(vim)
    if (vim.lastHPos === Infinity) return Infinity
    if (kept?.hpos === vim.lastHPos && kept.line === head.line) return kept.col
    // (`|` counts screen columns; the others leave an offset on the cursor's line.)
    if (vim.lastMotion?.name === 'moveToColumn') return vim.lastHPos
    return cursorCol(text, Math.min(vim.lastHPos, text.length), tabSize)
  }
  return cursorCol(text, head.ch, tabSize)
}
function normalGoal(view: EditorView, vim: Parameters<ActionFn>[2]) {
  const { state } = view
  const line = state.doc.lineAt(state.selection.main.head)
  return curswant(line.text, new CodeMirror.Pos(line.number - 1, state.selection.main.head - line.from), vim, state.tabSize)
}
/** Normal/Visual states whose last key's `j`/`k` failed: that key isn't the edit `.` repeats (see the key handler). */
const failedMotion = new WeakSet<object>()
// `j`/`k` (and `+`, `-`, `_`, Return): the dependency's, keeping the column in screen columns — the character covering it on
// the line it lands on (in a wide character or a tab: on it).
const moveByLines: Parameters<typeof Vim.defineMotion>[1] = (cm, head, motionArgs, vim) => {
  const tabSize = cm.cm6?.state.tabSize ?? 4
  // (`+`, `-`, `_` are linewise too, as in Vim — the dependency's would make `d+` delete characters.)
  if (motionArgs.toFirstChar) motionArgs.linewise = true
  let want = curswant(cm.getLine(head.line), head, vim, tabSize)
  const repeat = motionArgs.repeat + (motionArgs.repeatOffset || 0)
  let line = motionArgs.forward ? head.line + repeat : head.line - repeat
  const [first, last] = [cm.firstLine(), cm.lastLine()]
  const posV = cm.findPosV(head, motionArgs.forward ? repeat : -repeat, 'line', vim.lastHSPos)
  const keep = (hpos: number, at: number) => {
    vim.lastHPos = hpos
    keptGoal.set(vim, { hpos, line: at, col: want })
  }
  // Up from the first line, Down from the last: the motion fails, as in Vim — the cursor stays (the goal too) and an
  // operator is dropped (`dj` on the last line deletes nothing). A count that reaches past the edge still goes to it.
  if ((line < first && head.line === first) || (line > last && head.line === last)) {
    keep(want === Infinity ? Infinity : head.ch, head.line)
    failedMotion.add(vim)
    return null
  }
  line = Math.max(first, Math.min(last, line))
  const marked = motionArgs.forward ? posV.line > line : posV.line < line
  const text = cm.getLine(marked ? posV.line : line)
  let ch: number
  if (marked) {
    line = posV.line
    ch = posV.ch
  } else if (motionArgs.toFirstChar) {
    const blank = text.search(/\S/)
    ch = blank < 0 ? text.length : blank
    want = cursorCol(text, ch, tabSize)
  } else ch = offsetAtCol(text, want, tabSize)
  keep(want === Infinity ? Infinity : ch, line)
  vim.lastHSPos = cm.charCoords(new CodeMirror.Pos(line, ch), 'div').left
  return new CodeMirror.Pos(line, ch)
}
Vim.defineMotion('moveByLines', moveByLines)
/** A counted insert (`3i`, `3a`, `3o`…) until its first arrow: Vim's Up/Down then still head for the column the cursor
 *  wanted before the insert began, not where the typed text left it (`2l3iX<Down>` lands in column 2). */
const countedGoal = new WeakMap<object, number>()

// ---- Backspace, Delete, ⌃W, ⌃U in a block `I`/`A`/`c` ----
// CodeMirror deletes at every caret — joining lines where one is at column 0, deleting text that was there before on every
// line; the dependency's ⌃W/⌃U act on the main line and drop the other carets. As Vim (backspace=indent,eol,start): every
// caret deletes the same inserted text on its own line (⌃W, ⌃U and Backspace stop once at the start of the insert).
// Deleting what was there before — Backspace/⌃W/⌃U at the insert's start, Delete at any time — happens on the first line
// only: the insert goes on there as a one-line insert, the other lines get the first line's text when it ends (see
// `deferBlock`), and `.` replays the keys there (`I⌫⌫Z` at `hhh` deletes the two characters before it). `.` of an insert
// that kept its block repeats the text as it now stands (`XY ⌃WZ` → `Z`).

type BlockDelete = 'char' | 'forward' | 'word' | 'line'
const blockDeletes: Record<string, BlockDelete> = { '<BS>': 'char', '<Del>': 'forward', '<C-w>': 'word', '<C-u>': 'line' }
/** `.` replays these (the dependency records Backspace and Delete itself). */
const replayKeys: Partial<Record<BlockDelete, string>> = { word: 'nbmDeleteWordBefore', line: 'nbmDeleteLineBefore' }

/** Vim's ⌃W start in `text` from offset `col`, not before `stop`: back over blanks, then over one class of characters. */
function wordStart(text: string, col: number, stop: number) {
  const chars = charsOf(text.slice(0, col)).filter((c) => c.from >= stop)
  let i = chars.length
  const cls = (j: number) => charClass(text.slice(chars[j].from, chars[j].to))
  while (i > 0 && cls(i - 1) === 0) i--
  const k = i > 0 ? cls(i - 1) : 0
  while (i > 0 && cls(i - 1) === k && k !== 0) i--
  return i < chars.length ? chars[i].from : col
}

/** Where Insert's Up/Down keep heading (Vim's `curswant`): the column, while the cursor is where the last one left it. */
const verticalGoal = new WeakMap<object, { head: number; col: number }>()
/** Insert-mode Up/Down with one caret, as Vim: on the first line Up (on the last, Down) stays put — CodeMirror's goes to
 *  the line's start/end — and between unwrapped lines the cursor keeps its screen column (see `curswant`), not pixels. true:
 *  handled here. */
function insertVertical(cm: object, vim: Parameters<ActionFn>[2], view: EditorView, forward: boolean) {
  const { doc, selection } = view.state
  const main = selection.main
  if (selection.ranges.length !== 1 || !main.empty) return false
  if (view.moveToLineBoundary(main, forward, true).head === (forward ? doc.length : 0)) return true
  const line = doc.lineAt(main.head)
  const n = line.number + (forward ? 1 : -1)
  const oneRow = (l: { from: number; to: number }) => view.moveToLineBoundary(EditorSelection.cursor(l.from), true, true).head >= l.to
  if (n < 1 || n > doc.lines || !oneRow(line) || !oneRow(doc.line(n))) return false
  const goal = verticalGoal.get(cm)
  const counted = (vim.insertModeRepeat ?? 1) > 1 ? countedGoal.get(vim) : undefined
  const { tabSize } = view.state
  const col = counted ?? (goal?.head === main.head ? goal.col : displayCol(line.text, main.head - line.from, tabSize))
  const to = doc.line(n)
  const head = to.from + offsetAtCol(to.text, col, tabSize)
  view.dispatch({ selection: { anchor: head }, scrollIntoView: true, userEvent: 'select' })
  verticalGoal.set(cm, { head, col })
  if (!Vim.getVimGlobalState_().macroModeState.isPlaying) arrowRestart(vim)
  return true
}

/** What a key deletes before (`forward`: after) `head` that was there before the insert: at column 0 the line break. */
function deleteBefore(doc: Text, head: number, kind: BlockDelete) {
  const line = doc.lineAt(head)
  const col = head - line.from
  if (kind === 'forward') return { from: head, to: Math.min(doc.length, charEnd(doc, head)) }
  if (col === 0) return { from: Math.max(0, head - 1), to: head }
  const indent = /^[ \t]*/.exec(line.text)![0].length
  const from = kind === 'char' ? charStartIn(line.text, col - 1) : kind === 'word' ? wordStart(line.text, col, 0) : col > indent ? indent : 0
  return { from: line.from + from, to: head }
}

/** ⌃W / ⌃U at a one-caret Insert's cursor (backspace=indent,eol,start): back to where this insert's typing began, if
 *  that's on the line and before the cursor — what was entered goes first; from there on (nothing entered, a second ⌃U)
 *  what was there before, to the indent and then the line's start, and at column 0 the line break. */
function deleteInInsert(cm: object, view: EditorView, kind: 'word' | 'line') {
  const { doc } = view.state
  const head = view.state.selection.main.head
  const line = doc.lineAt(head)
  freezeInsertStart(cm)
  const start = insertStart.get(cm)
  const col = head - line.from
  let cut = deleteBefore(doc, head, kind)
  if (start && start.line === line.number && start.col < col) {
    cut = { from: line.from + (kind === 'word' ? wordStart(line.text, col, start.col) : Math.max(start.col, cut.from - line.from)), to: head }
  }
  view.dispatch({ changes: cut, selection: { anchor: cut.from }, userEvent: 'delete.backward' })
}

/** `.` replays the key (the dependency records only Backspace and Delete). */
function recordReplay(kind: 'word' | 'line') {
  const lastChange = Vim.getVimGlobalState_().macroModeState.lastInsertModeChanges
  if (lastChange.maybeReset) lastChange.changes = []
  lastChange.maybeReset = false
  lastChange.changes.push(new Vim.InsertModeKey(replayKeys[kind]!, new KeyboardEvent('keydown')))
}

for (const [kind, name] of Object.entries(replayKeys) as ['word' | 'line', string][]) {
  CodeMirror.keys[name] = (cm: CodeMirror) => {
    if (cm.cm6) deleteInInsert(cm, cm.cm6, kind)
  }
}

/** What a recorded insert (`.`'s keys) leaves: its text with the Backspaces in it applied, or null when it has other keys
 *  or deletes past its own start. */
function netInserted(recorded: readonly unknown[]) {
  let text = ''
  for (const c of recorded) {
    if (typeof c === 'string') text += c
    else if (c instanceof Vim.InsertModeKey && c.keyName === 'Backspace' && text) text = text.slice(0, lastCharOffset(text))
    else return null
  }
  return text
}

/** Where each caret of a multi-caret insert started inserting (null: not on its line any more), and where what it
 *  inserted ends (never before the caret, nor off its line). */
function blockInserts(cm: object, state: EditorState) {
  const { doc, selection } = state
  const { ranges } = selection
  const starts = insertStarts.get(cm)
  const ends = insertEnds.get(cm)
  const tracked = starts?.length === ranges.length ? starts : null
  const start = (i: number) => {
    const s = tracked?.[i]
    return s !== undefined && doc.lineAt(s).number === doc.lineAt(ranges[i].head).number && s <= ranges[i].head ? s : null
  }
  const end = (i: number) => {
    const line = doc.lineAt(ranges[i].head)
    return Math.max(ranges[i].head, Math.min(ends?.length === ranges.length ? ends[i] : ranges[i].head, line.to))
  }
  /** What the other carets inserted (to take back). */
  const others = () => ranges.flatMap((_, i) => (i !== selection.mainIndex && start(i) !== null && start(i)! < end(i) ? [{ from: start(i)!, to: end(i) }] : []))
  return { start, end, others }
}

/** A block `I`/`A`/`c` goes on as a one-caret insert at the main caret (Vim leaves no carets on the other lines): their
 *  inserted text is taken back (`changes`: and these made on the main line), and — as in Vim — they get theirs when the
 *  insert ends (see `finishDeferredBlock`). */
function deferBlock(cm: object, view: EditorView, cut: { from: number; to: number } | null, userEvent: string) {
  const { state } = view
  const { doc, selection } = state
  const { start, end, others } = blockInserts(cm, state)
  const i = selection.mainIndex
  const mainStart = start(i)
  if (mainStart === null) return false
  const line = doc.lineAt(selection.main.head)
  const rows = selection.ranges.flatMap((_, j) => (j !== i && start(j) !== null ? [start(j)!] : []))
  const changes = ChangeSet.of([...(cut ? [cut] : []), ...others()], doc.length)
  // From here on ⌃W/⌃U stop where the main line's insert began (fixed there, as for any one-caret insert).
  const { typed = false, frozen } = insertStart.get(cm) ?? {}
  insertStart.set(cm, { ...caretAt(doc, mainStart), typed: typed || mainStart < end(i), frozen })
  view.dispatch({ changes, selection: { anchor: changes.mapPos(selection.main.head, -1) }, userEvent })
  const origin = blockOrigin.get(cm)
  const base = line.length - (end(i) - mainStart)
  const after = view.state.doc
  deferredBlock.set(cm, {
    line: changes.mapPos(line.from, -1),
    col: mainStart - line.from,
    base,
    rows: rows.map((p) => changes.mapPos(p, -1)),
    offsets: rows.map((p) => doc.lineAt(p).number - line.number),
    always: !origin,
    origin: origin?.ch,
    toEnd: origin?.toEnd ?? false,
    widest: Math.max(base, ...rows.map((p) => after.lineAt(changes.mapPos(p, -1)).length)),
  })
  insertStarts.delete(cm)
  insertEnds.delete(cm)
  blockOrigin.delete(cm)
  return true
}

/** The insert ends: the other lines of a block insert that went on as a one-caret one get its text (see `deferBlock`), as
 *  Vim's `op_insert` works it out — from the first line, as many characters as it has grown by. A block `c` takes them
 *  from where its insert began. A block `I`/`A` only if the cursor is back on that line: `I` from its column — or from
 *  where the insert last began (`started`, Vim's `Insstart_orig`) when that's right of it; `A` from where it appended
 *  — or as an `I` from `started` when that's at or left of the block. A `$` block's `A` with the cursor moved left of
 *  where it appended: from where typing last went on, and on the other lines at a column cut short by that move. */
function finishDeferredBlock(cm: object, view: EditorView, started?: InsertStart) {
  const d = deferredBlock.get(cm)
  deferredBlock.delete(cm)
  if (!d) return
  const { doc } = view.state
  const line = doc.lineAt(d.line)
  const grown = line.length - d.base
  if (grown <= 0 || (!d.always && doc.lineAt(view.state.selection.main.head).number !== line.number)) return
  // Vim goes by line numbers: a line break typed since (Return) moves the text onto the lines now that far below the first.
  const rows = d.rows.flatMap((p, j) => {
    const now = doc.lineAt(p)
    const n = line.number + d.offsets[j]
    if (now.number === line.number || n > doc.lines) return []
    const moved = now.number !== n
    return [{ row: moved ? doc.line(n) : now, col: p - now.from, p: moved ? undefined : p }]
  })
  type Row = (typeof rows)[number]
  const begun = started?.line === line.number ? started.col : null
  const c = d.origin
  /** Where the text goes on `row` (null: not on it), after `pad` spaces. */
  // (A block `c`: at the block's column on each line as it is now — a line ending left of it is left alone, Vim's `op_change`.)
  let at = ({ row, col, p }: Row): { from: number; pad?: number } | null => {
    if (d.always) return row.length < d.col ? null : { from: row.from + d.col }
    if (p !== undefined) return { from: p }
    // (On another line than its own: a `$` block's `A` at its end, an `A` pads a shorter one out, an `I` leaves it alone.)
    if (d.toEnd) return { from: row.to }
    if (row.length >= col) return { from: row.from + col }
    return col > (c ?? 0) ? { from: row.to, pad: col - row.length } : null
  }
  let col = d.col
  let start = c
  if (c !== undefined && d.toEnd) {
    const resumed = d.resumed?.line === line.number ? d.resumed.col : d.col
    const offset = d.col - resumed
    if (offset > 0) {
      // (Vim narrows the block's right edge by the move — which can put it left of the block's column.)
      const right = d.widest - offset - 1
      if (right < 0) return
      col = resumed
      at = ({ row }) => ({ from: row.from + (row.length < c ? row.length : c <= right ? Math.min(row.length, right + 1) : right === c - 1 ? c : c - 1) })
    }
  } else if (c !== undefined && begun !== null && (d.col === c ? begun > c : begun <= c)) {
    col = start = begun
    at = ({ row }) => (row.length < begun ? null : { from: row.from + begun })
  }
  const text = line.text.slice(col, col + grown)
  const changes = text ? rows.flatMap((r) => {
    const to = at(r)
    return to ? [{ from: to.from, insert: ' '.repeat(to.pad ?? 0) + text }] : []
  }) : []
  if (!changes.length) return
  // (A block `I`/`A` leaves the cursor at the block's left edge — or where the insert last began, if left of that.)
  const head = view.state.selection.main.head
  const anchor = start === undefined ? head : line.from + Math.min(start, begun ?? start, Math.max(0, line.length - 1))
  view.dispatch({ changes, selection: { anchor }, userEvent: 'input' })
}

/** A block insert went on as a one-line insert: `.` replays the keys from the start of the insert, as a block `I` (at the
 *  cursor) or `A` (right of it, by the block's width; at the end of the line for a `$` block) on one line. */
function oneLineRedo(vim: Parameters<ActionFn>[2]) {
  const block = blockRepeat?.edit === vim.lastEditInputState ? blockRepeat : null
  const edit = vim.lastEditInputState
  const sel = edit?.operator === 'change' ? edit.operatorArgs?.lastSel : undefined
  restartRedo(vim)
  if (block?.toEnd) vim.lastEditActionCommand = { ...insertHere, actionArgs: { insertAt: 'eol' } }
  else if (block?.append) {
    insertRight = block.append
    vim.lastEditActionCommand = { ...insertHere, action: 'nbmInsertRight' }
  } else if (sel?.visualBlock) {
    const [left, right] = [Math.min(sel.anchor.ch, sel.head.ch), Math.max(sel.anchor.ch, sel.head.ch)]
    changeBlock = { height: Math.abs(sel.head.line - sel.anchor.line), width: right - left + 1, toEnd: !Number.isFinite(right) }
    vim.lastEditActionCommand = { ...insertHere, action: 'nbmChangeBlock' }
  }
}

function blockDelete(cm: object, vim: Parameters<ActionFn>[2], view: EditorView, kind: BlockDelete) {
  const { doc, selection } = view.state
  const { ranges, mainIndex } = selection
  const { start, end, others } = blockInserts(cm, view.state)
  const mainStart = start(mainIndex)
  if (mainStart === null) return false
  const lastChange = Vim.getVimGlobalState_().macroModeState.lastInsertModeChanges
  const main = ranges[mainIndex]
  if (kind === 'forward' && main.head < end(mainIndex)) {
    // Delete inside the inserted text (after an arrow key): on every line, as Vim copies the first line's insert.
    const cuts = ranges.map((r, i) => ({ from: r.head, to: Math.min(end(i), charEnd(doc, r.head)) }))
    view.dispatch({ changes: cuts.filter((c) => c.from < c.to), userEvent: 'delete.forward' })
    return true
  }
  if (kind === 'forward' || main.head === mainStart) {
    // What was there before: on the main line only, then a one-line insert from here. (The other lines have their
    // inserted text taken back; they get the first line's at the end, see `deferBlock`.)
    if (kind !== 'forward' && main.head === 0) return true
    const cut = deleteBefore(doc, main.head, kind)
    if (kind === 'forward' || cut.from >= doc.lineAt(main.head).from) deferBlock(cm, view, cut, kind === 'forward' ? 'delete.forward' : 'delete.backward')
    else {
      // (Joined onto the line above: the insert is off its line, so the others get nothing — as in Vim.)
      const changes = ChangeSet.of([cut, ...others()], doc.length)
      view.dispatch({ changes, selection: { anchor: changes.mapPos(main.head, -1) }, userEvent: 'delete.backward' })
      insertStarts.delete(cm)
      insertEnds.delete(cm)
      blockOrigin.delete(cm)
    }
    oneLineRedo(vim)
    const replay = replayKeys[kind]
    if (replay) {
      if (lastChange.maybeReset) lastChange.changes = []
      lastChange.maybeReset = false
      lastChange.changes.push(new Vim.InsertModeKey(replay, new KeyboardEvent('keydown')))
    }
    return true
  }
  // Every caret: back on its own line (never across a line break), stopping at its insert start.
  const cuts = ranges.map((r, i) => {
    const line = doc.lineAt(r.head)
    const col = r.head - line.from
    const stop = (start(i) ?? line.from) - line.from
    const from = kind === 'char' ? Math.max(stop, charStartIn(line.text, col - 1)) : kind === 'word' ? wordStart(line.text, col, stop) : stop
    return { from: line.from + Math.min(from, col), to: r.head }
  })
  view.dispatch({ changes: cuts.filter((c) => c.from < c.to), userEvent: 'delete.backward' })
  // (Backspace: the dependency records the key.)
  if (kind !== 'char') {
    const text = view.state.doc.sliceString(mainStart, view.state.selection.ranges[mainIndex].head)
    lastChange.changes = text ? [text] : []
    lastChange.maybeReset = false
  }
  return true
}

// ---- a character is a grapheme cluster ----
// Vim's unit is a whole character as displayed: `🙂`, `🧑‍💻`, `🇺🇸`, `👍🏽`, `é` with its combining accent. The dependency
// counts UTF-16 code units. Its positions (Normal's cursor, Visual's corners) are kept on a character's start; the steps it
// takes (`h`/`l`/`x`/`X`/`s`/`~`, the word motions, `r`) go a character at a time; and a range it builds one past a corner
// (Visual's inclusive end, a block's columns) — which then ends inside a character — grows to cover all of it.

/** Visual corners sit on a character's start. Entering Visual on an emoji, the dependency puts the cursor on its second
 *  half (so its range covers the pair) — then reads it as the next character: `j` carries it on and the block or selection
 *  takes one character too many on every line (`🙂ab` for `🙂a`). The ranges built from the corners still cover whole
 *  characters (see `setSelections` below). */
function wholeVisualEnds(cm: { getLine(line: number): string }, vim: Parameters<ActionFn>[2]) {
  if (!vim.visualMode || vim.visualLine) return
  for (const end of [vim.sel.anchor, vim.sel.head]) if (Number.isFinite(end.ch)) end.ch = charStartIn(cm.getLine(end.line), end.ch)
}

// Every range it sets grows to whole characters — in place, since the operators then edit the same range objects (a
// charwise `d` deletes `ranges[0]`, not the editor's selection).
const setSelections = CodeMirror.prototype.setSelections
CodeMirror.prototype.setSelections = function (ranges, primIndex) {
  for (const r of ranges) {
    const forward = r.anchor.line < r.head.line || (r.anchor.line === r.head.line && r.anchor.ch <= r.head.ch)
    const [from, to] = forward ? [r.anchor, r.head] : [r.head, r.anchor]
    const empty = from.line === to.line && from.ch === to.ch
    // (A caret inside one: Insert mode's goes after it — `A` on a block ending in an emoji — Normal's onto it.)
    from.ch = (empty && this.state.vim?.insertMode ? charEndIn : charStartIn)(this.getLine(from.line), from.ch)
    // Charwise Visual ending on a line break (an empty line, `$`): it's selected — up to the next line's start.
    const v = this.state.vim
    if (v?.visualMode && !v.visualLine && !v.visualBlock && !empty && to.line < this.lastLine() && to.ch > this.getLine(to.line).length) {
      to.line += 1
      to.ch = 0
    }
    if (empty) to.ch = from.ch
    else to.ch = charEndIn(this.getLine(to.line), to.ch)
  }
  return setSelections.call(this, ranges, primIndex)
}
// The cursor too: Normal's onto a character it lands inside (`$` on a line ending in `🧑‍💻`, `l` at its end), Insert's
// after it (`a` on one).
// Vim's `>` never indents empty lines (CodeMirror's indentMore does, leaving trailing whitespace in the file).
CodeMirror.prototype.indentMore = function (this: CodeMirror) {
  const view = this.cm6
  const { state } = view
  const unit = indentString(state, getIndentUnit(state))
  const lines = new Set<number>()
  for (const r of state.selection.ranges) {
    const last = state.doc.lineAt(r.to > r.from && state.doc.lineAt(r.to).from === r.to ? r.to - 1 : r.to).number
    for (let n = state.doc.lineAt(r.from).number; n <= last; n++) lines.add(n)
  }
  // Insert-mode ⌃T indents the line being typed on even when it's empty, and the caret moves with the text.
  const insert = Boolean(this.state.vim?.insertMode)
  const spec = [...lines].map((n) => state.doc.line(n)).filter((l) => insert || l.length > 0).map((l) => ({ from: l.from, insert: unit }))
  if (!spec.length) return
  const changes = state.changes(spec)
  view.dispatch({ changes, selection: state.selection.map(changes, 1), userEvent: 'input.indent' })
}

// Visual-block `>` shifts by the tab width; everything else indents by the indent unit (2 spaces). Same unit here.
const getOption = CodeMirror.prototype.getOption
CodeMirror.prototype.getOption = function (this: CodeMirror, name: string) {
  if (name === 'tabSize' && this.state.vim?.visualBlock) return getIndentUnit(this.cm6.state)
  return getOption.call(this, name)
} as typeof getOption

const setCursor = CodeMirror.prototype.setCursor
CodeMirror.prototype.setCursor = function (this: CodeMirror, line: number | Pos, ch?: number) {
  const pos = typeof line === 'number' ? { line, ch: ch ?? 0 } : line
  const at = (this.state.vim?.insertMode ? charEndIn : charStartIn)(this.getLine(pos.line), pos.ch)
  return setCursor.call(this, new CodeMirror.Pos(pos.line, at))
}

// `h` / `l` (and `x`, `X`, `s`, `~`, `dl`…): a character at a time, not a code unit.
Vim.defineMotion('moveByCharacters', (cm, head, motionArgs) => {
  const text = cm.getLine(head.line)
  let ch = head.ch
  for (let i = 0; i < motionArgs.repeat; i++) {
    if (motionArgs.forward ? ch >= text.length : ch <= 0) break
    ch = motionArgs.forward ? charEndIn(text, ch + 1) : charStartIn(text, ch - 1)
  }
  return new CodeMirror.Pos(head.line, ch)
})

// `f`/`F`/`t`/`T` and `;`/`,`: over characters (`t ` before `🧑‍💻 ` stops on the emoji, not inside it); a character matches
// only all of it (`fe` doesn't stop on `é` with a combining accent). With no match the motion fails, so its operator does
// nothing (`dfa` without an `a` ahead deleted the cursor's character).
function findChar(cm: Parameters<ActionFn>[0], head: Pos, repeat: number, forward: boolean, typed: string | undefined, till: boolean, skip: boolean) {
  if (!typed) return null
  const text = cm.getLine(head.line)
  const chars = charsOf(text)
  const dir = forward ? 1 : -1
  let i = chars.findIndex((c) => c.to > head.ch)
  if (i < 0) i = chars.length
  // (`;` after `t`: from the character it stopped next to, so that match doesn't stop it again.)
  if (skip) i += dir
  for (let n = 0; n < repeat; n++) {
    do i += dir
    while (i >= 0 && i < chars.length && text.slice(chars[i].from, chars[i].to) !== typed)
    if (i < 0 || i >= chars.length) return null
  }
  return new CodeMirror.Pos(head.line, chars[till ? i - dir : i].from)
}
const lastCharSearch = () => Vim.getVimGlobalState_().lastCharacterSearch
Vim.defineMotion('moveToCharacter', (cm, head, motionArgs) => {
  Object.assign(lastCharSearch(), { increment: 0, forward: Boolean(motionArgs.forward), selectedCharacter: motionArgs.selectedCharacter })
  return findChar(cm, head, motionArgs.repeat, Boolean(motionArgs.forward), motionArgs.selectedCharacter, false, false)
})
Vim.defineMotion('moveTillCharacter', (cm, head, motionArgs) => {
  Object.assign(lastCharSearch(), { increment: motionArgs.forward ? -1 : 1, forward: Boolean(motionArgs.forward), selectedCharacter: motionArgs.selectedCharacter })
  return findChar(cm, head, motionArgs.repeat, Boolean(motionArgs.forward), motionArgs.selectedCharacter, true, false)
})
Vim.defineMotion('repeatLastCharacterSearch', (cm, head, motionArgs) => {
  const last = lastCharSearch()
  const forward = motionArgs.forward === last.forward
  motionArgs.inclusive = forward
  const till = Boolean(last.increment)
  return findChar(cm, head, motionArgs.repeat, forward, last.selectedCharacter, till, till)
})

// ---- word motions ----
// The dependency's `w`/`b`/`e`/`ge` (and `W`…) over characters, with Vim's character classes: blanks, punctuation, word
// characters, emoji (an emoji next to a letter is a word of its own: `a🙂bc` is three) and a few scripts (CJK, kana,
// hangul) as their own words. A character's class is its first code point's.
const vimClassRanges: [number, number, number][] = [
  [0x037e, 0x037e, 1], [0x0387, 0x0387, 1], [0x055a, 0x055f, 1], [0x0589, 0x0589, 1], [0x05be, 0x05be, 1], [0x05c0, 0x05c0, 1],
  [0x05c3, 0x05c3, 1], [0x05f3, 0x05f4, 1], [0x060c, 0x060c, 1], [0x061b, 0x061b, 1], [0x061f, 0x061f, 1], [0x066a, 0x066d, 1],
  [0x06d4, 0x06d4, 1], [0x0700, 0x070d, 1], [0x0964, 0x0965, 1], [0x0970, 0x0970, 1], [0x0df4, 0x0df4, 1], [0x0e4f, 0x0e4f, 1],
  [0x0e5a, 0x0e5b, 1], [0x0f04, 0x0f12, 1], [0x0f3a, 0x0f3d, 1], [0x0f85, 0x0f85, 1], [0x104a, 0x104f, 1], [0x10fb, 0x10fb, 1],
  [0x1361, 0x1368, 1], [0x166d, 0x166e, 1], [0x1680, 0x1680, 0], [0x169b, 0x169c, 1], [0x16eb, 0x16ed, 1], [0x1735, 0x1736, 1],
  [0x17d4, 0x17dc, 1], [0x1800, 0x180a, 1], [0x2000, 0x200b, 0], [0x200c, 0x2027, 1], [0x2028, 0x2029, 0], [0x202a, 0x202e, 1],
  [0x202f, 0x202f, 0], [0x2030, 0x205e, 1], [0x205f, 0x205f, 0], [0x2060, 0x206f, 1], [0x2070, 0x207f, 0x2070],
  [0x2080, 0x2094, 0x2080], [0x20a0, 0x27ff, 1], [0x2800, 0x28ff, 0x2800], [0x2900, 0x2998, 1], [0x29d8, 0x29db, 1],
  [0x29fc, 0x29fd, 1], [0x2e00, 0x2e7f, 1], [0x3000, 0x3000, 0], [0x3001, 0x3020, 1], [0x3030, 0x3030, 1], [0x303d, 0x303d, 1],
  [0x3040, 0x309f, 0x3040], [0x30a0, 0x30ff, 0x30a0], [0x3300, 0x9fff, 0x4e00], [0xac00, 0xd7a3, 0xac00], [0xf900, 0xfaff, 0x4e00],
  [0xfd3e, 0xfd3f, 1], [0xfe30, 0xfe6b, 1], [0xff00, 0xff0f, 1], [0xff1a, 0xff20, 1], [0xff3b, 0xff40, 1], [0xff5b, 0xff65, 1],
  [0x1d000, 0x1d24f, 1], [0x1d400, 0x1d7ff, 1], [0x1f000, 0x1f2ff, 1], [0x1f300, 0x1f9ff, 1], [0x20000, 0x2a6df, 0x4e00],
  [0x2a700, 0x2b73f, 0x4e00], [0x2b740, 0x2b81f, 0x4e00], [0x2f800, 0x2fa1f, 0x4e00],
]
const emojiChar = /^(?:\p{Extended_Pictographic}|\p{Regional_Indicator})/u
/** Vim's class of the character at the start of `text`: 0 blank, 1 punctuation, 2 word, 3 emoji, else a script's. */
function charClass(text: string) {
  const c = text.codePointAt(0) ?? 0
  if (c < 0x100) {
    if (c === 0x20 || c === 0x09 || c === 0 || c === 0xa0) return 0
    return /\w/.test(text[0]) || c >= 0xc0 || c === 0xaa || c === 0xb5 || c === 0xba ? 2 : 1
  }
  if (emojiChar.test(text)) return 3
  return vimClassRanges.find(([lo, hi]) => c >= lo && c <= hi)?.[2] ?? 2
}

type WordLine = { text: string; chars: { from: number; to: number }[]; classes: number[] }
type Word = { line: number; from: number; to: number }
/** The dependency's `findWord` and `moveToWord`, in characters (`from`/`to`/`ch` are character indexes) — then back to
 *  code units. */
function moveToWord(cm: Parameters<ActionFn>[0], cur: Pos, repeat: number, forward: boolean, wordEnd: boolean, bigWord: boolean) {
  const cache = new Map<number, WordLine>()
  const lineAt = (n: number) => {
    let l = cache.get(n)
    if (!l) {
      const text = cm.getLine(n)
      const chars = charsOf(text)
      l = { text, chars, classes: chars.map((c) => charClass(text.slice(c.from, c.to))) }
      cache.set(n, l)
    }
    return l
  }
  const isLine = (n: number) => n >= cm.firstLine() && n <= cm.lastLine()
  const toIndex = (n: number, ch: number) => {
    const { chars } = lineAt(n)
    const i = chars.findIndex((c) => c.to > ch)
    return i < 0 ? chars.length + Math.max(0, ch - lineAt(n).text.length) : i
  }
  const toCh = (n: number, i: number) => {
    const { chars, text } = lineAt(n)
    return i < 0 ? i : i < chars.length ? chars[i].from : text.length + (i - chars.length)
  }
  const start = { line: cur.line, ch: toIndex(cur.line, cur.ch) }
  const findWord = (at: { line: number; ch: number }, emptyLineIsWord: boolean): Word | null => {
    let lineNum = at.line
    let pos = at.ch
    let line = lineAt(lineNum)
    const dir = forward ? 1 : -1
    // (A word: a run of one class — any non-blank one for `W`.)
    const cls = (i: number) => line.classes[i] ?? 0
    const same = (i: number, k: number) => (bigWord ? cls(i) > 0 : cls(i) === k)
    if (emptyLineIsWord && !line.text) {
      lineNum += dir
      if (!isLine(lineNum)) return null
      line = lineAt(lineNum)
      pos = forward ? 0 : line.chars.length
    }
    for (;;) {
      if (emptyLineIsWord && !line.text) return { from: 0, to: 0, line: lineNum }
      const stop = dir > 0 ? line.chars.length : -1
      while (pos !== stop) {
        const k = cls(pos)
        if (k > 0) {
          const wordStart = pos
          while (pos !== stop && same(pos, k)) pos += dir
          const wordEnd = pos
          // (Started at the end of a word: find the next one.)
          if (wordStart === at.ch && lineNum === at.line && wordEnd === wordStart + dir) continue
          return { from: Math.min(wordStart, wordEnd + 1), to: Math.max(wordStart, wordEnd), line: lineNum }
        }
        pos += dir
      }
      lineNum += dir
      if (!isLine(lineNum)) return null
      line = lineAt(lineNum)
      pos = dir > 0 ? 0 : line.chars.length
    }
  }
  if ((forward && !wordEnd) || (!forward && wordEnd)) repeat++
  // (For `e`, empty lines are not words.)
  const emptyLineIsWord = !(forward && wordEnd)
  const words: Word[] = []
  let at = start
  for (let i = 0; i < repeat; i++) {
    const word = findWord(at, emptyLineIsWord)
    if (!word) {
      const last = cm.lastLine()
      const eod = lineAt(last).chars.length
      words.push(forward ? { line: last, from: eod, to: eod } : { line: 0, from: 0, to: 0 })
      break
    }
    words.push(word)
    at = { line: word.line, ch: forward ? word.to - 1 : word.from }
  }
  const shortCircuit = words.length !== repeat
  const first = words[0]
  let last = words.pop()
  let target: { line: number; ch: number } | undefined
  if (forward && !wordEnd) {
    // `w`: not started in the middle of a word — the extra word at the end goes.
    if (!shortCircuit && (first.from !== start.ch || first.line !== start.line)) last = words.pop()
    target = last && { line: last.line, ch: last.from }
  } else if (forward && wordEnd) {
    target = last && { line: last.line, ch: last.to - 1 }
  } else if (!forward && wordEnd) {
    // `ge`
    if (!shortCircuit && (first.to !== start.ch || first.line !== start.line)) last = words.pop()
    target = last && { line: last.line, ch: last.to }
  } else {
    target = last && { line: last.line, ch: last.from }
  }
  // (Nothing to go back to — `b`/`ge` at the start of the note: the motion fails, so `db`/`cge` do nothing, as in Vim.)
  if (!target || (!forward && target.line === start.line && target.ch === start.ch)) return null
  return new CodeMirror.Pos(target.line, toCh(target.line, target.ch))
}
Vim.defineMotion('moveByWords', (cm, head, motionArgs) =>
  moveToWord(cm, head, motionArgs.repeat, Boolean(motionArgs.forward), Boolean(motionArgs.wordEnd), Boolean(motionArgs.bigWord)),
)

// ---- `r` ----
// Each character (not code unit) becomes the typed one; Normal `r` with a count past the end of the line does nothing, as
// in Vim. `r<CR>` replaces them with one line break.
Vim.defineAction('replace', (cm, actionArgs, vim) => {
  const view = cm.cm6
  const typed = actionArgs.selectedCharacter ?? ''
  if (!view || !typed) return
  const { doc } = view.state
  const each = (text: string) => text.replace(/[^\n]+/g, (run) => typed.repeat(charsOf(run).length))
  if (vim.visualMode) {
    const { ranges } = view.state.selection
    const block = vim.visualBlock
    const spaces = ' '.repeat(view.state.tabSize)
    const changes = ranges.map((r: SelectionRange) => {
      const text = doc.sliceString(r.from, r.to)
      return { from: r.from, to: r.to, insert: typed === '\n' ? '\n' : each(block ? text.replace(/\t/g, spaces) : text) }
    })
    const start = ranges[0].from
    Vim.exitVisualMode(cm, false)
    view.dispatch({ changes: typed === '\n' ? changes.slice(0, 1) : changes, selection: { anchor: start }, userEvent: 'input' })
    return
  }
  const head = view.state.selection.main.head
  const line = doc.lineAt(head)
  const chars = charsOf(line.text.slice(head - line.from))
  const count = Math.max(1, actionArgs.repeat ?? 1)
  if (count > chars.length) return
  const end = head + chars[count - 1].to
  if (typed === '\n') {
    view.dispatch({ changes: { from: head, to: end }, selection: { anchor: head } })
    return CodeMirror.commands.newlineAndIndent(cm)
  }
  const insert = typed.repeat(count)
  view.dispatch({ changes: { from: head, to: end, insert }, selection: { anchor: head + lastCharOffset(insert) }, userEvent: 'input' })
})

function beginInsertSession(cm: object, view: EditorView) {
  if (!sessionStart.has(cm)) sessionStart.set(cm, keyStart.get(cm) ?? startOf(view.state))
}

/** Spaces before each of `at` whose line is shorter there than column `col`, up to it. */
function padTo(view: EditorView, at: readonly number[], col: number) {
  const { doc } = view.state
  const changes = at.flatMap((pos) => {
    const width = col - (pos - doc.lineAt(pos).from)
    return width > 0 ? [{ from: pos, insert: ' '.repeat(width) }] : []
  })
  if (changes.length) view.dispatch({ changes, userEvent: 'input' })
  return changes.length > 0
}

function onModeChange(cm: object, view: EditorView, e: ModeEvent) {
  // (The dependency then puts the cursor where the insert goes — `A`, `o` — which moves this along, see `modeIndicator`.)
  if (e.mode === 'insert') insertStart.set(cm, { ...caretAt(view.state.doc, view.state.selection.main.head), typed: false })
  if (e.mode === 'insert' || e.mode === 'replace') return beginInsertSession(cm, view)
  // (A move not typed after leaves Vim's insert start as it was — the cursor stepping back for Esc too.)
  const started = insertStart.get(cm)
  insertStart.delete(cm)
  finishDeferredBlock(cm, view, started && { ...started, moved: undefined })
  const starts = insertStarts.get(cm)
  insertStarts.delete(cm)
  insertEnds.delete(cm)
  const start0 = sessionStart.get(cm)
  const doc0 = start0?.doc
  sessionStart.delete(cm)
  // A block `I`/`A` that inserted something leaves the cursor at the block's top-left (Vim), not on the last character
  // typed — so `j.` repeats it in the same column.
  const origin = blockOrigin.get(cm)
  blockOrigin.delete(cm)
  const inserted = origin && doc0 && !doc0.eq(view.state.doc) && e.mode === 'normal'
  // A block's `A` on a line that ends left of the block: Vim pads it out with spaces so the text lines up (`c    Q`).
  if (inserted && origin.pad !== undefined && starts) padTo(view, starts, origin.pad)
  if (inserted && origin.line < view.state.doc.lines) {
    const line = view.state.doc.line(origin.line + 1)
    view.dispatch({ selection: { anchor: line.from + Math.min(origin.ch, Math.max(0, line.length - 1)) } })
  }
  // After vim finishes the key (counted repeats, the cursor step back), before the next one.
  if (start0) queueMicrotask(() => getCM(view) === cm && mergeSince(view, start0.doc, start0.depth))
}

// ---- clipboard=unnamed: the unnamed register mirrors the system pasteboard ----
const registers = Vim.getRegisterController()
/** `"+` and `"*`: one register, the system clipboard — the last pasteboard text native handed over (`systemClipboard`,
 *  refreshed when the panel becomes key, before each key press, and once a second while it stays key) or the last text we put there (`setClipboard`). The dependency would read and
 *  write `"+` through navigator.clipboard, which WKWebView never answers (the editor stalls): it never sees `"+` (see
 *  `pushText` and `paste` below). */
const clipboard = registers.getRegister('+')
Vim.defineRegister('*', clipboard)
/** The clipboard holds our own ⌘⇧C copy of a note with images (its Markdown): null otherwise. */
let ownCopyText: string | null = null
/** The text we last put on the pasteboard (a yank, ⌘C/⌘X), and what the registers got for it — the same, or for a line
 *  copy the line with its newline: when the pasteboard hands it back, the registers keep their shape. */
let sentText: string | null = null
let sentRegister: string | null = null
/** A put of `reg` reads the system clipboard (as native last handed it over — refreshed before every key). */
const readsClipboard = (reg: VimRegister) => reg === registers.unnamedRegister || reg === clipboard
const isOwnCopy = (reg: VimRegister) =>
  (reg === registers.unnamedRegister || reg === clipboard) && ownCopyText !== null && reg.toString() === ownCopyText && !reg.blockwise

/** `src` (a register just written) is now the system clipboard too. `after`: native is still reading the pasteboard for
 *  something (a paste of our own copy), so the pasteboard write waits for it. `replaced`: it's what a Visual put of the
 *  clipboard's text replaced — native skips the write if the pasteboard moved on before the put saw it (see `readsClipboard`). */
function toClipboard(src: VimRegister, after: Promise<unknown> = Promise.resolve(), replaced = false) {
  ownCopyText = null
  const text = src.toString()
  sentText = sentRegister = text
  if (src !== clipboard) clipboard.setText(text, src.linewise, src.blockwise)
  void after
    .catch(() => {})
    .then(() => send(replaced ? { type: 'setClipboard', text, replaced } : { type: 'setClipboard', text }))
    .catch(() => {})
}

// `p`/`P` of our own copy: its image references are relative to the folder it was copied from, so — like ⌘V — native
// writes the images into this folder's assets/ first (rewriting references where a name is taken), then the text goes in
// where vim would have put it (over the selection, in Visual). Async: the spot is reserved now and mapped through anything
// done meanwhile (see `reservePaste`); the paste is its own undo step.
let pasteSeq = 0
function pasteOwnCopy(cm: Parameters<ActionFn>[0], view: EditorView, actionArgs: Parameters<ActionFn>[1], vim: Parameters<ActionFn>[2], reg: VimRegister, end = false) {
  const text = reg.toString()
  const after = Boolean(actionArgs.after)
  const repeat = Math.max(1, actionArgs.repeat ?? 1)
  const lines = (t: string) => (t.endsWith('\n') ? t : t + '\n').repeat(repeat)
  const token = `vim-paste-${++pasteSeq}-${Date.now()}`
  // Native may paste other text than the register's (the clipboard changed since): it goes in as that text's shape —
  // linewise when it ends in a newline — so both placements are reserved (see `reservePaste`).
  const reserve = (placeAs: (linewise: boolean) => Placement) =>
    reservePaste(view, token, placeAs(reg.linewise), placeAs(!reg.linewise))
  if (vim.visualMode) {
    // As the dependency's Visual paste: linewise text replaces whole lines in Visual Line (in charwise Visual it goes in on
    // lines of its own); in Visual Block the block is deleted and the text goes in at its top-left corner.
    const { ranges } = view.state.selection
    const first = ranges[0]
    const [lineMode, block] = [vim.visualLine, vim.visualBlock]
    const replaced = cm.getSelection()
    const to = block ? first.to : ranges[ranges.length - 1].to
    const { doc } = view.state
    // `gp`/`gP`: just after the text — whole lines (Visual Line, or a linewise register) at the start of the line below
    // them (or, with none, of the last one); else past the text, on its last character when the line ends there.
    const endCaret = (from: number, t: string) =>
      lineMode || t.endsWith('\n')
        ? t.endsWith('\n') ? from + t.length : to < doc.length ? from + t.length + 1 : from + t.lastIndexOf('\n') + 1
        : to === doc.lineAt(to).to ? from + lastCharOffset(t) : from + t.length
    const placeAs = (linewise: boolean) => ({
      at: first.from,
      to,
      extra: block ? ranges.slice(1).filter((r) => !r.empty).map(({ from, to }) => ({ from, to })) : undefined,
      linewise,
      shape: (t: string) => (!linewise ? t.repeat(repeat) : lineMode ? lines(t).slice(0, -1) : '\n' + lines(t).slice(0, -1) + '\n'),
      // (`p`/`P`: whole lines on the first one's first non-blank, other text over more than a line at its start, else on
      // its last character — as Vim.)
      caret: (from: number, t: string) => {
        if (end) return endCaret(from, t)
        if (lineMode || linewise) {
          const first = !lineMode && t.startsWith('\n') ? 1 : 0
          return from + first + /^[ \t]*/.exec(t.slice(first))![0].length
        }
        return block || t.includes('\n') ? from : from + lastCharOffset(t)
      },
    })
    Vim.exitVisualMode(cm, false)
    view.dispatch({ selection: { anchor: first.from } })
    reserve(placeAs)
    const sent = send({ type: 'pasteOwnCopy', token, text })
    sent.catch(() => cancelPaste(token))
    // Visual `p` (and `gp`, `gP`) leaves the replaced text in the unnamed register (and so on the clipboard) — once native
    // has taken the copy being pasted off the pasteboard. Visual `P` leaves the register alone.
    if (after || end) {
      registers.unnamedRegister.setText(lineMode ? replaced + '\n' : replaced, lineMode, block)
      toClipboard(registers.unnamedRegister, sent, true)
    }
    return
  }
  const { doc } = view.state
  const head = view.state.selection.main.head
  const line = doc.lineAt(head)
  const placeAs = (linewise: boolean) => {
    // `]p` / `[p`: whole lines take the current line's indent (the rest keep theirs relative to the first).
    const indent = actionArgs.matchIndent && linewise ? /^[ \t]*/.exec(line.text)![0] : null
    const fix = (t: string) => (indent === null ? t : reindent(t, indent, view.state.tabSize))
    return linewise
      ? {
          // Whole lines below (`p`) or above (`P`) the current one; the caret on the first one's first non-blank.
          at: after ? line.to : line.from,
          linewise,
          shape: (t: string) => (after ? '\n' + lines(fix(t)).slice(0, -1) : lines(fix(t))),
          caret: (from: number, t: string) => {
            // (`gp`/`gP`: the start of the line below them — or, with none, of the last one.)
            if (end) return !after ? from + t.length : from < view.state.doc.length ? from + t.length + 1 : from + t.lastIndexOf('\n') + 1
            const start = after ? from + 1 : from
            return start + /^[ \t]*/.exec(t.slice(start - from))![0].length
          },
        }
      : {
          // After (`p`) or at (`P`) the cursor's character; the caret on the last pasted character (start, if multi-line).
          at: after ? Math.min(charEnd(doc, head), line.to) : head,
          linewise,
          shape: (t: string) => t.repeat(repeat),
          // (`gp`/`gP`: after it — on its last character at the end of a line.)
          caret: (from: number, t: string) =>
            end ? (from < view.state.doc.lineAt(from).to ? from + t.length : from + lastCharOffset(t)) : t.includes('\n') ? from : from + lastCharOffset(t),
        }
  }
  reserve(placeAs)
  void send({ type: 'pasteOwnCopy', token, text }).catch(() => cancelPaste(token))
}

/** `]p` text: each line's leading whitespace re-based from the first line's to `indent` (as Vim; blank lines left alone). */
function reindent(text: string, indent: string, tabSize: number) {
  const width = (ws: string) => [...ws].reduce((n, c) => n + (c === '\t' ? tabSize : 1), 0)
  const base = width(/^[ \t]*/.exec(text)![0])
  const target = width(indent)
  return text.replace(/^[ \t]*(?=[^\n])/gm, (ws) => ' '.repeat(Math.max(0, target + width(ws) - base)))
}

// ---- a blockwise register put over a Visual selection ----
// The dependency's version uses the text's length as the block's height and corrupts the lines below. As Vim: the selection
// is deleted (charwise, whole lines or the block), then the block goes in where the cursor lands — at the selection's
// top-left like `P` (in Visual Line, as whole lines). Visual `p` leaves what was deleted in the register; `P` doesn't.
// One transaction, one undo step. A one-line charwise register over a Visual block goes in on every line of it (Vim 9).

/** Vim's blockwise put of `rows` at column `col` from line `lineNo`, `count` copies side by side: short lines padded out to
 *  the column, lines added past the end, each copy padded to the block's width when text follows it. */
function blockPut(doc: Text, lineNo: number, col: number, rows: string[], count: number) {
  const width = Math.max(...rows.map((r) => r.length))
  const copies = (row: string, short: boolean) =>
    Array.from({ length: count }, (_, j) => row + (j < count - 1 || !short ? ' '.repeat(width - row.length) : '')).join('')
  const changes: { from: number; insert: string }[] = []
  let added = ''
  rows.forEach((row, i) => {
    if (lineNo + i > doc.lines) return void (added += '\n' + ' '.repeat(col) + copies(row, true))
    const line = doc.line(lineNo + i)
    const at = Math.min(col, line.length)
    changes.push({ from: line.from + at, insert: ' '.repeat(col - at) + copies(row, line.length <= col) })
  })
  if (added) changes.push({ from: doc.length, insert: added })
  return changes
}

function putBlockOverVisual(cm: Parameters<ActionFn>[0], view: EditorView, actionArgs: Parameters<ActionFn>[1], vim: Parameters<ActionFn>[2], reg: VimRegister) {
  const { doc, selection } = view.state
  const { ranges } = selection
  const text = reg.toString()
  // (A charwise register here is one line over a Visual block: the cursor ends on its last character, as in Vim.)
  const charwise = !reg.blockwise
  const rows = charwise ? ranges.map(() => text) : text.split('\n')
  const count = Math.max(1, actionArgs.repeat ?? 1)
  const [from, to] = [ranges[0].from, ranges[ranges.length - 1].to]
  let change: ChangeSet
  let caret: number
  let deleted: [text: string, linewise: boolean, blockwise: boolean]
  if (vim.visualLine) {
    const [first, last] = [doc.lineAt(from), doc.lineAt(to)]
    const insert = Array.from({ length: count }, () => rows.join('\n')).join('\n')
    change = ChangeSet.of({ from: first.from, to: last.to, insert }, doc.length)
    caret = first.from + /^[ \t]*/.exec(insert)![0].length
    deleted = [doc.sliceString(first.from, last.to) + '\n', true, false]
  } else {
    const cuts = vim.visualBlock ? ranges.map((r) => ({ from: r.from, to: r.to })) : [{ from, to }]
    const cut = ChangeSet.of(cuts, doc.length)
    const after = cut.apply(doc)
    const top = doc.lineAt(from)
    const col = from - top.from
    change = cut.compose(ChangeSet.of(blockPut(after, top.number, col, rows, count), after.length))
    caret = after.line(top.number).from + col + (charwise ? lastCharOffset(text.repeat(count)) : 0)
    deleted = [cuts.map((r) => doc.sliceString(r.from, r.to)).join('\n'), false, Boolean(vim.visualBlock)]
  }
  Vim.exitVisualMode(cm, false)
  view.dispatch({ changes: change, selection: { anchor: Math.min(caret, change.newLength) }, scrollIntoView: true, userEvent: 'input.paste' })
  if (keepsRegister(actionArgs)) return
  registers.unnamedRegister.setText(...deleted)
  toClipboard(registers.unnamedRegister, undefined, readsClipboard(reg))
}

/** Normal `p`/`P` of a block: after (at) the cursor's character, `count` copies side by side, short lines padded (the
 *  dependency repeats the text before splitting it into rows, so copies stair-step into the lines below). The cursor on
 *  the block's top-left. */
function putBlockAtCursor(view: EditorView, actionArgs: Parameters<ActionFn>[1], reg: VimRegister) {
  const { doc } = view.state
  const head = view.state.selection.main.head
  const line = doc.lineAt(head)
  const at = actionArgs.after && head < line.to ? charEnd(doc, head) : head
  const changes = blockPut(doc, line.number, at - line.from, reg.toString().split('\n'), Math.max(1, actionArgs.repeat ?? 1))
  view.dispatch({ changes, selection: { anchor: at }, scrollIntoView: true, userEvent: 'input.paste' })
}

/** Whole lines put over a Visual block (Vim's `nv_put`): the block is deleted, then the lines go in below the cursor's line
 *  (`p`, the block's end where Visual ended) or above the block's top line (`P` — below it when the cursor couldn't stay on
 *  the block's column, the line now too short). The cursor on the first put line's first non-blank. `p` leaves the
 *  block in the register. `.` repeats the block delete (see `recordPutRedo`). */
function putLinesOverBlock(cm: Parameters<ActionFn>[0], view: EditorView, actionArgs: Parameters<ActionFn>[1], vim: Parameters<ActionFn>[2], reg: VimRegister) {
  const { doc, selection } = view.state
  const { ranges } = selection
  const text = reg.toString()
  const lines = Array.from({ length: Math.max(1, actionArgs.repeat ?? 1) }, () => (text.endsWith('\n') ? text.slice(0, -1) : text)).join('\n')
  const cuts = ranges.map((r) => ({ from: r.from, to: r.to }))
  const cut = ChangeSet.of(cuts, doc.length)
  const after = cut.apply(doc)
  const top = doc.lineAt(ranges[0].from).number
  const left = Math.min(vim.sel.anchor.ch, vim.sel.head.ch)
  const below = actionArgs.after || Math.max(0, after.line(top).length - 1) < left
  const at = after.line(actionArgs.after ? vim.sel.head.line + 1 : top)
  const put = below ? { from: at.to, insert: '\n' + lines } : { from: at.from, insert: lines + '\n' }
  const change = cut.compose(ChangeSet.of(put, after.length))
  const caret = (below ? at.to + 1 : at.from) + /^[ \t]*/.exec(lines)![0].length
  const deleted = cuts.map((r) => doc.sliceString(r.from, r.to)).join('\n')
  Vim.exitVisualMode(cm, false)
  view.dispatch({ changes: change, selection: { anchor: caret }, scrollIntoView: true, userEvent: 'input.paste' })
  if (keepsRegister(actionArgs)) return
  registers.unnamedRegister.setText(deleted, false, true)
  toClipboard(registers.unnamedRegister, undefined, readsClipboard(reg))
}
const putsLinesOverBlock = (vim: Parameters<ActionFn>[2], reg: VimRegister) => Boolean(vim.visualBlock && reg.linewise && !reg.blockwise && reg.toString())

/** `reg` goes in as a block over the Visual selection: blockwise, or one charwise line over a Visual block. */
const putsAsBlock = (vim: Parameters<ActionFn>[2], reg: VimRegister) => {
  const text = reg.toString()
  return Boolean(vim.visualMode && text && (reg.blockwise || (vim.visualBlock && !reg.linewise && !text.includes('\n'))))
}

// ---- `.` after a Visual put ----
// Vim's redo of a Visual `p`/`P` is the Visual delete alone (`nv_put` records the delete, not the put): the same extent
// from the cursor — as many characters on one line (running past its end takes the line break), as many lines (the last
// one to the same column), or a block as wide and tall — deleted into the unnamed register (Visual `P`'s: the black hole).
type PutRedo = { mode: 'char' | 'line' | 'block'; lines: number; chars: number; lastCh: number; keep: boolean }
let putRedo: PutRedo | null = null
const redoPutCommand = { keys: '', type: 'action' as const, action: 'nbmRedoVisualPut' }

/** `keep`: Visual `P`, whose redo deletes into the black hole (the registers stay, as Vim). */
function recordPutRedo(vim: Parameters<ActionFn>[2], keep: boolean) {
  const { anchor, head } = vim.sel
  const end = anchor.line > head.line || (anchor.line === head.line && anchor.ch > head.ch) ? anchor : head
  putRedo = { mode: vim.visualLine ? 'line' : vim.visualBlock ? 'block' : 'char', lines: Math.abs(head.line - anchor.line), chars: Math.abs(head.ch - anchor.ch), lastCh: end.ch, keep }
  vim.lastEditInputState = new (vim.inputState.constructor as new () => typeof vim.inputState)()
  vim.lastEditActionCommand = redoPutCommand
  Vim.getVimGlobalState_().macroModeState.lastInsertModeChanges.visualBlock = 0
}

Vim.defineAction('nbmRedoVisualPut', (cm) => {
  const view = cm.cm6
  const r = putRedo
  if (!view || !r) return
  const { doc } = view.state
  const head = view.state.selection.main.head
  const line = doc.lineAt(head)
  const col = head - line.from
  const last = doc.line(Math.min(doc.lines, line.number + r.lines))
  // Through column `end` of `l` (exclusive), or its line break too when that runs past the end of it.
  const through = (l: typeof line, end: number) => (end <= l.length ? l.from + end : l.number < doc.lines ? l.to + 1 : l.to)
  let ranges: { from: number; to: number }[]
  if (r.mode === 'line') {
    ranges = [last.number < doc.lines ? { from: line.from, to: last.to + 1 } : { from: Math.max(0, line.from - 1), to: last.to }]
  } else if (r.mode === 'block') {
    ranges = []
    for (let n = line.number; n <= last.number; n++) {
      const l = doc.line(n)
      ranges.push({ from: l.from + Math.min(col, l.length), to: l.from + Math.min(col + r.chars + 1, l.length) })
    }
  } else ranges = [{ from: head, to: r.lines ? through(last, r.lastCh + 1) : through(line, col + r.chars + 1) }]
  const text = r.mode === 'line' ? doc.sliceString(line.from, last.to) + '\n' : ranges.map((x) => doc.sliceString(x.from, x.to)).join('\n')
  const changes = ChangeSet.of(ranges, doc.length)
  const after = changes.apply(doc)
  let caret = changes.mapPos(head, -1)
  const at = after.lineAt(Math.min(caret, after.length))
  if (r.mode === 'line') caret = at.from + /^[ \t]*/.exec(at.text)![0].length
  else if (caret >= at.to && at.length) caret = at.to - 1
  if (!r.keep) registers.pushText(undefined, 'delete', text, r.mode === 'line', r.mode === 'block')
  view.dispatch({ changes, selection: { anchor: caret }, scrollIntoView: true, userEvent: 'delete' })
})

/** A Visual put of an empty register (`"zp`, `"zgp` of a never-written `z`): Vim deletes the selection — into the unnamed
 *  register (and the clipboard), or for `P` into the black hole — and `.` repeats that delete. As Visual `d` (`"_d`). */
function deleteForEmptyPut(cm: Parameters<ActionFn>[0], vim: Parameters<ActionFn>[2], keep: boolean) {
  if (keep) vim.inputState.registerName = '_'
  Vim.handleKey(cm, 'd', 'mapping')
}

Vim.defineAction('nbmPaste', function (this: VimActions, cm, actionArgs, vim) {
  const view = cm.cm6
  const reg = registers.getRegister(actionArgs.registerName)
  if (vim.visualMode && !reg.toString()) return deleteForEmptyPut(cm, vim, keepsRegister(actionArgs))
  if (vim.visualMode) recordPutRedo(vim, keepsRegister(actionArgs))
  if (view && isOwnCopy(reg)) return pasteOwnCopy(cm, view, actionArgs, vim, reg)
  putRegister(this, cm, actionArgs, vim, reg)
})

/** Visual `P` keeps the unnamed register; `p`, `gp` and `gP` leave the replaced text there (Vim keeps it for `P` alone). */
const keepsRegister = (actionArgs: Parameters<ActionFn>[1]) => !actionArgs.after && !puttingToEnd

/** The changes `put` makes (also counted in any tracking around it). */
function trackChanges(view: EditorView, put: () => void) {
  const outer = putChanges
  let mine = (putChanges = ChangeSet.empty(view.state.doc.length))
  try {
    put()
  } finally {
    mine = putChanges
    putChanges = outer && outer.compose(mine)
  }
  return mine
}

/** `p`/`P` of a register that isn't our own copy (see `pasteOwnCopy`), in Normal or over a Visual selection. */
function putRegister(actions: VimActions, cm: Parameters<ActionFn>[0], actionArgs: Parameters<ActionFn>[1], vim: Parameters<ActionFn>[2], reg: VimRegister) {
  const view = cm.cm6
  if (!view) return actions.paste(cm, actionArgs, vim)
  if (putsAsBlock(vim, reg)) return putBlockOverVisual(cm, view, actionArgs, vim, reg)
  if (putsLinesOverBlock(vim, reg)) return putLinesOverBlock(cm, view, actionArgs, vim, reg)
  const [visual, lineMode, block] = [vim.visualMode, vim.visualLine, vim.visualBlock]
  const lineShaped = lineMode || (reg.linewise && !reg.blockwise)
  const multiLine = reg.toString().includes('\n')
  const u = registers.unnamedRegister
  const kept = [u.toString(), u.linewise, u.blockwise] as const
  const changes = trackChanges(view, () => actions.paste(cm, actionArgs, vim))
  if (!visual || vim.visualMode) return // (an empty register pastes nothing)
  // The cursor as Vim's (the dependency leaves it at the end): whole lines — Visual Line puts any register as lines — on
  // the first one's first non-blank; other text over more than a line at its start.
  let start = -1
  let split = false
  changes.iterChanges((_fromA, _toA, fromB, _toB, inserted) => {
    if (start >= 0 || !inserted.length) return
    start = fromB
    split = inserted.sliceString(0, 1) === '\n'
  })
  if (start >= 0 && (lineShaped || multiLine)) {
    const line = view.state.doc.lineAt(lineShaped && split ? start + 1 : start)
    view.dispatch({ selection: { anchor: lineShaped ? line.from + /^[ \t]*/.exec(line.text)![0].length : start } })
  }
  // Visual `p` put the replaced text in the unnamed register (whole lines from Visual Line, a block from Visual Block, as
  // Vim): the clipboard follows. Visual `P` leaves it alone (Vim 9).
  if (keepsRegister(actionArgs)) return u.setText(...kept)
  if (lineMode) u.setText(u.toString() + '\n', true)
  else if (block) u.setText(u.toString(), false, true)
  toClipboard(u, undefined, readsClipboard(reg))
}
for (const [keys, after] of [['p', true], ['P', false]] as const) {
  for (const context of ['normal', 'visual']) Vim.mapCommand(keys, 'action', 'nbmPaste', { after, isEdit: true }, { isEdit: true, context })
}
// `.` in Visual mode does nothing in Vim (the selection stays): the dependency replays the last change over it.
Vim.defineAction('nbmVisualDot', () => {})
Vim.mapCommand('.', 'action', 'nbmVisualDot', {}, { context: 'visual' })
// ---- Visual `J` / `gJ` ----
// The highlighted lines, at least two (the dependency joins through the line its selection ends on, which is the next one
// when Visual ends on a line break — see `setSelections` — and joins nothing on one line).
Vim.defineAction('nbmJoinVisual', function (this: VimActions, cm, actionArgs, vim) {
  const [a, b] = [vim.sel.anchor.line, vim.sel.head.line]
  const top = Math.min(a, b)
  cm.setSelection(new CodeMirror.Pos(top, 0), new CodeMirror.Pos(Math.min(cm.lastLine(), Math.max(a, b, top + 1)), 0))
  return this.joinLines(cm, actionArgs, vim)
})
for (const [keys, keepSpaces] of [['J', false], ['gJ', true]] as const) {
  Vim.mapCommand(keys, 'action', 'nbmJoinVisual', { keepSpaces }, { isEdit: true, context: 'visual' })
}

// ---- `gp` / `gP` ----
// `p` / `P` with the cursor just after what went in (the dependency has no mapping), in Normal and over a Visual selection
// (which is replaced as by `p`/`P`): past charwise text (on its last character at the end of a line), at the start of the
// line below whole lines (Visual Line puts any register as lines), right of a block on its last line. A one-line charwise
// register over a Visual block goes in on every line of it; the cursor ends after it on the first one (as Vim).
/** While a put is tracked (see `trackChanges`): its changes so far. */
let putChanges: ChangeSet | null = null
/** While a `gp`/`gP` puts. */
let puttingToEnd = false
Vim.defineAction('nbmPasteEnd', function (this: VimActions, cm, actionArgs, vim) {
  const view = cm.cm6
  const reg = registers.getRegister(actionArgs.registerName)
  if (view && vim.visualMode && !reg.toString()) return deleteForEmptyPut(cm, vim, false)
  if (!view || !reg.toString()) return
  // (Read before the put: a Visual put can leave other text in `reg`.)
  const lineShaped = vim.visualLine || (reg.linewise && !reg.blockwise)
  const perLine = Boolean(vim.visualBlock && !reg.linewise && !reg.blockwise && !reg.toString().includes('\n'))
  if (vim.visualMode) recordPutRedo(vim, false)
  if (isOwnCopy(reg)) return pasteOwnCopy(cm, view, actionArgs, vim, reg, true)
  puttingToEnd = true
  let changes: ChangeSet
  try {
    changes = trackChanges(view, () => putRegister(this, cm, actionArgs, vim, reg))
  } finally {
    puttingToEnd = false
  }
  // The end of the text that went in (the last piece, or the first line's for a line over a block) and whether it
  // ended in a line break.
  let end = -1
  let endsLine = false
  changes.iterChanges((_fromA, _toA, _fromB, toB, inserted) => {
    if (!inserted.length || (perLine && end >= 0) || toB < end) return
    end = toB
    endsLine = inserted.sliceString(inserted.length - 1) === '\n'
  })
  if (end < 0) return
  const { doc } = view.state
  const line = doc.lineAt(end)
  const caret = !lineShaped ? onCharacter(doc, end) : endsLine ? end : line.number < doc.lines ? line.to + 1 : line.from
  view.dispatch({ selection: { anchor: caret } })
})
for (const [keys, after] of [['gp', true], ['gP', false]] as const) {
  for (const context of ['normal', 'visual']) Vim.mapCommand(keys, 'action', 'nbmPasteEnd', { after, isEdit: true }, { isEdit: true, context })
}

// Every paste (`p`, `]p`, `:put`) reads its register here, never through navigator.clipboard (see `clipboard`). `]p`/`[p`
// of our own copy bring its images along too.
Vim.defineAction('paste', function (this: VimActions, cm, actionArgs, vim) {
  const view = cm.cm6
  const register = registers.getRegister(actionArgs.registerName)
  if (view && putsAsBlock(vim, register)) return putBlockOverVisual(cm, view, actionArgs, vim, register)
  if (view && putsLinesOverBlock(vim, register)) return putLinesOverBlock(cm, view, actionArgs, vim, register)
  if (view && !vim.visualMode && register.blockwise && register.toString()) return putBlockAtCursor(view, actionArgs, register)
  if (view && actionArgs.matchIndent && isOwnCopy(register)) return pasteOwnCopy(cm, view, actionArgs, vim, register)
  const text = register.toString()
  // `p` on a character longer than a code unit (`🙂`, `🧑‍💻`): the dependency puts the text one code unit on — inside it —
  // and the caret a unit short of the last pasted character. As Vim: after the character, the caret on the last one pasted.
  // (From its last code point the dependency's step lands at its end — or inside that code point's pair, which
  // `surrogateGuard` moves past.)
  const head = view?.state.selection.main.head ?? 0
  const inLine = Boolean(view && text && !vim.visualMode && !register.linewise && !register.blockwise)
  const charwise = inLine && Boolean(actionArgs.after)
  const end = view && charwise ? charEnd(view.state.doc, head) : head + 1
  const pasted = text.repeat(Math.max(1, actionArgs.repeat ?? 1))
  const wide = view !== undefined && end > head + 1
  if (wide) {
    const last = end - 1 - (/[\udc00-\udfff]/.test(view.state.sliceDoc(end - 1, end)) ? 1 : 0)
    if (last > head) view.dispatch({ selection: { anchor: last } })
  }
  this.continuePaste(cm, actionArgs, vim, text, register)
  // `P`: on the last character pasted (the dependency puts the cursor after it).
  if (view && inLine && !actionArgs.after && !pasted.includes('\n')) return view.dispatch({ selection: { anchor: head + lastCharOffset(pasted) } })
  if (!wide) return
  view.dispatch({ selection: { anchor: end + (pasted.includes('\n') ? 0 : lastCharOffset(pasted)) } })
})
// ---- linewise deletes through the last line ----
// As Vim: they take the line break *before* them (the dependency does only for `dd` of the last line — `2dd`/`Vjd` over
// the last two left an empty line behind), and the register holds the lines themselves ("three\n", not "\nthree"). Only
// that separator is dropped from the register: a deleted range that starts with a blank line keeps it. Lines through the
// last one end in a line break of their own — an empty last line too ("b\n" + "\n").
Vim.defineOperator('delete', (cm, args, ranges) => {
  const vim = cm.state.vim
  let text: string
  let head: Pos
  if (vim?.visualBlock) {
    text = cm.getSelection()
    cm.replaceSelections(ranges.map(() => ''))
    const [a, b] = [ranges[0].anchor, ranges[0].head]
    head = a.line < b.line || (a.line === b.line && a.ch <= b.ch) ? a : b
  } else {
    let from = ranges[0].anchor
    const to = ranges[0].head
    const throughEnd = Boolean(args.linewise) && to.line > cm.lastLine()
    const separator = throughEnd && from.line > cm.firstLine()
    if (separator) from = new CodeMirror.Pos(from.line - 1, cm.getLine(from.line - 1).length)
    text = cm.getRange(from, to)
    cm.replaceRange('', from, to)
    if (separator) text = text.slice(1)
    if (throughEnd) text += '\n'
    head = args.linewise ? new CodeMirror.Pos(from.line, /^[ \t]*/.exec(cm.getLine(from.line))![0].length) : from
  }
  registers.pushText(args.registerName, 'delete', text, args.linewise, Boolean(vim?.visualBlock))
  // On the content: a character, or the line break in Visual (the dependency's `clipCursorToContent`).
  const line = Math.min(Math.max(cm.firstLine(), head.line), cm.lastLine())
  const max = cm.getLine(line).length - (vim?.visualMode || vim?.insertMode ? 0 : 1)
  return new CodeMirror.Pos(line, Math.max(0, Math.min(head.ch, max)))
})

// ---- linewise yanks through the last line ----
// Lines yanked through the last one: that one's line break too, even when it's empty. Their range stops at the end of
// the document — as does the range of the lines before an empty last line, which already ends in their line break
// (`2yy` of "first\nlast\n" is "first\nlast\n", `3yy` "first\nlast\n\n"). Which lines were yanked is in the operator's
// range: through the last one, it ends past it (as `delete` above). The dependency's yank otherwise.
let yankedThroughEnd = false
const posBefore = (a: Pos, b: Pos) => a.line < b.line || (a.line === b.line && a.ch < b.ch)
Vim.defineOperator('yank', (cm, args, ranges, oldAnchor) => {
  const vim = cm.state.vim
  const [range] = ranges
  const text = cm.getSelection()
  const endPos = vim?.visualMode ? [vim.sel.anchor, vim.sel.head, range.head, range.anchor].reduce((a, b) => (posBefore(b, a) ? b : a)) : oldAnchor
  yankedThroughEnd = Boolean(args.linewise) && !vim?.visualBlock && Math.max(range.anchor.line, range.head.line) > cm.lastLine()
  try {
    registers.pushText(args.registerName, 'yank', text, args.linewise, vim?.visualBlock)
  } finally {
    yankedThroughEnd = false
  }
  const message = document.createElement('div')
  message.className = 'cm-vim-message'
  message.textContent = `${Math.abs(cm.getCursor('end').line - cm.getCursor('start').line) || 1} lines yanked${args.registerName ? ` into "${args.registerName}` : ''}`
  cm.openNotification(message, { bottom: true, duration: 1500 })
  return endPos
})

const pushText = registers.pushText.bind(registers)
registers.pushText = (name, operator, text, linewise, blockwise) => {
  if (operator === 'yank' && yankedThroughEnd) text += '\n'
  if (linewise && !text.endsWith('\n')) text += '\n'
  const system = name === '+' || name === '*'
  // `"+` as `"*` (the same register): the dependency hands `"+` writes to navigator.clipboard as well.
  pushText(system ? '*' : name, operator, text, linewise, blockwise)
  if (operator === 'yank' && keyView) yankStart = { from: keyView.state.selection.main.from, linewise: Boolean(linewise) }
  // Named registers ("a…"z) stay private, like Vim; everything else lands on the system clipboard.
  if (name === '_' || (name && name !== '"' && !system)) return
  toClipboard(system ? clipboard : registers.unnamedRegister)
}

/** The system pasteboard changed (copied in another app): `p` and `"+p` should paste it. `ownCopy`: it's our own ⌘⇧C copy
 *  of a note with images (`text` = its Markdown), which they paste the way ⌘V does — see `pasteOwnCopy`. */
export function setVimClipboard(text: string, ownCopy = false) {
  // Emptied (an empty string copied): `"+` pastes nothing now. The unnamed register keeps the last yank.
  if (!text) return clipboard.setText('')
  ownCopyText = ownCopy ? text : null
  // Our own yank coming back keeps its shape (linewise, blockwise); anything else — a ⌘⇧C copy even of the same text —
  // is plain text, linewise when it ends in a newline (like Vim with clipboard=unnamed).
  const echo = !ownCopy && text === sentText
  for (const reg of [registers.unnamedRegister, clipboard]) {
    if (echo && reg.toString() === sentRegister) continue
    reg.setText(text, text.endsWith('\n'))
  }
}

/** ⌘C / ⌘X in the editor, as MacVim's `"+y` / `"+x`: `p` pastes what they put on the clipboard (clipboard=unnamed), in
 *  its shape. CodeMirror copies the selection, or with none the cursor's lines (which `p` puts as lines); Visual Line takes
 *  whole lines (⌘X deletes them, line breaks and all) and Visual Block a block. Native only hands the pasteboard over when
 *  the panel next becomes key. */
const copyToRegister = EditorView.domEventHandlers({
  copy: (e, view) => clip(e, view, false),
  cut: (e, view) => clip(e, view, true),
})

function clip(e: ClipboardEvent, view: EditorView, cut: boolean) {
  const cm = getCM(view)
  const vim = cm?.state.vim
  const { state } = view
  const { doc, lineBreak } = state
  const { ranges } = state.selection
  if (!cm || !vim?.visualMode || !(vim.visualLine || vim.visualBlock) || !e.clipboardData) {
    const lines = ranges.every((r) => r.empty)
    const text = copiedText(state)
    if (!text && !lines) return false
    copied(lines ? text + lineBreak : text, lines, false, text)
    // Once CodeMirror has cut it: out of Visual onto one cursor where it was (a Visual block leaves one per line), on a
    // character — after whole lines, the next one's first non-blank (like `dd`).
    if (cut && !vim?.insertMode) queueMicrotask(() => getCM(view) === cm && cm && toCutStart(cm, view, lines))
    return false
  }
  const lineMode = Boolean(vim.visualLine)
  const [first, last] = [doc.lineAt(ranges[0].from), doc.lineAt(ranges[ranges.length - 1].to)]
  const text = lineMode ? doc.sliceString(first.from, last.to) + lineBreak : ranges.map((r) => doc.sliceString(r.from, r.to)).join(lineBreak)
  e.clipboardData.clearData()
  e.clipboardData.setData('text/plain', text)
  copied(text, lineMode, !lineMode, text)
  if (!cut || state.readOnly) return true
  const cuts = !lineMode
    ? ranges.filter((r) => !r.empty)
    : last.number < doc.lines
      ? [{ from: first.from, to: last.to + 1 }]
      : [{ from: Math.max(0, first.from - 1), to: last.to }]
  const changes = ChangeSet.of(cuts, doc.length)
  const after = changes.apply(doc)
  const line = after.lineAt(changes.mapPos(ranges[0].from, -1))
  const caret = lineMode ? line.from + /^[ \t]*/.exec(line.text)![0].length : changes.mapPos(ranges[0].from, -1)
  Vim.exitVisualMode(cm as Parameters<typeof Vim.exitVisualMode>[0], false)
  view.dispatch({ changes, selection: { anchor: onCharacter(after, caret) }, scrollIntoView: true, userEvent: 'delete.cut' })
  return true
}

function toCutStart(cm: NonNullable<ReturnType<typeof getCM>>, view: EditorView, lines: boolean) {
  const vim = cm.state.vim
  if (!vim || vim.insertMode) return
  if (vim.visualMode) Vim.exitVisualMode(cm as Parameters<typeof Vim.exitVisualMode>[0], false)
  const { doc } = view.state
  let pos = view.state.selection.ranges[0].head
  if (lines) pos = doc.lineAt(pos).from + /^[ \t]*/.exec(doc.lineAt(pos).text)![0].length
  view.dispatch({ selection: { anchor: onCharacter(doc, pos) } })
}

/** ⌘C / ⌘X put `pasteboard` on the clipboard: the unnamed register (and `"+`) hold `text` as that shape. */
function copied(text: string, linewise: boolean, blockwise: boolean, pasteboard: string) {
  ownCopyText = null
  sentText = pasteboard
  sentRegister = text
  for (const reg of [registers.unnamedRegister, clipboard]) reg.setText(text, linewise, blockwise)
}

function copiedText(state: EditorState) {
  const selected = state.selection.ranges.filter((r) => !r.empty).map((r) => state.sliceDoc(r.from, r.to))
  if (selected.length) return selected.join(state.lineBreak)
  const lines = [...new Set(state.selection.ranges.map((r) => state.doc.lineAt(r.from).number))]
  return lines.map((n) => state.doc.line(n).text).join(state.lineBreak)
}

/** A ⌘⇧C copy is about to replace the pasteboard: what comes back is no longer the echo of a yank. */
export function noteCopiedToClipboard() {
  sentText = null
}

export function vimState(view: EditorView) {
  return getCM(view)?.state.vim ?? null
}

/** True when Esc should be left to vim: leave insert/visual or cancel a pending operator/count. A finished
 *  search's highlighting doesn't count — Esc in Normal hides (and the highlight goes with it). */
export function vimWantsEscape(view: EditorView) {
  const s = vimState(view)
  if (!s) return false
  return Boolean(s.insertMode || s.visualMode || s.status)
}

/** Drop the `/` search highlight (like :nohlsearch). */
export function clearVimSearch(view: EditorView) {
  const cm = getCM(view)
  if (cm && vimState(view)?.searchState_?.getOverlay()) Vim.handleEx(cm as Parameters<typeof Vim.handleEx>[0], 'nohlsearch')
}

/** Put vim in plain Normal mode (note load): out of insert/visual, no pending count/operator/register. */
export function enterNormal(view: EditorView) {
  const cm = getCM(view)
  const s = cm?.state.vim
  if (!cm || !s) return
  if (s.insertMode) Vim.exitInsertMode(cm as Parameters<typeof Vim.exitInsertMode>[0], true)
  else if (s.visualMode) Vim.exitVisualMode(cm as Parameters<typeof Vim.exitVisualMode>[0])
  // A half-typed command (`g`, `2d`, `"a`) must not complete with keys typed in the next note.
  if (s.inputState.keyBuffer.length || s.inputState.operator || s.inputState.motion || s.inputState.registerName || s.inputState.prefixRepeat.length || s.inputState.motionRepeat.length) {
    Vim.handleKey(cm as Parameters<typeof Vim.handleKey>[0], '<Esc>', 'mapping')
  }
  s.status = ''
  s.expectLiteralNext = false
  // Normal mode's cursor is on a character, never past the end of a line (a first open puts the caret at the very end).
  const { selection, doc } = view.state
  const pos = selection.ranges.length === 1 && selection.main.empty ? onCharacter(doc, selection.main.head) : null
  if (pos !== null && pos !== selection.main.head) view.dispatch({ selection: { anchor: pos } })
}

/**
 * A vim instance is per editor *state*: loading another note (view.setState) or toggling vim makes a new one.
 * But vim's jump list (gg, G, n, %, …) is global and holds bookmarks of the old instance, which still reads
 * positions from the same EditorView — now showing a different document. The next jump motion then hits
 * "Invalid position 1886 in document of length 13", the command throws, and its key used to land in the
 * note as text. Retire the outgoing instance's bookmarks so the jump list skips them.
 */
function retire(cm: ReturnType<typeof getCM>) {
  if (!cm) return
  for (const mark of Object.values(cm.marks)) mark.offset = null
}

const label = (e: ModeEvent) => {
  if (e.mode === 'visual') return e.subMode === 'linewise' ? 'visual line' : e.subMode === 'blockwise' ? 'visual block' : 'visual'
  if (e.mode === 'replace') return 'replace'
  return e.mode === 'insert' ? 'insert' : 'normal'
}

// A quiet lowercase mode label in the bottom-right corner.
const modeIndicator = ViewPlugin.fromClass(
  class {
    dom: HTMLElement
    cm: ReturnType<typeof getCM> = null
    handler = (e: ModeEvent) => {
      this.set(label(e))
      if (this.cm) onModeChange(this.cm, this.view, e)
    }
    constructor(readonly view: EditorView) {
      this.dom = document.createElement('div')
      this.dom.className = 'vim-mode'
      this.dom.setAttribute('aria-hidden', 'true')
      ;(document.getElementById('app') ?? document.body).appendChild(this.dom)
      view.scrollDOM.addEventListener('scroll', this.onScroll, { passive: true })
      this.attach()
    }
    // Mid-scroll the corner label would sit on top of text (see .vim-mode.away). At the bottom the content
    // reserves room for it.
    onScroll = () => {
      const el = this.view.scrollDOM
      this.dom.classList.toggle('away', el.scrollTop + el.clientHeight < el.scrollHeight - 4)
    }
    attach() {
      const cm = getCM(this.view)
      if (cm === this.cm) return
      this.cm?.off('vim-mode-change', this.handler)
      retire(this.cm)
      this.cm = cm
      if (!cm) return
      cm.on('vim-mode-change', this.handler)
      const s = cm.state.vim
      this.set(s?.insertMode ? 'insert' : s?.visualMode ? 'visual' : 'normal')
    }
    set(text: string) {
      if (this.dom.textContent !== text) this.dom.textContent = text
      this.dom.dataset.mode = text.split(' ')[0]
    }
    update(u: ViewUpdate) {
      this.attach()
      const starts = this.cm && insertStarts.get(this.cm)
      if (this.cm && starts && u.docChanged) insertStarts.set(this.cm, starts.map((p) => u.changes.mapPos(p, -1)))
      const deferred = this.cm && deferredBlock.get(this.cm)
      if (this.cm && deferred) {
        const map = (p: number) => u.changes.mapPos(p, -1)
        let next = u.docChanged ? { ...deferred, line: map(deferred.line), rows: deferred.rows.map(map) } : deferred
        // Where typing goes on after the cursor moved (Vim's `Insstart`, set by the next change).
        for (const tr of u.transactions) {
          const sel = tr.state.selection
          if (tr.docChanged) next = next.moved ? { ...next, resumed: next.moved, moved: undefined } : next
          else if (tr.selection && sel.ranges.length === 1 && sel.main.empty) next = { ...next, moved: caretAt(tr.state.doc, sel.main.head) }
        }
        // (Its first line joined onto the one above: the insert is off that line — the others get nothing, as in Vim.)
        if (u.state.doc.lineAt(next.line).from !== next.line) deferredBlock.delete(this.cm)
        else if (next !== deferred) deferredBlock.set(this.cm, next)
      }
      const ends = this.cm && insertEnds.get(this.cm)
      if (this.cm && ends && u.docChanged) insertEnds.set(this.cm, ends.map((p) => u.changes.mapPos(p, 1)))
      let start = this.cm ? insertStart.get(this.cm) : undefined
      if (this.cm && start) {
        // A cursor move on its own — an arrow key, a click, the dependency placing the cursor for `A` — restarts it
        // where typing goes on (see `settled`).
        for (const tr of u.transactions) {
          const sel = tr.state.selection
          if (tr.docChanged) start = { ...(start.frozen ? frozenStart(tr, start) : joinedStart(tr, settled(start))), typed: true }
          else if (tr.selection && sel.ranges.length === 1 && sel.main.empty) start = { ...start, moved: caretAt(tr.state.doc, sel.main.head) }
        }
        insertStart.set(this.cm, start)
      }
      if (putChanges && u.docChanged) putChanges = putChanges.compose(u.changes)
      if (u.geometryChanged || u.heightChanged) this.onScroll()
    }
    destroy() {
      this.cm?.off('vim-mode-change', this.handler)
      retire(this.cm)
      this.view.scrollDOM.removeEventListener('scroll', this.onScroll)
      this.dom.remove()
    }
  },
)
