import { isolateHistory } from '@codemirror/commands'
import { ChangeSet, EditorSelection, type SelectionRange, Text } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import { send } from '../bridge/client'
import { toast } from '../ui/toast'
import { listInfo } from './commands'
import { applyAsOf, changesSince } from './historyEdit'

// Drag-and-drop of image files: save via Swift, insert `![](assets/…)` as its own line at the drop point.
// (⌘V image paste is native: Swift saves the asset and sends us `insertText`.)

/**
 * The prefix that continues a line's container: a list item's content column (`- [ ] item` → `  `, quoted
 * `> 1. item` → `>    `), or a plain line's own quote + indentation. Block content (an image) inserted under
 * a list item must be indented to it, or CommonMark reads it as a lazy continuation and every other renderer
 * disagrees with the editor.
 */
function container(text: string, above: string | null): { prefix: string; contentFrom: number } {
  const info = listInfo(text)
  if (info) {
    // An item with no text yet has its content column one space after the marker (CommonMark), however much
    // padding was typed; more than 4 spaces there would otherwise make the block an indented code block.
    const empty = text.slice(info.prefixLength).trim() === ''
    const width = empty ? info.markerFrom - info.quote.length + info.marker.length + 1 : info.markerEnd - info.quote.length
    return { prefix: info.quote + ' '.repeat(width), contentFrom: info.prefixLength }
  }
  const lead = /^(?:[ \t]*>[ \t]?)*[ \t]*/.exec(text)![0]
  // A whitespace-only line keeps its indentation only as far as the line above's container reaches
  // (stray spaces on a blank line mustn't turn the image into an indented code block).
  if (lead === text && lead.includes('>')) {
    // Blank quote line: keep the quote markers, and indent past them only as far as the line above's container
    // reaches (a list item inside the quote); stray extra spaces would make an indented code block.
    const quote = /^(?:[ \t]*>[ \t]?)*/.exec(text)![0]
    const reach = above === null ? 0 : container(above, null).prefix.length
    return { prefix: lead.slice(0, Math.min(lead.length, Math.max(quote.length, reach))), contentFrom: lead.length }
  }
  if (lead === text) {
    const reach = above === null ? 0 : container(above, null).prefix.length
    return { prefix: lead.slice(0, Math.min(lead.length, reach)), contentFrom: lead.length }
  }
  return { prefix: lead, contentFrom: lead.length }
}

/**
 * Insert `text` as its own line(s) at `pos`, leaving the cursor on the line below it. With `to`, the range
 * [pos, to) (the selection) is replaced first, all in one undoable step. Inside a list item or quote the
 * block (and the caret line after it) stays in that container. `moveCaret: false` leaves the selection where it is.
 */
export function insertBlock(view: EditorView, pos: number, text: string, to = pos, moveCaret = true) {
  const { changes, caret } = blockChange(view.state.doc, view.state.lineBreak, pos, text, to)
  view.dispatch({
    changes,
    selection: moveCaret ? { anchor: caret } : undefined,
    scrollIntoView: moveCaret,
    userEvent: 'input.paste',
  })
}

/** `insertBlock`'s change to `original` (and the caret after it), without applying it. */
function blockChange(original: Text, br: string, pos: number, text: string, to = pos) {
  const clear = ChangeSet.of({ from: pos, to }, original.length)
  const doc = clear.apply(original)
  const at = Math.max(0, Math.min(clear.mapPos(pos, -1), doc.length))
  let line = doc.lineAt(at)
  const above = (l: typeof line) => (l.number > 1 ? doc.line(l.number - 1).text : null)
  // The empty last line after a file's final newline, below a whitespace-only continuation/quote line: the block
  // belongs on that line (in its container), as it would mid-document — not in a new top-level paragraph after it.
  if (line.length === 0 && line.number === doc.lines && line.number > 1) {
    const prev = doc.line(line.number - 1)
    if (prev.length > 0 && /^(?:[ \t]*>?)*$/.test(prev.text) && container(prev.text, above(prev)).prefix !== '') line = prev
  }
  const { prefix: cont, contentFrom } = container(line.text, above(line))
  const contentStart = line.from + contentFrom
  const blank = line.text.slice(contentFrom).trim() === ''
  // On a blank line (or an empty item) the block takes it over; otherwise it goes in at the point, splitting
  // the line there (without leaving the spaces around the split dangling).
  // A whitespace-only line is replaced from its start (its stray indent is capped to `cont`), so 4+ spaces left on
  // a blank line can't turn the image into an indented code block.
  const bare = blank && /^(?:[ \t]*>?)*$/.test(line.text) && !listInfo(line.text)
  // Empty list item: the block goes one space after its marker (or task box), dropping extra padding.
  const itemStart = line.from + line.text.slice(0, contentFrom).replace(/[ \t]+$/, '').length + 1
  let from = bare ? line.from : blank ? Math.min(contentStart, itemStart) : Math.max(at, contentStart)
  let end = blank ? line.to : Math.max(at, contentStart)
  if (!blank) {
    while (from > contentStart && /[ \t]/.test(doc.sliceString(from - 1, from))) from--
    while (end < line.to && /[ \t]/.test(doc.sliceString(end, end + 1))) end++
  }
  const prefix = bare ? cont : blank || from === contentStart ? '' : br + cont
  const body = text.split('\n').join(br + cont)
  const atEnd = blank || end === line.to
  const next = line.number < doc.lines ? doc.line(line.number + 1) : null
  // Top level: reuse a blank line that follows. In a container, the caret line continues it.
  const suffix = !cont && atEnd && next !== null && next.text.trim() === '' ? '' : br + cont
  const caret = from + prefix.length + body.length + (suffix ? suffix.length : br.length)
  return { changes: clear.compose(ChangeSet.of({ from, to: end, insert: prefix + body + suffix }, doc.length)), caret }
}

