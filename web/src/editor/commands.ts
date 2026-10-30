import { indentLess, indentMore } from '@codemirror/commands'
import { deleteMarkupBackward, insertNewlineContinueMarkupCommand } from '@codemirror/lang-markdown'
import { syntaxTree } from '@codemirror/language'
import type { SyntaxNode } from '@lezer/common'
import { ChangeSpec, EditorSelection, EditorState, Line, Prec, SelectionRange, StateCommand, Transaction, TransactionSpec } from '@codemirror/state'
import { EditorView, KeyBinding, keymap } from '@codemirror/view'
import { continuationOf, enclosingItem, quotePrefix } from './listIndent'
import { deleteCharacterBackward } from './unicode'

// Toggle-style Markdown formatting. Everything edits plain text; the live preview renders it.

const dispatch = (state: EditorState, d: (tr: Transaction) => void, spec: TransactionSpec) => {
  d(state.update(spec, { scrollIntoView: true, userEvent: 'input.format' }))
  return true
}

/** The selection, or the word at the cursor, with surrounding whitespace trimmed off. */
function targetRange(state: EditorState, range: SelectionRange) {
  let { from, to } = range
  if (range.empty) {
    const word = state.wordAt(range.head)
    if (word) ({ from, to } = word)
  } else {
    // Don't wrap surrounding whitespace: `** word**` isn't valid emphasis.
    const text = state.sliceDoc(from, to)
    from += text.length - text.trimStart().length
    to -= text.length - text.trimEnd().length
    if (to < from) to = from
  }
  return { from, to }
}

/** Wrap/unwrap the selection (or the word at the cursor) with a marker like `~~` or `` ` ``. */
export const toggleInline =
  (marker: string): StateCommand =>
  ({ state, dispatch: d }) => {
    const m = marker.length
    const tr = state.changeByRange((range) => {
      const { from, to } = targetRange(state, range)
      const cursor = range.empty ? range.head : null
      const before = state.sliceDoc(from - m, from)
      const after = state.sliceDoc(to, to + m)
      const inner = state.sliceDoc(from, to)
      // Already wrapped from outside: **|word|**
      if (before === marker && after === marker) {
        const changes = [
          { from: from - m, to: from },
          { from: to, to: to + m },
        ]
        const map = (p: number) => (p >= to ? p - 2 * m : p >= from ? p - m : p)
        return { changes, range: cursor !== null ? EditorSelection.cursor(map(cursor)) : EditorSelection.range(from - m, to - m) }
      }
      // Wrapped from inside: |**word**|
      if (inner.length >= 2 * m && inner.startsWith(marker) && inner.endsWith(marker)) {
        const changes = [
          { from, to: from + m },
          { from: to - m, to },
        ]
        return { changes, range: EditorSelection.range(from, to - 2 * m) }
      }
      const changes = [
        { from, insert: marker },
        { from: to, insert: marker },
      ]
      if (cursor !== null) return { changes, range: EditorSelection.cursor(cursor + m) }
      return { changes, range: EditorSelection.range(from + m, to + m) }
    })
    d(state.update(tr, { scrollIntoView: true, userEvent: 'input.format' }))
    return true
  }

const run = (text: string, at: number, dir: 1 | -1, ch: string) => {
  let n = 0
  for (let i = dir === 1 ? at : at - 1; i >= 0 && i < text.length && text[i] === ch && n < 3; i += dir) n++
  return n
}

/**
 * ⌘B / ⌘I. Emphasis is counted, not matched: the symmetric run of `*` (or `_`) around the text says
 * what it is (1 italic, 2 bold, 3 both), and toggling adds/removes one or two markers. New markup always
 * uses `*`, which (unlike `_`) is valid mid-word, so ⌘B then ⌘I on `coff|ee` gives `***coff***ee`.
 */
export const toggleEmphasis =
  (kind: 'bold' | 'italic'): StateCommand =>
  ({ state, dispatch: d }) => {
    const size = kind === 'bold' ? 2 : 1
    const tr = state.changeByRange((range) => {
      let { from, to } = targetRange(state, range)
      const cursor = range.empty ? range.head : null
      const line = state.doc.lineAt(from)
      if (to > line.to) return { range }
      const text = line.text
      let a = from - line.from
      let b = to - line.from
      // Selection that includes its own markers (|**word**|): treat them as outside.
      for (const ch of ['*', '_']) {
        const k = Math.min(run(text, a, 1, ch), run(text, b, -1, ch))
        if (k && b - a > 2 * k) {
          a += k
          b -= k
          break
        }
      }
      let ch = '*'
      let k = Math.min(run(text, a, -1, '*'), run(text, b, 1, '*'))
      if (!k) {
        const u = Math.min(run(text, a, -1, '_'), run(text, b, 1, '_'))
        if (u) {
          ch = '_'
          k = u
        }
      }
      const has = kind === 'bold' ? k >= 2 : k % 2 === 1
      from = line.from + a
      to = line.from + b
      if (has) {
        const changes = [
          { from: from - size, to: from },
          { from: to, to: to + size },
        ]
        const map = (p: number) => (p >= to ? p - 2 * size : p >= from ? p - size : Math.min(p, from - size))
        return {
          changes,
          range: cursor !== null ? EditorSelection.cursor(map(cursor)) : EditorSelection.range(from - size, to - size),
        }
      }
      const marker = (ch === '_' && k ? '_' : '*').repeat(size)
      const changes = [
        { from, insert: marker },
        { from: to, insert: marker },
      ]
      if (cursor !== null) return { changes, range: EditorSelection.cursor(cursor + size) }
      return { changes, range: EditorSelection.range(from + size, to + size) }
    })
    d(state.update(tr, { scrollIntoView: true, userEvent: 'input.format' }))
    return true
  }

