import { StateEffect, StateField, Text, Transaction } from '@codemirror/state'
import { Decoration, DecorationSet, EditorView } from '@codemirror/view'
import type { SearchPassage } from '../bridge/protocol'

const flash = StateEffect.define<{ from: number; to: number } | null>()
export const passageHighlight = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(previous, tr) {
    for (const effect of tr.effects) {
      if (effect.is(flash)) {
        return effect.value
          ? Decoration.set([Decoration.mark({ class: 'cm-search-passage' }).range(effect.value.from, effect.value.to)])
          : Decoration.none
      }
    }
    return tr.docChanged || tr.selection ? Decoration.none : previous
  },
  provide: field => EditorView.decorations.from(field),
})

/** Verify the indexed text against the live buffer. An intervening edit can move a match. */
export function locatePassage(doc: Text, original: string, passage?: SearchPassage) {
  if (!passage?.text) return null
  const { offset, text } = passage
  const from = original.includes('\r\n') ? original.slice(0, offset).replace(/\r\n/g, '\n').length : offset
  if (from >= 0 && from + text.length <= doc.length && doc.sliceString(from, from + text.length) === text) {
    return { from, to: from + text.length }
  }
  const live = doc.toString()
  const found = live.indexOf(text)
  if (found < 0 || live.indexOf(text, found + 1) >= 0) return null
  return { from: found, to: found + text.length }
}

let timer: ReturnType<typeof setTimeout>
export function revealPassage(view: EditorView, range: { from: number; to: number }) {
  clearTimeout(timer)
  view.dispatch({
    selection: { anchor: range.from },
    effects: [flash.of(range), EditorView.scrollIntoView(range.from, { y: 'center' })],
    annotations: Transaction.addToHistory.of(false),
  })
  timer = setTimeout(() => {
    if (view.state.field(passageHighlight).size) view.dispatch({ effects: flash.of(null) })
  }, 1600)
}
