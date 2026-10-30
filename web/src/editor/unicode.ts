import { ChangeSet, ChangeSpec, EditorSelection, EditorState, findClusterBreak, Prec, SelectionRange, Text } from '@codemirror/state'
import type { Command } from '@codemirror/view'

// Offsets are UTF-16 code units: a position between the halves of a surrogate pair (most emoji) splits a character. An
// edit there leaves a lone surrogate, which has no UTF-8 form — the note could no longer be saved.

const isHigh = (c: number) => c >= 0xd800 && c <= 0xdbff
const isLow = (c: number) => c >= 0xdc00 && c <= 0xdfff
const codeAt = (doc: Text, pos: number) => (pos >= 0 && pos < doc.length ? doc.sliceString(pos, pos + 1).charCodeAt(0) : 0)

/** `pos` sits inside a surrogate pair. */
const splits = (doc: Text, pos: number) => isHigh(codeAt(doc, pos - 1)) && isLow(codeAt(doc, pos))

/** `pos`, or the start of the grapheme cluster (`🙂`, `🧑‍💻`, `é` with its combining mark) it falls inside. */
export function clusterStart(doc: Text, pos: number) {
  const line = doc.lineAt(pos)
  const off = pos - line.from
  const prev = findClusterBreak(line.text, off, false)
  return findClusterBreak(line.text, prev, true) === off ? pos : line.from + prev
}

/** Where vim's block cursor lands for a range leaving Visual: on its last character (a forward range's head is one past
 *  it — the whole character, never half of an emoji). Never past the end of a line that has characters: Normal mode
 *  can't sit there (a caret at the end of one goes back onto its last character). */
export function normalCaret(doc: Text, anchor: number, head: number) {
  const line = doc.lineAt(head)
  const pos = head <= anchor ? clusterStart(doc, head) : head === line.from ? head - 1 : line.from + findClusterBreak(line.text, head - line.from, false)
  return EditorSelection.single(onCharacter(doc, pos))
}

/** `pos`, or the last character of its line when it's at the end of a non-empty one. */
export function onCharacter(doc: Text, pos: number) {
  const line = doc.lineAt(pos)
  return pos === line.to && pos > line.from ? line.from + findClusterBreak(line.text, pos - line.from, false) : pos
}

/** The position after the character (grapheme cluster, as vim counts them) at `pos`; at the end of a line, after its
 *  line break. */
export function charEnd(doc: Text, pos: number) {
  const line = doc.lineAt(pos)
  return pos < line.to ? line.from + findClusterBreak(line.text, pos - line.from, true) : pos + 1
}

/** Offset of `text`'s last character (grapheme cluster) from its start: 0 for empty text. */
export const lastCharOffset = (text: string) => (text ? findClusterBreak(text, text.length, false) : 0)

// Character offsets within one line's text (vim's `ch`): a character is a grapheme cluster.

/** Offset `i` of `text`, or the start of the character it falls inside. */
export function charStartIn(text: string, i: number) {
  if (i <= 0 || i >= text.length) return i
  const prev = findClusterBreak(text, i, false)
  return findClusterBreak(text, prev, true) === i ? i : prev
}

/** Offset `i` of `text`, or the end of the character it falls inside. */
export function charEndIn(text: string, i: number) {
  const start = charStartIn(text, i)
  return start === i ? i : findClusterBreak(text, start, true)
}

/** The characters of `text`: their [from, to) offsets. */
export function charsOf(text: string) {
  const out: { from: number; to: number }[] = []
  for (let i = 0; i < text.length; ) {
    const to = findClusterBreak(text, i, true)
    out.push({ from: i, to })
    i = to
  }
  return out
}

// Screen columns (Vim's virtual columns, what `j`/`k` and Insert's Up/Down keep): a character is one cell, a wide one
// (CJK, fullwidth forms, emoji) two, a combining mark none (it rides on its base), a tab up to the next tab stop.

/** East Asian Wide/Fullwidth blocks (emoji are matched by their presentation, below). */
const wide: [number, number][] = [
  [0x1100, 0x115f], [0x2329, 0x232a], [0x2630, 0x2637], [0x268a, 0x268f], [0x2e80, 0x303e], [0x3041, 0x3247], [0x3250, 0x33ff], [0x3400, 0x4dbf], [0x4e00, 0x9fff], [0xa000, 0xa4cf],
  [0xa960, 0xa97f], [0xac00, 0xd7a3], [0xf900, 0xfaff], [0xfe10, 0xfe19], [0xfe30, 0xfe6f], [0xff00, 0xff60], [0xffe0, 0xffe6],
  [0x16fe0, 0x16fe4], [0x17000, 0x18aff], [0x1b000, 0x1b16f], [0x1f200, 0x1f202], [0x1f210, 0x1f23b], [0x1f240, 0x1f248],
  [0x1f250, 0x1f251], [0x1f260, 0x1f265], [0x20000, 0x2fffd], [0x30000, 0x3fffd],
]
const unassigned = /^\p{Cn}/u
const emojiFirst = /^(?:\p{Emoji_Presentation}|(?=[\u{1f300}-\u{1faff}])(?!\p{Cn})\p{Extended_Pictographic})/u
/** An emoji a variation selector can make wide: `✔️`, `©️` — not the ASCII digits/`#`/`*` (`1️⃣` stays one cell, as in nvim). */
const emojiBase = /^(?![\0-\x7f])\p{Emoji}/u