const URL_RE = /^(https?:\/\/|mailto:|www\.)\S+$/i

/** ⌘⇧K: `[selection](|)`; if the selection is a URL, `[|](url)`. */
export const insertLink: StateCommand = ({ state, dispatch: d }) => {
  const tr = state.changeByRange((range) => {
    let { from, to } = range
    if (range.empty) {
      const word = state.wordAt(range.head)
      if (word) ({ from, to } = word)
    }
    const text = state.sliceDoc(from, to)
    if (URL_RE.test(text)) {
      return { changes: { from, to, insert: `[](${text})` }, range: EditorSelection.cursor(from + 1) }
    }
    if (!text) return { changes: { from, insert: '[]()' }, range: EditorSelection.cursor(from + 1) }
    const insert = `[${text}]()`
    return { changes: { from, to, insert }, range: EditorSelection.cursor(from + insert.length - 1) }
  })
  d(state.update(tr, { scrollIntoView: true, userEvent: 'input.format' }))
  return true
}

const selectedLines = (state: EditorState) => {
  const seen = new Set<number>()
  const lines: Line[] = []
  for (const r of state.selection.ranges) {
    // A selection ending exactly at a line start (e.g. shift+↓ over one line) doesn't include that line.
    const end = r.to > r.from && state.doc.lineAt(r.to).from === r.to ? r.to - 1 : r.to
    const last = state.doc.lineAt(end).number
    for (let n = state.doc.lineAt(r.from).number; n <= last; n++) {
      if (seen.has(n)) continue
      seen.add(n)
      lines.push(state.doc.line(n))
    }
  }
  return lines
}

const inCode = (state: EditorState, pos: number) => {
  for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(pos, 1); n; n = n.parent) {
    if (n.name === 'FencedCode' || n.name === 'CodeBlock') return true
  }
  return false
}

const HEADING_RE = /^#{1,6}(?:[ \t]+|$)/

/** Where a line's heading marker goes: after its quote prefix. A list marker (and its indentation) is replaced, so
 *  `- item` / `- [ ] task` / `1. item` become `# item`, and `> quote` becomes `> # quote`. */
function headingSlot(l: Line) {
  const info = listInfo(l.text)
  const quote = QUOTE_RE.exec(l.text)![0].length
  const from = l.from + quote
  if (info) return { from, to: l.from + info.prefixLength }
  return { from, to: from + (HEADING_RE.exec(l.text.slice(quote))?.[0].length ?? 0) }
}

/** ⌘⌥1/2/3 toggles the heading level of the selected lines. */
export const toggleHeading =
  (level: number): StateCommand =>
  ({ state, dispatch: d }) => {
    let lines = selectedLines(state)
    // Across several lines, blank ones (also bare `>` quote lines) stay blank (like the list toggle).
    if (lines.length > 1) lines = lines.filter((l) => !blankLine(l))
    if (!lines.length) return false
    const is = new RegExp(`^#{${level}}(?:[ \\t]|$)`)
    const all = lines.every((l) => !listInfo(l.text) && is.test(l.text.slice(QUOTE_RE.exec(l.text)![0].length)))
    const changes: ChangeSpec[] = lines.map((l) => {
      const { from, to } = headingSlot(l)
      return { from, to, insert: all ? '' : '#'.repeat(level) + ' ' }
    })
    const set = state.changes(changes)
    // A caret at the line's text start stays at the text start (after the new `# `).
    return dispatch(state, d, { changes: set, selection: state.selection.map(set, 1) })
  }

// ---------- lists ----------
type ListKind = 'bullet' | 'ordered' | 'task'
// Optional blockquote prefix, indentation, marker, spacing, optional checkbox.
const LIST_RE = /^((?:[ \t]*>[ \t]?)*)([ \t]*)(?:([-*+])|(\d+)([.)]))([ \t]+)(\[[ xX]\][ \t]+)?/
const QUOTE_RE = /^(?:[ \t]*>[ \t]?)*/

