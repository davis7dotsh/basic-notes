import { history, historyField, undoDepth } from '@codemirror/commands'
import { ChangeSet, Compartment, EditorSelection, EditorState, Text, Transaction } from '@codemirror/state'
import type { EditorView } from '@codemirror/view'

// Rewriting the undo history. CodeMirror's history has no API for reordering or merging events, but its state
// round-trips through JSON (`historyField`), and a fresh `historyField.init` in a reconfigured compartment replaces the
// live value. Used for: an async paste that completes after later typing (its undo step goes where ⌘V was pressed), and
// Vim insert sessions (`o…<Esc>` is one undo step). JSON drops events' effects; this app records none in history.

/** Holds `historyField.init(…)`: reconfiguring it swaps in a rewritten history. Part of every editor state. */
export const historySlot = new Compartment()

type EventJSON = { changes?: unknown; mapped?: unknown; startSelection?: unknown; selectionsAfter: unknown[] }
type HistoryJSON = { done: EventJSON[]; undone: EventJSON[] }

const isEvent = (e: unknown): e is EventJSON =>
  typeof e === 'object' && e !== null && 'selectionsAfter' in e && Array.isArray(e.selectionsAfter)

function readHistory(state: EditorState): HistoryJSON | null {
  const json: unknown = state.toJSON({ history: historyField })
  if (typeof json !== 'object' || json === null || !('history' in json)) return null
  const h: unknown = json.history
  if (typeof h !== 'object' || h === null || !('done' in h) || !('undone' in h)) return null
  const { done, undone } = h
  if (!Array.isArray(done) || !Array.isArray(undone) || !done.every(isEvent) || !undone.every(isEvent)) return null
  return { done, undone }
}

function writeHistory(view: EditorView, h: HistoryJSON) {
  const scratch = EditorState.fromJSON({ doc: '', selection: EditorSelection.single(0).toJSON(), history: h }, { extensions: history() }, { history: historyField })
  const value = scratch.field(historyField)
  view.dispatch({ effects: historySlot.reconfigure(historyField.init(() => value)) })
}

type Walk = {
  h: HistoryJSON
  /** The newest events since `doc0`, oldest first, with their forward changes. */
  events: { json: EventJSON; forward: ChangeSet }[]
  /** docs[i] = the document before events[i]; docs[events.length] = the live document. */
  docs: Text[]
}

/**
 * Walk the undo history back from the live document to the newest point where it was `doc0`: the events since then.
 * null = it never was (changes outside history, an undo past it) or the events aren't plain change events.
 */
function walkBack(state: EditorState, doc0: Text, minEvents = 0): Walk | null {
  const h = readHistory(state)
  if (!h) return null
  let doc = state.doc
  const docs = [doc]
  const events: Walk['events'] = []
  for (let i = h.done.length - 1; ; i--) {
    if (events.length >= minEvents && doc.length === doc0.length && doc.eq(doc0)) break
    const json = h.done[i]
    // `mapped` = changes outside history happened after this event: the ones below it aren't in this doc's coordinates.
    if (i < 0 || !json?.changes || !json.startSelection || json.mapped !== undefined) return null
    const inverse = ChangeSet.fromJSON(json.changes)
    if (inverse.length !== doc.length) return null
    events.unshift({ json, forward: inverse.invert(doc) })
    doc = inverse.apply(doc)
    docs.unshift(doc)
  }
  return { h, events, docs }
}

/** The changes that took `doc0` to the live document (null as for `walkBack`); empty = none since. */
export function changesSince(state: EditorState, doc0: Text): ChangeSet | null {
  const walk = walkBack(state, doc0)
  if (!walk) return null
  return walk.events.reduce((acc, e) => acc.compose(e.forward), ChangeSet.empty(doc0.length))
}

/**
 * Apply `change` (a change to `doc0`, the document when an async paste was invoked) as if it had happened then: the
 * edits made since are rebased over it, and it becomes its own undo step below them (`sel0` = the selection it restores).
 * Typing at the paste's position stays after it. false (nothing done) when the history since `doc0` can't be rebuilt;
 * the caller then applies it as a new step.
 */