/** A native text paste: replace the selection inline, exactly like ⌘V of plain text. */
export function insertInline(view: EditorView, text: string) {
  view.dispatch(view.state.replaceSelection(text), { scrollIntoView: true, userEvent: 'input.paste' })
}

const readBase64 = (file: File) =>
  new Promise<string>((resolve, reject) => {
    const r = new FileReader()
    r.onload = () => resolve(String(r.result).replace(/^data:[^,]*,/, ''))
    r.onerror = () => reject(r.error)
    r.readAsDataURL(file)
  })

// Saving is async (FileReader + bridge). A drop belongs to the note session it landed in: if another note
// loads meanwhile, the image is saved but not inserted anywhere; within the same session the drop point
// follows intervening edits.
let generation = 0
const pendingDrops = new Set<{ pos: number }>()

// A native paste whose text arrives later (see `beginPaste` in protocol.ts): the selection at ⌘V, mapped through
// intervening edits. `from` sticks before text typed at a collapsed caret (so typing lands after the paste) and, for a
// range, both ends hug its content (typing just outside it doesn't grow it). `sel` is the selection as it would be had
// the user done nothing since: equal to the live one at completion = the caret hasn't moved. `at` is the moment of ⌘V
// (document, selection, range): the paste's undo step goes there, below whatever was typed while it was pending.
// `place` (a vim `p`): replace [at, to) (default: insert at `at`) instead of the selection, the text reshaped by `shape`
// (linewise, counts), and the caret (when untouched) at `caret(from, inserted)` instead of after the text. `extra`: ranges
// after it deleted along with it (the other lines of a visual block), each only if it still holds what it held. `linewise`
// with an `other` placement: the shape the text was expected in — text that arrives in the other shape (ends in a newline
// or doesn't) goes where `other` puts it.
type Range = { from: number; to: number }
export type Placement = { at: number; to?: number; extra?: Range[]; linewise?: boolean; shape(text: string): string; caret(from: number, text: string): number }
type Extra = Range & { text: string; at: Range }
type Reservation = {
  from: number
  to: number
  text: string
  extra: Extra[]
  sel: SelectionRange
  at: { doc: Text; sel: EditorSelection; from: number; to: number }
  place?: Placement
  other?: Reservation
}
const pendingPastes = new Map<string, Reservation>()

function reservation(view: EditorView, place?: Placement): Reservation {
  const sel = view.state.selection.main
  const from = place ? place.at : sel.from
  const to = place ? (place.to ?? place.at) : sel.to
  const at = { doc: view.state.doc, sel: view.state.selection, from, to }
  const extra = (place?.extra ?? []).map((r) => ({ ...r, text: view.state.sliceDoc(r.from, r.to), at: r }))
  return { from, to, text: view.state.sliceDoc(from, to), extra, sel, at, place }
}

export function reservePaste(view: EditorView, token: string, place?: Placement, other?: Placement) {
  pendingPastes.set(token, { ...reservation(view, place), other: other && reservation(view, other) })
  // Typing from here on starts its own undo step (not joined to the one before ⌘V), so the paste can go between them.
  view.dispatch({ annotations: isolateHistory.of('full') })
}

export function cancelPaste(token: string) {
  pendingPastes.delete(token)
}

/**
 * Insert a reserved paste: replace its range if that still holds the text it held at ⌘V (or was typed over as a
 * whole), else replace nothing and insert at the range's mapped start. false = no such reservation (another note was
 * loaded since): nothing inserted. Edits made while it was pending stay after it in the undo history too.
 */