/** Empty after its quote marks (`>`, `> >`): the format toggles leave it alone. */
const blankLine = (l: Line) => l.text.slice(QUOTE_RE.exec(l.text)![0].length).trim() === ''

/** Offsets are relative to the line start. `indent` is the indentation inside any quote prefix. */
export function listInfo(text: string) {
  const m = LIST_RE.exec(text)
  if (!m) return null
  const kind: ListKind = m[7] ? 'task' : m[3] ? 'bullet' : 'ordered'
  const quote = m[1]
  const indent = m[2]
  const markerFrom = quote.length + indent.length
  const marker = m[3] ?? m[4] + m[5]
  return { kind, quote, indent, markerFrom, marker, markerEnd: markerFrom + marker.length + m[6].length, prefixLength: m[0].length }
}
type ListInfo = NonNullable<ReturnType<typeof listInfo>>

/** Length of the quote prefix + indentation (where block markup goes on a non-list line). */
const leadLength = (text: string) => {
  const q = QUOTE_RE.exec(text)![0].length
  return q + /^[ \t]*/.exec(text.slice(q))![0].length
}

/** Length of the heading marker (`## `) at `from` on `line`, or 0. */
const headingLength = (line: Line, from: number) => HEADING_RE.exec(line.text.slice(from - line.from))?.[0].length ?? 0

/** ⌘⇧7/8/9: set the selected lines to a list kind, or remove it when they already are. */
export const toggleList =
  (kind: ListKind): StateCommand =>
  ({ state, dispatch: d }) => {
    let lines = selectedLines(state)
    if (lines.length > 1) lines = lines.filter((l) => !blankLine(l))
    if (!lines.length) return false
    const all = lines.every((l) => listInfo(l.text)?.kind === kind)
    let n = 0
    const changes: ChangeSpec[] = lines.map((l) => {
      const info = listInfo(l.text)
      const from = l.from + (info ? info.markerFrom : leadLength(l.text))
      const to = info ? l.from + info.prefixLength : from + headingLength(l, from)
      if (all) return { from, to, insert: '' }
      n++
      const insert = kind === 'bullet' ? '- ' : kind === 'task' ? '- [ ] ' : `${n}. `
      return { from, to, insert }
    })
    return dispatch(state, d, { changes })
  }

/** The `[ ]`/`[x]` change for a task line (quoted or not), or null when the line isn't a task item. */
function flipTask(line: Line, info: ListInfo | null): ChangeSpec | null {
  if (info?.kind !== 'task') return null
  const box = line.from + info.markerEnd + 1
  return { from: box, to: box + 1, insert: /x/i.test(line.text[info.markerEnd + 1]) ? ' ' : 'x' }
}

/** Pointer toggle (rendered checkbox): flip the task on the line at `pos`. */
export function toggleTaskAt(view: EditorView, pos: number) {
  const line = view.state.doc.lineAt(pos)
  const change = inCode(view.state, line.from) ? null : flipTask(line, listInfo(line.text))
  if (!change) return false
  view.dispatch({ changes: change, userEvent: 'input.toggle' })
  return true
}

/** ⌘↩: toggle the checkbox on the current line(s), turning plain lines/bullets into tasks first. */
export const toggleTask: StateCommand = ({ state, dispatch: d }) => {
  const changes: ChangeSpec[] = []
  for (const l of selectedLines(state)) {
    if (inCode(state, l.from)) continue
    const info = listInfo(l.text)
    const flip = flipTask(l, info)
    if (flip) changes.push(flip)
    else if (info) changes.push({ from: l.from + info.markerEnd, insert: '[ ] ' })
    else {
      const from = l.from + leadLength(l.text)
      changes.push({ from, to: from + headingLength(l, from), insert: '- [ ] ' })
    }
  }
  return dispatch(state, d, { changes })
}

// ---------- Tab / Shift-Tab ----------
function previousListLine(state: EditorState, line: Line, quote: string, pred: (indent: number) => boolean) {
  for (let n = line.number - 1; n >= 1 && n >= line.number - 200; n--) {
    const l = state.doc.line(n)
    const body = l.text.startsWith(quote) ? l.text.slice(quote.length) : null
    if (body === null) return null // left the quote
    if (!body.trim()) continue
    const info = listInfo(l.text)
    if (!info || info.quote !== quote) {
      if (!/^\s/.test(body)) return null // left the list
      continue
    }
    if (pred(info.indent.length)) return { line: l, info }
  }
  return null
}