/** Cells `char` (one grapheme cluster) takes starting at screen column `col`. */
function cells(char: string, col: number, tabSize: number) {
  const cp = char.codePointAt(0) ?? 0
  if (cp === 9) return tabSize - (col % tabSize)
  // (Other control characters show as `^X`; an emoji variation selector makes `✔️`/`❤️` wide, a keycap `1️⃣` not.)
  if (cp < 0x20 || cp === 0x7f || emojiFirst.test(char) || (char.includes('\ufe0f') && emojiBase.test(char))) return 2
  return wide.some(([a, b]) => cp >= a && cp <= b) && !unassigned.test(char) ? 2 : 1
}

/** The screen columns each character of `text` starts and ends at. */
function columns(text: string, tabSize: number) {
  let col = 0
  return charsOf(text).map((c) => {
    const start = col
    col += cells(text.slice(c.from, c.to), col, tabSize)
    return { ...c, start, end: col }
  })
}

/** The screen column at offset `to` of a line's `text` (where an Insert caret there is). */
export const displayCol = (text: string, to: number, tabSize: number) => columns(text.slice(0, to), tabSize).at(-1)?.end ?? 0

/** The screen column of a Normal cursor on the character at offset `at`: a tab's last cell (Vim's cursor sits there). */
export function cursorCol(text: string, at: number, tabSize: number) {
  const c = columns(text, tabSize).find((c) => c.to > at)
  if (!c) return displayCol(text, text.length, tabSize)
  return text[c.from] === '\t' ? c.end - 1 : c.start
}

/** The offset of the character of `text` covering screen column `col` (Vim's `coladvance`); past the end, `text.length`. */
export const offsetAtCol = (text: string, col: number, tabSize: number) => columns(text, tabSize).find((c) => c.end > col)?.from ?? text.length

/** Backspace over a character made of several code points takes all of it (`é` as e + a combining accent), as forward
 *  Delete and vim's `X` do — CodeMirror's backward step takes a trailing combining mark alone. Only where the two differ;
 *  everything else (indentation units, line breaks, emoji it already deletes whole) is CodeMirror's. */
export const deleteCharacterBackward: Command = (view) => {
  const { state } = view
  const r = state.selection.main
  if (state.readOnly || state.selection.ranges.length > 1 || !r.empty) return false
  const line = state.doc.lineAt(r.head)
  const off = r.head - line.from
  if (off === 0 || !/[^ \t]/.test(line.text.slice(0, off))) return false
  const from = findClusterBreak(line.text, off, false)
  if (from >= findClusterBreak(line.text, off, false, false)) return false
  view.dispatch({ changes: { from: line.from + from, to: r.head }, selection: { anchor: line.from + from }, scrollIntoView: true, userEvent: 'delete.backward' })
  return true
}

const snapRange = (doc: Text, r: SelectionRange) => {
  if (r.empty) return splits(doc, r.head) ? EditorSelection.cursor(r.head - 1) : r
  // A range grows to whole characters.
  const from = splits(doc, r.from) ? r.from - 1 : r.from
  const to = splits(doc, r.to) ? r.to + 1 : r.to
  if (from === r.from && to === r.to) return r
  return r.anchor < r.head ? EditorSelection.range(from, to) : EditorSelection.range(to, from)
}

function snapSelection(doc: Text, sel: EditorSelection) {
  const ranges = sel.ranges.map((r) => snapRange(doc, r))
  return ranges.every((r, i) => r === sel.ranges[i]) ? null : EditorSelection.create(ranges, sel.mainIndex)
}

/**
 * Nothing leaves half a character behind. Arithmetic that steps one code unit (vim's `p` "after the cursor's character",
 * a block column through an emoji) would split a pair: an insertion there goes after the whole character, a deletion that
 * took half of one takes the rest of it too, and a lone surrogate that still turns up becomes U+FFFD. Selections snap to
 * whole characters. In the same transaction (one undo step, its annotations kept).
 */
export const surrogateGuard = Prec.highest(
  EditorState.transactionFilter.of((tr) => {
    if (!tr.docChanged) {
      const sel = tr.selection && snapSelection(tr.newDoc, tr.selection)
      return sel ? [tr, { selection: sel, sequential: true }] : tr
    }
    const doc = tr.newDoc
    const fixes: ChangeSpec[] = []
    let last = -1
    tr.changes.iterChangedRanges((_fA, _tA, from, to) => {
      const start = Math.max(from - 1, last, 0)
      const end = Math.min(to + 1, doc.length)
      if (start >= end) return
      const text = doc.sliceString(start, end)
      if (!/[\ud800-\udfff]/.test(text)) return void (last = end)
      // An insertion between the halves of a pair (H|text|L): the low half moves back to its partner.
      if (to > from && start === from - 1 && isHigh(codeAt(doc, from - 1)) && !isLow(codeAt(doc, from)) && isLow(codeAt(doc, to)) && !isHigh(codeAt(doc, to - 1))) {
        fixes.push({ from, insert: doc.sliceString(to, to + 1) }, { from: to, to: to + 1 })
      } else {
        for (let i = 0; i < text.length; i++) {
          const pos = start + i
          const c = text.charCodeAt(i)
          const lone = isHigh(c) ? !isLow(codeAt(doc, pos + 1)) : isLow(c) && !isHigh(codeAt(doc, pos - 1))
          if (!lone) continue
          // Outside the inserted text it's what's left of a character the edit cut through: it goes too.
          fixes.push({ from: pos, to: pos + 1, insert: pos < from || pos >= to ? '' : '\ufffd' })
        }
      }
      last = end
    })
    if (!fixes.length) {
      const sel = snapSelection(doc, tr.newSelection)
      return sel ? [tr, { selection: sel, sequential: true }] : tr
    }
    const changes = ChangeSet.of(fixes, doc.length)
    const after = changes.apply(doc)
    const mapped = tr.newSelection.map(changes)
    return [tr, { changes, selection: snapSelection(after, mapped) ?? mapped, sequential: true }]
  }),
)