export function completePaste(view: EditorView, token: string, text: string, block: boolean) {
  const reserved = pendingPastes.get(token)
  if (!reserved) return false
  pendingPastes.delete(token)
  const p = reserved.other && reserved.place?.linewise !== text.endsWith('\n') ? reserved.other : reserved
  if (p.place) text = p.place.shape(text)
  const intact = view.state.sliceDoc(p.from, p.to) === p.text
  const extra = p.extra.filter((r) => view.state.sliceDoc(r.from, r.to) === r.text)
  if (!intact || p.at.doc !== view.state.doc) {
    // Edited meanwhile: apply it as of ⌘V (its own undo step below those edits) when the history allows.
    const since = changesSince(view.state, p.at.doc)
    const { from, to: end } = p.at
    const replace = end > from && (intact || (since !== null && deletesAll(since, from, end)))
    const to = replace ? end : from
    const change = block
      ? blockChange(p.at.doc, view.state.lineBreak, from, text, to).changes
      : ChangeSet.of([{ from, to, insert: view.state.toText(text) }, ...extra.map((r) => r.at)], p.at.doc.length)
    if (since && !since.empty && applyAsOf(view, p.at.doc, p.at.sel, change, 'input.paste')) return true
  }
  const to = intact ? p.to : p.from
  const untouched = view.state.selection.main.eq(p.sel)
  if (block) insertBlock(view, p.from, text, to, untouched)
  else
    view.dispatch({
      changes: [{ from: p.from, to, insert: text }, ...extra.map(({ from, to }) => ({ from, to }))],
      selection: untouched ? { anchor: p.place ? p.place.caret(p.from, text) : p.from + view.state.toText(text).length } : undefined,
      scrollIntoView: untouched,
      userEvent: 'input.paste',
    })
  return true
}

/** Whether `changes` delete every character of [from, to). */
function deletesAll(changes: ChangeSet, from: number, to: number) {
  let covered = from
  changes.iterChangedRanges((fromA, toA) => {
    if (fromA <= covered && toA > covered) covered = toA
  })
  return covered >= to
}

/** Call when a different note is loaded into the editor. */
export function newDropSession() {
  generation++
  pendingDrops.clear()
  pendingPastes.clear()
}

const trackDrops = EditorView.updateListener.of((u) => {
  if (!u.docChanged) return
  for (const p of pendingDrops) p.pos = u.changes.mapPos(p.pos)
  for (const p of [...pendingPastes.values()].flatMap((p) => (p.other ? [p, p.other] : [p]))) {
    const empty = p.from === p.to
    p.from = u.changes.mapPos(p.from, empty ? -1 : 1)
    p.to = Math.max(p.from, u.changes.mapPos(p.to, -1))
    p.sel = p.sel.map(u.changes)
    for (const r of p.extra) {
      r.from = u.changes.mapPos(r.from, 1)
      r.to = Math.max(r.from, u.changes.mapPos(r.to, -1))
    }
  }
})

async function insertImages(view: EditorView, files: File[], pos: number) {
  const gen = generation
  const drop = { pos }
  pendingDrops.add(drop)
  const paths: string[] = []
  for (const file of files) {
    try {
      const base64 = await readBase64(file)
      const reply = await send<{ path: string }>({ type: 'saveImage', base64, mime: file.type || 'image/png', filename: file.name || null })
      if (reply?.path) paths.push(reply.path)
    } catch (err) {
      void send({ type: 'log', level: 'error', message: `saveImage failed: ${String(err)}` })
    }
  }
  pendingDrops.delete(drop)
  if (gen !== generation) {
    if (paths.length) toast(paths.length > 1 ? 'Images saved · note changed' : 'Image saved · note changed')
    return
  }
  if (paths.length) insertBlock(view, drop.pos, paths.map((p) => `![](${p})`).join('\n'))
  else toast('Couldn’t save image', 'error')
  view.focus()
}

const hasFiles = (e: DragEvent) => Boolean(e.dataTransfer && [...e.dataTransfer.types].includes('Files'))

export const dropImages = [
  trackDrops,
  EditorView.domEventHandlers({
    dragover(e) {
      if (!hasFiles(e)) return false
      e.preventDefault()
      if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy'
      return false // let dropCursor track the position
    },
    drop(e, view) {
      if (!hasFiles(e)) return false
      e.preventDefault()
      const files = [...(e.dataTransfer?.files ?? [])].filter((f) => f.type.startsWith('image/'))
      if (files.length) {
        const pos = view.posAtCoords({ x: e.clientX, y: e.clientY }) ?? view.state.selection.main.head
        void insertImages(view, files, pos)
      }
      return true // never let CM (or WKWebView) handle a file drop
    },
  }),
]

/** WKWebView navigates to a dropped file by default; never let that happen anywhere in the page. */
export function guardWindowDrops() {
  const stop = (e: DragEvent) => {
    if (hasFiles(e)) e.preventDefault()
  }
  window.addEventListener('dragover', stop)
  window.addEventListener('drop', stop)
}