/** Tab in a list item nests it under the previous item (indent = that item's content column). */
export const indentList: StateCommand = ({ state, dispatch: d }) => {
  const lines = selectedLines(state)
  const infos = lines.map((l) => listInfo(l.text))
  if (!infos.every(Boolean)) return false
  const changes: ChangeSpec[] = []
  lines.forEach((l, i) => {
    const info = infos[i]!
    const cur = info.indent.length
    const prev = previousListLine(state, l, info.quote, (ind) => ind <= cur)
    if (!prev || prev.info.indent.length !== cur) return
    const target = prev.info.markerEnd - prev.info.quote.length
    const base = l.from + info.quote.length
    changes.push({ from: base, to: base + cur, insert: ' '.repeat(target) })
  })
  if (changes.length) dispatch(state, d, { changes })
  return true // swallow Tab in lists even when nothing can nest
}

export const outdentList: StateCommand = ({ state, dispatch: d }) => {
  const lines = selectedLines(state)
  const infos = lines.map((l) => listInfo(l.text))
  if (!infos.every(Boolean)) return false
  const changes: ChangeSpec[] = []
  lines.forEach((l, i) => {
    const info = infos[i]!
    const cur = info.indent.length
    if (!cur) return
    const base = l.from + info.quote.length
    changes.push({ from: base, to: base + cur, insert: ' '.repeat(parentIndent(state, l, info)) })
  })
  if (changes.length) dispatch(state, d, { changes })
  return true
}

function parentIndent(state: EditorState, line: Line, info: ListInfo) {
  const parent = previousListLine(state, line, info.quote, (ind) => ind < info.indent.length)
  return parent ? parent.info.indent.length : 0
}

/** The list item on this line, if it's a real one (not a `- ` inside a code block). */
function listItemAt(state: EditorState, line: Line) {
  const info = listInfo(line.text)
  return info && !inCode(state, line.from + info.markerFrom) ? info : null
}

const continueMarkup = insertNewlineContinueMarkupCommand({ nonTightLists: false })

/**
 * Enter in lists. On an empty item: nested → outdent one level; top level → leave the list, with a blank
 * line between the list and what follows (otherwise CommonMark reads the next line as a lazy continuation
 * of the last item, and the file renders differently elsewhere than in the preview). Quote prefixes are
 * kept. Otherwise Markdown continuation (next bullet/number/task) as usual.
 */
export const listEnter: StateCommand = (target) => {
  const { state, dispatch: d } = target
  const r = state.selection.main
  if (state.selection.ranges.length === 1 && r.empty) {
    const line = state.doc.lineAt(r.head)
    const above = openAbove(state, line, r.head)
    if (above) return dispatch(state, d, above)
    const info = listItemAt(state, line)
    if (info && r.head - line.from >= info.markerEnd && line.text.slice(info.prefixLength).trim() === '') {
      const cur = info.indent.length
      const base = line.from + info.quote.length
      if (cur > 0) {
        const to = parentIndent(state, line, info)
        const prefix = line.text.slice(info.markerFrom, info.prefixLength).replace(/\[[xX]\]/, '[ ]')
        return dispatch(state, d, {
          changes: { from: base, to: line.to, insert: ' '.repeat(to) + prefix },
          selection: { anchor: base + to + prefix.length },
        })
      }
      const prev = line.number > 1 ? state.doc.line(line.number - 1).text : ''
      const prevBlank = prev.slice(QUOTE_RE.exec(prev)![0].length).trim() === ''
      const insert = prevBlank ? info.quote : info.quote.trimEnd() + state.lineBreak + info.quote
      return dispatch(state, d, { changes: { from: line.from, to: line.to, insert }, selection: { anchor: line.from + insert.length } })
    }
    // Empty continuation line of a list item (`  |` under `- item` / `  ![](…)`): leave the list, as from an
    // empty item.
    const q = QUOTE_RE.exec(line.text)![0]
    const rest = line.text.slice(q.length)
    if (!info && rest !== '' && rest.trim() === '' && r.head === line.to && line.number > 1 && !inCode(state, line.from)) {
      const prev = state.doc.line(line.number - 1)
      const lead = leadLength(prev.text)
      if (lead < prev.text.length && enclosingItem(syntaxTree(state).resolveInner(prev.from + lead, 1))) {
        const insert = q ? q.trimEnd() + state.lineBreak + q : state.lineBreak
        return dispatch(state, d, { changes: { from: line.from, to: line.to, insert }, selection: { anchor: line.from + insert.length } })
      }
    }
    // Empty quote line under a quoted line: leave the quote (one level), like an empty list item leaves the
    // list — a blank line ends it, so what's typed next isn't swallowed into it.
    const quote = QUOTE_RE.exec(line.text)![0]
    if (!info && quote && line.text.slice(quote.length).trim() === '' && r.head - line.from >= quote.trimEnd().length && line.number > 1) {
      const prev = state.doc.line(line.number - 1)
      const prevQuote = QUOTE_RE.exec(prev.text)![0]
      if (prevQuote && !inCode(state, line.from)) {
        const marks = quote.match(/[ \t]*>[ \t]?/g) ?? []
        const outer = marks.slice(0, -1).join('')
        const insert = outer ? outer.trimEnd() + state.lineBreak + outer : state.lineBreak
        // A blank quote line right above (`>`) becomes the separator itself.
        const from = prevQuote.trimEnd() === quote.trimEnd() && prev.text.slice(prevQuote.length).trim() === '' ? prev.from : line.from
        return dispatch(state, d, { changes: { from, to: line.to, insert }, selection: { anchor: from + insert.length } })
      }
    }
  }
  return continueMarkup(target)
}