export function applyAsOf(view: EditorView, doc0: Text, sel0: EditorSelection, change: ChangeSet, userEvent: string) {
  const walk = walkBack(view.state, doc0)
  if (!walk || !walk.events.length) return false
  let paste = change
  let doc = change.apply(doc0)
  const rebased: EventJSON[] = []
  for (const { json, forward } of walk.events) {
    const edit = forward.map(paste) // the paste first: text typed where it went lands after it
    const next = paste.map(forward, true)
    rebased.push({
      changes: edit.invert(doc).toJSON(),
      startSelection: selectionPast(EditorSelection.fromJSON(json.startSelection), paste).toJSON(),
      selectionsAfter: json.selectionsAfter.map((s) => EditorSelection.fromJSON(s).map(next).toJSON()),
    })
    doc = edit.apply(doc)
    paste = next
  }
  // `paste` is now the paste rebased onto the live document; both orders must reach the same text.
  if (paste.length !== view.state.doc.length || !paste.apply(view.state.doc).eq(doc)) return false
  const own: EventJSON = { changes: change.invert(doc0).toJSON(), startSelection: sel0.toJSON(), selectionsAfter: [] }
  view.dispatch({ changes: paste, annotations: Transaction.addToHistory.of(false), userEvent })
  const done = walk.h.done.slice(0, walk.h.done.length - walk.events.length)
  writeHistory(view, { done: [...done, own, ...rebased], undone: [] })
  return true
}

/**
 * `sel` (before `paste`) carried over it, as the selection had the paste come first: a range inside (or touching) what
 * the paste replaced becomes the caret after its insert — where the edit made from that selection now happens. Others map.
 */
function selectionPast(sel: EditorSelection, paste: ChangeSet) {
  const spans: { fromA: number; toA: number; toB: number }[] = []
  paste.iterChanges((fromA, toA, _fromB, toB) => spans.push({ fromA, toA, toB }))
  const ranges = sel.ranges.map((r) => {
    const hit = spans.filter((c) => c.fromA <= r.to && r.from <= c.toA)
    if (!hit.length || r.from < hit[0].fromA || r.to > hit[hit.length - 1].toA) return r.map(paste)
    return EditorSelection.cursor(hit[hit.length - 1].toB)
  })
  return EditorSelection.create(ranges, sel.mainIndex)
}

/** Fold every undo event since `doc0` into one (a Vim insert session). `depth0`: the undo depth then — the events since
 *  go back past a later point where the document was `doc0` too (a session that ends where it began). */
export function mergeSince(view: EditorView, doc0: Text, depth0?: number) {
  const walk = walkBack(view.state, doc0, depth0 === undefined ? 0 : undoDepth(view.state) - depth0)
  if (!walk || walk.events.length < 2) return
  const first = walk.events[0].json
  const last = walk.events[walk.events.length - 1].json
  const forward = walk.events.reduce((acc, e) => acc.compose(e.forward), ChangeSet.empty(doc0.length))
  const merged: EventJSON = { changes: forward.invert(doc0).toJSON(), startSelection: first.startSelection, selectionsAfter: last.selectionsAfter }
  const done = walk.h.done.slice(0, walk.h.done.length - walk.events.length)
  writeHistory(view, { done: [...done, merged], undone: walk.h.undone })
}

/**
 * After a redo, the selection a Mac app shows: the history restores the selection from before the undo mapped through the
 * redone change, which after typing over a selection is a sliver of the new text (its first character — the next keystroke
 * replaces it). A range that cuts into one replaced span (part of it) becomes a caret at that span's end. Ranges that hold
 * whole spans or sit between them — formatting wrapped or prefixed around the selection (⌘B, a list toggle, Tab) — stay.
 * null = nothing to fix.
 */
export function redoSelection(tr: Transaction) {
  if (!tr.isUserEvent('redo') || !tr.docChanged) return null
  const spans: { from: number; to: number }[] = []
  tr.changes.iterChangedRanges((_fromA, _toA, from, to) => spans.push({ from, to }))
  const sel = tr.state.selection
  let changed = false
  const ranges = sel.ranges.map((r) => {
    if (r.empty) return r
    const hit = spans.filter((c) => c.from < r.to && r.from < c.to)
    if (hit.length !== 1 || (r.from <= hit[0].from && r.to >= hit[0].to)) return r
    changed = true
    return EditorSelection.cursor(hit[0].to)
  })
  return changed ? EditorSelection.create(ranges, sel.mainIndex) : null
}