/** Whether `line` ends inside a paragraph, so a line right after it could be read as its continuation. */
function endsInParagraph(state: EditorState, line: Line) {
  if (line.text.slice(quoteEnd(state, line)).trim() === '') return false
  for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(line.to, -1); n; n = n.parent) {
    if (n.name === 'Paragraph') return true
  }
  return false
}

/**
 * Return with the caret at the start of a heading / list item / quote line's text (where ⌘←, Home and ⌃A land) opens a
 * line above and leaves this one intact: a blank line above a heading, an empty item with the same marker above an item
 * (ordered items renumbered), an empty quote line above a quote line. The caret stays on this line's text.
 */
function openAbove(state: EditorState, line: Line, head: number) {
  if (inCode(state, line.from) || state.doc.sliceString(head, line.to).trim() === '') return null
  const { base, start } = textStart(state, line)
  if (head !== start || start === line.from) return null
  const nl = state.lineBreak
  const quote = line.text.slice(0, quoteEnd(state, line))
  const info = listItemAt(state, line)
  let changes: ChangeSpec[]
  if (info) {
    const item = enclosingItem(syntaxTree(state).resolveInner(line.from + info.markerFrom, 1))
    if (!item || state.doc.lineAt(item.from).number !== line.number) return null
    const spacing = line.text.slice(info.markerFrom + info.marker.length, info.markerEnd)
    const empty = info.quote + info.indent + info.marker + spacing + (info.kind === 'task' ? '[ ] ' : '')
    // An empty item right under paragraph text isn't an item (it'd be a setext underline or lazy text): blank line first.
    // Not under a parent item's own text (a nested list's first item): that's still a list item, and the blank would
    // make the list loose.
    const first = item.prevSibling?.name !== 'ListItem'
    const prev = line.number > 1 ? state.doc.line(line.number - 1) : null
    const underText = prev && endsInParagraph(state, prev) && !enclosingItem(syntaxTree(state).resolveInner(prev.to, -1))
    const sep = first && underText ? info.quote.trimEnd() + nl : ''
    changes = [{ from: line.from, insert: sep + empty + nl }, ...renumberFrom(state, item)]
  } else if (start > base) {
    changes = [{ from: line.from, insert: quote.trimEnd() + nl }] // heading
  } else if (quote && start === line.from + quote.length) {
    changes = [{ from: line.from, insert: quote + nl }]
  } else return null
  const set = state.changes(changes)
  return { changes: set, selection: { anchor: set.mapPos(head, 1) } }
}

/**
 * Vim `o` / `O` on a list item or quote line: open the line below/above with the same structure Return would give —
 * the next bullet/task/number (following ordered items renumbered) or quote prefix — and the caret after it. null
 * elsewhere (headings, paragraphs, code, empty items): vim's own open-line applies.
 */
export function openLine(state: EditorState, after: boolean): TransactionSpec | null {
  const line = state.doc.lineAt(state.selection.main.head)
  if (inCode(state, line.from)) return null
  const info = listItemAt(state, line)
  const quote = quoteEnd(state, line)
  if (!info && !quote) return null
  const { base, start } = textStart(state, line)
  if (state.doc.sliceString(start, line.to).trim() === '') return null
  if (!after) {
    if (!info && start > base) return null // quoted heading: plain open-line
    const above = openAbove(state, line, start)
    if (!above) return null
    return { changes: above.changes, selection: { anchor: above.changes.mapPos(line.from, 1) - state.lineBreak.length } }
  }
  if (!info && start > base) return null // quoted heading
  const item = info ? enclosingItem(syntaxTree(state).resolveInner(line.from + info.markerFrom, 1)) : null
  const para = item?.getChild('Paragraph')
  if (info && item && para && state.doc.lineAt(para.from).number === line.number && para.to > line.to) {
    // The item's text goes on below (continuation lines): the new item goes after all of it.
    const at = state.doc.lineAt(para.to).to
    const cur = markNumber(state, item)
    const next = markNumber(state, item.nextSibling)
    const n = cur ? (next?.n === cur.n ? cur.n : cur.n + 1) : 0
    const marker = cur ? `${n}${info.marker.slice(-1)}` : info.marker
    const spacing = line.text.slice(info.markerFrom + info.marker.length, info.markerEnd)
    const insert = state.lineBreak + info.quote + info.indent + marker + spacing + (info.kind === 'task' ? '[ ] ' : '')
    const renumber = cur && next && next.n === n && n !== cur.n && item.nextSibling ? renumberFrom(state, item.nextSibling) : []
    const set = state.changes([{ from: at, insert }, ...renumber])
    return { changes: set, selection: { anchor: set.mapPos(at, 1) } }
  }
  // Like Return at the line's end.
  let out: TransactionSpec | null = null
  continueMarkup({ state: state.update({ selection: { anchor: line.to } }).state, dispatch: (tr) => (out = { changes: tr.changes, selection: tr.selection }) })
  return out
}

const markNumber = (state: EditorState, item: SyntaxNode | null) => {
  const mark = item?.name === 'ListItem' ? item.getChild('ListMark') : null
  return mark && /^\d+[.)]$/.test(state.sliceDoc(mark.from, mark.to)) ? { mark, n: Number(state.sliceDoc(mark.from, mark.to - 1)) } : null
}

/** An ordered item gets an item with its number inserted before it: it and the consecutively numbered items after it
 *  shift up by one. Lazy numbering (`1.` `1.` `1.`) stays as is. */
function renumberFrom(state: EditorState, item: SyntaxNode): ChangeSpec[] {
  const cur = markNumber(state, item)
  if (!cur || markNumber(state, item.prevSibling)?.n === cur.n) return []
  const changes: ChangeSpec[] = []
  let expect = cur.n
  for (let it: SyntaxNode | null = item; it; it = it.nextSibling) {
    const m = markNumber(state, it)
    if (!m || m.n !== expect) break
    changes.push({ from: m.mark.from, to: m.mark.to - 1, insert: String(m.n + 1) })
    expect = m.n + 1
  }
  return changes
}

/** Backspace right after a list marker: nested → outdent; top level → drop the marker. */
export const listBackspace: StateCommand = (target) => {
  const { state, dispatch: d } = target
  const r = state.selection.main
  if (state.selection.ranges.length === 1 && r.empty) {
    const line = state.doc.lineAt(r.head)
    const info = listItemAt(state, line)
    if (info && r.head - line.from === info.prefixLength) {
      const cur = info.indent.length
      const base = line.from + info.quote.length
      if (cur > 0) {
        const to = parentIndent(state, line, info)
        return dispatch(state, d, {
          changes: { from: base, to: base + cur, insert: ' '.repeat(to) },
          selection: { anchor: r.head - cur + to },
        })
      }
      return dispatch(state, d, { changes: { from: line.from + info.markerFrom, to: line.from + info.prefixLength }, selection: { anchor: line.from + info.markerFrom } })
    }
    // At a heading's text start: drop the whole `## ` like a list marker.
    if (!inCode(state, line.from)) {
      const { base, start } = textStart(state, line)
      if (r.head === start && start > base) return dispatch(state, d, { changes: { from: base, to: start }, selection: { anchor: base } })
    }
  }
  return deleteMarkupBackward(target)
}

/**
 * Typing a list marker + space at the start of an empty item (muscle memory after auto-continue) doesn't
 * double it: `- ` on an empty bullet stays one bullet, `[ ] ` on an empty task stays one task, `1. ` on a
 * bullet (or `- ` on a number) switches the kind. (`[ ] ` on a bullet naturally makes it a task.)
 */
export const absorbListMarker = EditorView.inputHandler.of((view, from, to, text) => {
  if (text !== ' ' || from !== to) return false
  const { state } = view
  if (state.selection.ranges.length > 1) return false
  const line = state.doc.lineAt(from)
  if (line.text.slice(from - line.from).trim() !== '') return false
  const before = line.text.slice(0, from - line.from)
  const info = listItemAt(state, line)
  if (!info || info.prefixLength >= before.length) return false
  const typed = before.slice(info.prefixLength)
  const typedFrom = line.from + info.prefixLength
  let changes: ChangeSpec[]
  if (/^\[[ xX]\]$/.test(typed)) {
    if (info.kind !== 'task') return false
    // The box typed wins (`[x] ` on an auto-continued `[ ]` checks it).
    const box = line.from + info.markerEnd
    const keep = state.sliceDoc(box, box + 3) === typed
    changes = keep ? [{ from: typedFrom, to: from }] : [{ from: box, to: box + 3, insert: typed }, { from: typedFrom, to: from }]
  } else if (/^(?:[-*+]|\d+[.)])$/.test(typed)) {
    const typedOrdered = /\d/.test(typed)
    const isOrdered = info.kind === 'ordered'
    changes =
      typedOrdered === isOrdered
        ? [{ from: typedFrom, to: from }]
        : [{ from: line.from + info.markerFrom, to: from, insert: typed + ' ' }]
  } else return false
  const set = state.changes(changes)
  view.dispatch({ changes: set, selection: { anchor: set.mapPos(line.to) }, userEvent: 'input.type' })
  return true
})

/** Where the hidden marker of a bullet/task item (or the hidden indentation of an item's continuation line) spans,
 *  or null if `line` is neither. */
function hiddenMarker(state: EditorState, line: Line) {
  const info = listInfo(line.text)
  if (!info) {
    const cont = continuationOf(syntaxTree(state), state.doc, line)
    return cont ? { start: line.from + cont.quote, end: line.from + cont.quote + cont.indent, quoted: cont.quote > 0 } : null
  }
  for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(line.from + info.markerFrom, 1); n; n = n.parent) {
    if (n.name === 'ListItem') {
      // Indentation is hidden too (inside a quote: after its marks, which stay real text).
      const start = line.from + info.quote.length
      // Ordered markers stay visible (editable); only their hidden indentation is skipped.
      const end = line.from + (info.kind === 'ordered' ? info.markerFrom : info.prefixLength)
      return { start, end, quoted: info.quote !== '' }
    }
    if (n.name === 'FencedCode' || n.name === 'CodeBlock') return null
  }
  return null
}

/** Length of a line's blockquote prefix (`> `, `>> `), or 0 outside quotes (quoted code keeps its quote's marks). */
const quoteEnd = (state: EditorState, line: Line) => quotePrefix(syntaxTree(state), line)

/** End of a heading's `#`s (and the spaces after them) or of an ordered item's `1. ` on `line`, when it starts at
 *  `start` (the line's visual start: after quote marks and hidden indentation). These markers stay visible and
 *  editable, so only the line's start snaps past them. null when there's none. */
function visibleMarkerEnd(state: EditorState, line: Line, start: number) {
  const info = listInfo(line.text)
  if (info?.kind === 'ordered') {
    if (line.from + info.markerFrom !== start) return null
    for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(start, 1); n; n = n.parent) {
      if (n.name === 'ListItem') return line.from + info.prefixLength
      if (n.name === 'FencedCode' || n.name === 'CodeBlock') return null
    }
    return null
  }
  const m = /^#{1,6}[ \t]+/.exec(state.doc.sliceString(start, line.to))
  if (!m) return null
  for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(start, 1); n; n = n.parent) {
    if (/^ATXHeading[1-6]$/.test(n.name)) return n.from === start ? start + m[0].length : null
    if (n.name === 'FencedCode' || n.name === 'CodeBlock' || n.name === 'Paragraph') return null
  }
  return null
}

/** Where line-start keys put the caret on `line`: past quote marks, hidden list markers and indentation, and visible
 *  heading/ordered markers — the start of the line's text. */
function textStart(state: EditorState, line: Line) {
  const m = hiddenMarker(state, line)
  const base = m ? m.end : line.from + quoteEnd(state, line)
  return { base, start: visibleMarkerEnd(state, line, base) ?? base }
}

/** Where a caret at `head` on `line` belongs when it falls inside a hidden list marker or the quote prefix, or at the
 *  very start of a heading / ordered item (the line's text start), else null. */
function snapTarget(state: EditorState, line: Line, head: number) {
  if (head - line.from > 24) return null
  const m = hiddenMarker(state, line)
  const q = quoteEnd(state, line)
  let target: number | null = null
  if (m && head >= m.start && head < m.end) target = m.end
  // Quote marks are structure too: line-start keys land after them, so typing doesn't unquote the line.
  else if (q > 0 && head < line.from + q) target = m && m.start >= line.from + q ? m.end : line.from + q
  // `# `/`1. ` stay editable text: only a caret at the line's start (⌃A, Home, ⌘←) moves past them.
  const { base, start } = textStart(state, line)
  if ((target ?? head) === base && start !== base) return start
  return target
}

/** Whether `head` is strictly inside `line`'s visible ordered marker (`2|.`, `1|0)`, `2.| `): typing there breaks the item.
 *  `orAtStart`: its start (`|2.`) counts too. */
function insideOrderedMarker(state: EditorState, line: Line, head: number, orAtStart = false) {
  if (listInfo(line.text)?.kind !== 'ordered') return false
  const { base, start } = textStart(state, line)
  return start !== base && (head > base || (orAtStart && head === base)) && head < start
}

/**
 * Mac editing (vim off): bullets and checkboxes behave like non-text. A caret that lands inside a hidden
 * marker (arrow keys, Home/⌘←, clicks in the gutter) snaps to the item's text. A selection extended back into it
 * from the same line's text (⇧⌘←, ⇧Home) stops at the text too, so typing over it keeps the marker.
 */
export const listCursorSnap = [
  EditorState.transactionFilter.of((tr) => {
    if (!tr.selection || tr.docChanged || !tr.isUserEvent('select')) return tr
    const { state } = tr
    let changed = false
    const ranges = tr.selection.ranges.map((r, i) => {
      const line = state.doc.lineAt(r.head)
      // Keyboard motion (⌥←, ↑/↓) can stop between an ordered item's number and its `.`: it goes on to the text, or —
      // moving back from this line's text — on to the end of the line above, like ← there. Clicks may edit the number.
      // ↑/↓ (and ⇧↑/⇧↓, which carry a goal column) treat the whole marker box as the marker: landing before the number
      // too goes on to the text, like a bullet's.
      const vertical = r.goalColumn !== undefined
      if (!tr.isUserEvent('select.pointer') && insideOrderedMarker(state, line, r.head, vertical)) {
        const before = tr.startState.selection.ranges[i]
        const back = !vertical && line.from > 0 && before !== undefined && before.head > r.head && before.head <= line.to
        const head = back ? line.from - 1 : textStart(state, line).start
        changed = true
        // Keep ↑/↓'s goal column, so the next vertical move continues from where it started, not from the snap.
        return r.empty ? EditorSelection.cursor(head, 0, undefined, r.goalColumn) : EditorSelection.range(r.anchor, head, r.goalColumn)
      }
      const target = snapTarget(state, line, r.head)
      if (target === null) return r
      if (r.empty) {
        changed = true
        return EditorSelection.cursor(target, 0, undefined, r.goalColumn)
      }
      // Only a range anchored in this line's text: multi-line selections (⇧↑, ⌘A, drags across lines) keep the marker.
      if (r.anchor < target || r.anchor > line.to) return r
      changed = true
      return r.anchor === target ? EditorSelection.cursor(target) : EditorSelection.range(r.anchor, target)
    })
    return changed ? [tr, { selection: EditorSelection.create(ranges, tr.selection.mainIndex), sequential: true }] : tr
  }),
  // ← (⇧←) at the start of an item's text continues to the previous line (instead of stopping behind the bullet).
  Prec.high(
    keymap.of([
      { key: 'ArrowLeft', run: (view) => leftFromTextStart(view, false) },
      { key: 'Shift-ArrowLeft', run: (view) => leftFromTextStart(view, true) },
    ]),
  ),
]

function leftFromTextStart(view: EditorView, extend: boolean) {
  const { state } = view
  const r = state.selection.main
  if (state.selection.ranges.length > 1 || (!extend && !r.empty)) return false
  const line = state.doc.lineAt(r.head)
  if (line.from === 0) return false
  const { start } = textStart(state, line)
  if (start === line.from || start !== r.head) return false
  const head = line.from - 1
  view.dispatch({ selection: extend ? { anchor: r.anchor, head } : { anchor: head }, scrollIntoView: true, userEvent: 'select' })
  return true
}

const insertSpaces: StateCommand = ({ state, dispatch: d }) => {
  if (state.selection.ranges.some((r) => !r.empty)) return indentMore({ state, dispatch: d })
  d(state.update(state.replaceSelection('  '), { scrollIntoView: true, userEvent: 'input' }))
  return true
}

/** Typing `*`, `_`, `~` or `` ` `` with text selected wraps it instead of replacing it. */
export const wrapOnType = EditorView.inputHandler.of((view, _from, _to, text) => {
  if (!['*', '_', '~', '`'].includes(text)) return false
  const { state } = view
  if (state.selection.ranges.some((r: SelectionRange) => r.empty)) return false
  if (state.readOnly) return false
  view.dispatch(
    state.changeByRange((r) => ({
      changes: [
        { from: r.from, insert: text },
        { from: r.to, insert: text },
      ],
      range: EditorSelection.range(r.from + 1, r.to + 1),
    })),
    { userEvent: 'input.type' },
  )
  return true
})

export const formatKeymap: KeyBinding[] = [
  { key: 'Mod-b', run: toggleEmphasis('bold') },
  { key: 'Mod-i', run: toggleEmphasis('italic') },
  { key: 'Mod-Shift-x', run: toggleInline('~~') },
  { key: 'Mod-e', run: toggleInline('`') },
  { key: 'Mod-Shift-k', run: insertLink }, // ⌘K is the action menu
  { key: 'Mod-Alt-1', run: toggleHeading(1) },
  { key: 'Mod-Alt-2', run: toggleHeading(2) },
  { key: 'Mod-Alt-3', run: toggleHeading(3) },
  { key: 'Mod-Shift-7', run: toggleList('ordered') },
  { key: 'Mod-Shift-8', run: toggleList('bullet') },
  { key: 'Mod-Shift-9', run: toggleList('task') },
  { key: 'Mod-Enter', run: toggleTask },
  { key: 'Enter', run: listEnter },
  { key: 'Backspace', run: listBackspace },
  { key: 'Backspace', run: deleteCharacterBackward },
  { key: 'Tab', run: indentList, shift: outdentList },
  { key: 'Tab', run: insertSpaces, shift: indentLess },
]
