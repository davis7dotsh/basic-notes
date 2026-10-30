import { syntaxTree } from '@codemirror/language'
import { EditorState, Range, RangeSet } from '@codemirror/state'
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType } from '@codemirror/view'
import type { SyntaxNode } from '@lezer/common'
import { send } from '../bridge/client'
import { toggleTaskAt } from './commands'
import { refLabel } from './imageNodes'
import { images } from './images'
import { continuationOf, INDENT_W, itemContentIndent, listDepth, MARKER_W, orderedMarkerW } from './listIndent'
import { vimState } from './vimMode'

// Obsidian-style hybrid preview. The doc is always plain Markdown; this plugin only hides/restyles syntax.
// Rule: markup on a line touching the selection is revealed (muted); everywhere else it's hidden.
// Exceptions: list bullets/checkboxes stay rendered unless the cursor is literally inside the marker, and
// fenced-code fences reveal when the selection touches any line of the block.
// Only the visible ranges are decorated, so cost is independent of note length.

type Span = { from: number; to: number }

const hidden = Decoration.replace({})
const muted = Decoration.mark({ class: 'cm-md-mark' })
// Revealed list markers keep the rendered marker's width so the item text doesn't shift.
const mutedBullet = Decoration.mark({ class: 'cm-md-mark cm-li-raw cm-li-raw-bullet' })
const mutedTask = Decoration.mark({ class: 'cm-md-mark cm-li-raw cm-li-raw-task' })
const inlineCode = Decoration.mark({ class: 'cm-inline-code' })
const taskDone = Decoration.mark({ class: 'cm-task-done' })
const headingLine = [1, 2, 3, 4].map((n) => Decoration.line({ class: `cm-h cm-h${n}` }))
const setextUnderline = Decoration.line({ class: 'cm-setext-underline' })
// Hidden underline: the line collapses, so a setext heading sits on the page exactly like an ATX one.
const setextCollapsed = Decoration.line({ class: 'cm-setext-underline cm-setext-collapsed' })
const quoteLine = Decoration.line({ class: 'cm-quote' })
const hrLine = Decoration.line({ class: 'cm-hr' })
const codeLine = {
  single: Decoration.line({ class: 'cm-codeblock cm-codeblock-begin cm-codeblock-end' }),
  begin: Decoration.line({ class: 'cm-codeblock cm-codeblock-begin' }),
  end: Decoration.line({ class: 'cm-codeblock cm-codeblock-end' }),
  middle: Decoration.line({ class: 'cm-codeblock' }),
}

// A code line's wrapped rows continue under its indentation (YAML keeps its shape in a narrow panel), not at the block's
// left edge. Leading spaces only: a tab's width depends on where its tab stop falls.
const codeHangCache = new Map<number, Decoration>()
function codeHang(cols: number) {
  let d = codeHangCache.get(cols)
  if (!d) {
    d = Decoration.line({ attributes: { style: `padding-left:calc(14px + ${cols}ch);text-indent:-${cols}ch` } })
    codeHangCache.set(cols, d)
  }
  return d
}

// List lines get a hanging indent so wrapped text aligns with the item's text, not the bullet. Quoted: on top of
// the quote's own gutter (.cm-quote padding), like continuation lines.
const listLineCache = new Map<string, Decoration>()
function listLine(depth: number, markerEm: number, quoted: boolean) {
  const key = `${depth}:${markerEm}:${quoted}`
  let d = listLineCache.get(key)
  if (!d) {
    const pad = depth * INDENT_W + markerEm
    const padding = quoted ? `calc(14px + ${pad}em)` : `${pad}em`
    d = Decoration.line({ class: 'cm-li', attributes: { style: `padding-left:${padding};text-indent:-${markerEm}em` } })
    listLineCache.set(key, d)
  }
  return d
}

// An item's indented continuation lines (`  ![](…)`, a second line of text) sit at the item's text column.
// rem, not em: image-only lines use a smaller font.
const contLineCache = new Map<string, Decoration>()
function contLine(pad: number, quoted: boolean) {
  const key = `${pad}:${quoted}`
  let d = contLineCache.get(key)
  if (!d) {
    // Quoted: on top of the quote's own gutter (.cm-quote padding).
    const style = quoted ? `padding-left:calc(14px + ${pad}rem)` : `padding-left:${pad}rem`
    d = Decoration.line({ class: 'cm-li-cont', attributes: { style } })
    contLineCache.set(key, d)
  }
  return d
}

class BulletWidget extends WidgetType {
  constructor(readonly depth: number) {
    super()
  }
  eq(o: BulletWidget) {
    return o.depth === this.depth
  }
  toDOM() {
    const el = document.createElement('span')
    el.className = `cm-bullet cm-bullet-${this.depth % 3}`
    el.setAttribute('aria-hidden', 'true')
    return el
  }
}

class CheckboxWidget extends WidgetType {
  constructor(readonly checked: boolean) {
    super()
  }
  eq(o: CheckboxWidget) {
    return o.checked === this.checked
  }
  toDOM(view: EditorView) {
    const el = document.createElement('span')
    el.className = 'cm-task-box' + (this.checked ? ' cm-task-box-checked' : '')
    el.setAttribute('role', 'checkbox')
    el.setAttribute('aria-checked', String(this.checked))
    // Inline SVG (not a CSS background) so the check never pops in a frame late.
    el.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 8.4 6.7 11 12 5.4"/></svg>'
    el.addEventListener('mousedown', (e) => {
      e.preventDefault()
      e.stopPropagation()
      toggleTaskAt(view, view.posAtDOM(el))
    })
    return el
  }
  ignoreEvent() {
    return true
  }
}

class LangLabelWidget extends WidgetType {
  constructor(readonly lang: string) {
    super()
  }
  eq(o: LangLabelWidget) {
    return o.lang === this.lang
  }
  toDOM() {
    const el = document.createElement('span')
    el.className = 'cm-code-lang'
    el.textContent = this.lang
    return el
  }
}

const linkMarks = new Map<string, Decoration>()
function linkMark(href: string) {
  let d = linkMarks.get(href)
  if (!d) {
    if (linkMarks.size > 2000) linkMarks.clear()
    d = Decoration.mark({ class: 'cm-link', attributes: { 'data-href': href } })
    linkMarks.set(href, d)
  }
  return d
}

function activeSpans(state: EditorState, focused: boolean): Span[] {
  if (!focused) return []
  return state.selection.ranges.map((r) => ({ from: state.doc.lineAt(r.from).from, to: state.doc.lineAt(r.to).to }))
}

function build(view: EditorView) {
  const { state } = view
  const { doc } = state
  const focused = view.hasFocus
  const spans = activeSpans(state, focused)
  const sel = state.selection.ranges
  const touches = (from: number, to: number) => spans.some((s) => s.from <= to && s.to >= from)
  const lineActive = (pos: number) => {
    const l = doc.lineAt(pos)
    return touches(l.from, l.to)
  }
  // Vim's block cursor sits *on* a character, so a cursor at the marker start counts as inside.
  const vim = vimState(view)
  const block = vim !== null && !vim.insertMode
  /** Cursor inside (from, to), or a non-empty selection overlapping it. */
  const selectionInside = (from: number, to: number) =>
    focused && sel.some((r) => (r.empty ? (block ? r.head >= from : r.head > from) && r.head < to : r.from < to && r.to > from))

  const deco: Range<Decoration>[] = []
  const atomic: Range<Decoration>[] = []
  const hide = (from: number, to: number, widget?: WidgetType) => {
    if (to <= from) return
    const d = widget ? Decoration.replace({ widget }) : hidden
    deco.push(d.range(from, to))
    atomic.push(d.range(from, to))
  }
  const markOrHide = (from: number, to: number, active: boolean) => {
    if (to <= from) return
    if (active) deco.push(muted.range(from, to))
    else hide(from, to)
  }

  const ranges = view.visibleRanges
  if (!ranges.length) return { deco: Decoration.none, atomic: Decoration.none }
  const visFrom = ranges[0].from
  const visTo = ranges[ranges.length - 1].to

  syntaxTree(state).iterate({
    from: visFrom,
    to: visTo,
    enter: (ref) => {
      const name = ref.name
      switch (name) {
        case 'ATXHeading1':
        case 'ATXHeading2':
        case 'ATXHeading3':
        case 'ATXHeading4':
        case 'ATXHeading5':
        case 'ATXHeading6': {
          const level = Math.min(4, Number(name.slice(-1)))
          deco.push(headingLine[level - 1].range(doc.lineAt(ref.from).from))
          return
        }
        case 'SetextHeading1':
        case 'SetextHeading2': {
          const level = name === 'SetextHeading1' ? 1 : 2
          const first = doc.lineAt(ref.from).number
          const last = doc.lineAt(ref.to).number
          for (let n = first; n < last; n++) deco.push(headingLine[level - 1].range(doc.line(n).from))
          // The `===`/`---` underline (and its line) disappears unless the heading is being edited.
          const mark = ref.node.getChild('HeaderMark')
          const active = touches(doc.line(first).from, doc.line(last).to)
          deco.push((mark && !active ? setextCollapsed : setextUnderline).range(doc.line(last).from))
          if (mark) markOrHide(mark.from, mark.to, active)
          return
        }
        case 'HeaderMark': {
          const parent = ref.node.parent
          if (!parent || parent.name.startsWith('Setext')) return // handled with the heading
          const line = doc.lineAt(ref.from)
          const active = touches(line.from, line.to)
          if (ref.from === parent.from) {
            // Leading `#`s plus the following space.
            const end = doc.sliceString(ref.to, ref.to + 1) === ' ' ? ref.to + 1 : ref.to
            markOrHide(ref.from, end, active)
          } else {
            // Optional closing `#`s plus the whitespace before them.
            let start = ref.from
            while (start > line.from && /\s/.test(doc.sliceString(start - 1, start))) start--
            markOrHide(start, ref.to, active)
          }
          return
        }
        case 'EmphasisMark':
        case 'StrikethroughMark':
          markOrHide(ref.from, ref.to, lineActive(ref.from))
          return
        case 'InlineCode': {
          const node = ref.node
          const marks = node.getChildren('CodeMark')
          const innerFrom = marks[0]?.to ?? ref.from
          const innerTo = marks.length > 1 ? marks[marks.length - 1].from : ref.to
          if (innerTo > innerFrom) deco.push(inlineCode.range(innerFrom, innerTo))
          const active = lineActive(ref.from) || lineActive(ref.to)
          for (const m of marks) markOrHide(m.from, m.to, active)
          return false
        }
        case 'FencedCode':
          fencedCode(ref.node)
          return false
        case 'CodeBlock': {
          // Indented code: same block styling, nothing to hide but a quote's marks.
          const first = doc.lineAt(ref.from).number
          const last = doc.lineAt(ref.to).number
          codeLines(first, last, ref.node)
          quoteMarks(ref.node)
          return false
        }
        case 'Link':
          link(ref.node)
          return
        case 'Image': {
          // `![x]` with no `[x]: …` definition isn't an image — leave it as the text it is.
          const label = refLabel(doc, ref.node)
          if (label !== null && !state.field(images, false)?.defs.has(label)) return false
          const active = lineActive(ref.from) || lineActive(ref.to)
          markOrHide(ref.from, ref.to, active)
          return false
        }
        case 'Autolink': {
          // <https://…>
          const node = ref.node
          const url = node.getChild('URL')
          const active = lineActive(ref.from)
          if (url) deco.push(linkMark(doc.sliceString(url.from, url.to)).range(url.from, url.to))
          for (const m of node.getChildren('LinkMark')) markOrHide(m.from, m.to, active)
          return false
        }
        case 'URL': {
          const parent = ref.node.parent?.name
          if (parent === 'Link' || parent === 'Image' || parent === 'Autolink') return
          deco.push(linkMark(doc.sliceString(ref.from, ref.to)).range(ref.from, ref.to))
          return
        }
        case 'ListMark':
          listMark(ref.node)
          return
        case 'Blockquote': {
          const first = doc.lineAt(Math.max(ref.from, visFrom)).number
          const last = doc.lineAt(Math.min(ref.to, visTo)).number
          for (let n = first; n <= last; n++) deco.push(quoteLine.range(doc.line(n).from))
          return
        }
        case 'QuoteMark':
          quoteMark(ref.from, ref.to)
          return
        case 'HorizontalRule': {
          const line = doc.lineAt(ref.from)
          if (touches(line.from, line.to)) deco.push(muted.range(ref.from, ref.to))
          else {
            deco.push(hrLine.range(line.from))
            hide(ref.from, ref.to)
          }
          return
        }
        case 'Escape':
          // `\*` reads as a plain `*`: the backslash hides off-line and is muted on the edited line.
          markOrHide(ref.from, ref.from + 1, lineActive(ref.from))
          return
        default:
          return
      }
    },
  })

  function codeLines(first: number, last: number, node: SyntaxNode) {
    const from = Math.max(first, doc.lineAt(visFrom).number)
    const to = Math.min(last, doc.lineAt(visTo).number)
    // (Not inside a list item or quote: their lines have their own indent.)
    const hang = node.parent?.name === 'Document'
    for (let n = from; n <= to; n++) {
      const d = first === last ? codeLine.single : n === first ? codeLine.begin : n === last ? codeLine.end : codeLine.middle
      const line = doc.line(n)
      deco.push(d.range(line.from))
      const cols = hang ? /^ */.exec(line.text)![0].length : 0
      if (cols && cols < line.length) deco.push(codeHang(cols).range(line.from))
    }
  }

  function quoteMark(from: number, to: number) {
    const end = doc.sliceString(to, to + 1) === ' ' ? to + 1 : to
    markOrHide(from, end, lineActive(from))
  }

  /** Code inside a quote: its lines' quote marks read like any quote line's, not as code. */
  function quoteMarks(node: SyntaxNode) {
    for (const m of node.getChildren('QuoteMark')) quoteMark(m.from, m.to)
  }

  function fencedCode(node: SyntaxNode) {
    const firstLine = doc.lineAt(node.from)
    const lastLine = doc.lineAt(node.to)
    codeLines(firstLine.number, lastLine.number, node)
    quoteMarks(node)
    const active = touches(firstLine.from, lastLine.to)
    const marks = node.getChildren('CodeMark')
    const open = marks[0]
    const close = marks.length > 1 ? marks[marks.length - 1] : null
    const info = node.getChild('CodeInfo')
    if (!open) return
    if (active) {
      deco.push(muted.range(open.from, open.to))
      if (info) deco.push(muted.range(info.from, info.to))
      if (close) deco.push(muted.range(close.from, close.to))
      return
    }
    const lang = info ? doc.sliceString(info.from, info.to).trim().split(/\s/)[0] : ''
    hide(open.from, firstLine.to, lang ? new LangLabelWidget(lang) : undefined)
    if (close) {
      const closeLine = doc.lineAt(close.from)
      if (closeLine.number !== firstLine.number) hide(close.from, closeLine.to)
    }
  }

  function link(node: SyntaxNode) {
    const marks = node.getChildren('LinkMark')
    if (marks.length < 2) return
    const url = node.getChild('URL')
    const textFrom = marks[0].to
    const textTo = marks[1].from
    const active = lineActive(node.from) || lineActive(node.to)
    const href = url ? doc.sliceString(url.from, url.to) : null
    if (href && textTo > textFrom) deco.push(linkMark(href).range(textFrom, textTo))
    if (!active && href && textTo > textFrom) {
      hide(node.from, textFrom)
      hide(textTo, node.to)
    } else {
      if (textFrom > node.from) deco.push(muted.range(node.from, textFrom))
      if (node.to > textTo) deco.push(muted.range(textTo, node.to))
    }
  }

  function listMark(mark: SyntaxNode) {
    const item = mark.parent
    const list = item?.parent
    if (!item || !list) return
    const depth = listDepth(item)
    const line = doc.lineAt(mark.from)
    // Only quote marks and indentation before the marker (not a parent item's marker on the same line): the
    // indentation is hidden and the line gets the item's hanging indent.
    const lead = doc.sliceString(line.from, mark.from)
    const quote = /^(?:[ \t]*>[ \t]?)*/.exec(lead)![0].length
    const indentOnly = /^[ \t]*$/.test(lead.slice(quote))
    const quoted = quote > 0
    // Content starts after the marker's whitespace (1–4 spaces).
    let contentFrom = mark.to
    while (contentFrom < line.to && contentFrom - mark.to < 4 && /[ \t]/.test(doc.sliceString(contentFrom, contentFrom + 1))) contentFrom++
    if (contentFrom === mark.to) return // bare `-` with nothing after: not a rendered bullet yet

    const task = item.getChild('Task')
    const taskMarker = task?.getChild('TaskMarker')
    if (task && taskMarker && doc.lineAt(taskMarker.from).number === line.number) {
      const end = /[ \t]/.test(doc.sliceString(taskMarker.to, taskMarker.to + 1)) ? taskMarker.to + 1 : taskMarker.to
      const checked = /x/i.test(doc.sliceString(taskMarker.from, taskMarker.to))
      if (indentOnly) {
        hide(line.from + quote, mark.from)
        deco.push(listLine(depth, MARKER_W, quoted).range(line.from))
      }
      if (selectionInside(mark.from, end)) deco.push(mutedTask.range(mark.from, end))
      else hide(mark.from, end, new CheckboxWidget(checked))
      if (checked && task.to > end) deco.push(taskDone.range(end, Math.min(task.to, line.to)))
      return
    }

    if (list.name === 'BulletList') {
      if (indentOnly) {
        hide(line.from + quote, mark.from)
        deco.push(listLine(depth, MARKER_W, quoted).range(line.from))
      }
      if (selectionInside(mark.from, contentFrom)) deco.push(mutedBullet.range(mark.from, contentFrom))
      else hide(mark.from, contentFrom, new BulletWidget(depth))
      return
    }

    // Ordered: keep the number visible (it carries meaning), just align it. The number and its spacing sit in a box
    // exactly as wide as the hanging indent, so the text (and its wrapped lines) start at the same column whatever
    // the glyphs measure.
    if (indentOnly) {
      const markerEm = orderedMarkerW(mark.to - mark.from - 1)
      hide(line.from + quote, mark.from)
      deco.push(listLine(depth, markerEm, quoted).range(line.from))
      deco.push(olBox(markerEm).range(mark.from, contentFrom))
    }
    deco.push(olMarker.range(mark.from, mark.to))
  }

  // Indented continuation lines of list items: drop the raw indentation, align with the item's text. An
  // indented blank line right after an item (the caret line after an image) gets the same, so typing on it
  // doesn't move anything.
  const tree = syntaxTree(state)
  for (const { from, to } of ranges) {
    for (let pos = from; pos <= to; ) {
      const line = doc.lineAt(pos)
      pos = line.to + 1
      const cont = continuationOf(tree, doc, line)
      if (!cont) continue
      deco.push(contLine(itemContentIndent(cont.item), cont.quote > 0).range(line.from))
      hide(line.from + cont.quote, line.from + cont.quote + cont.indent)
    }
  }

  return { deco: Decoration.set(deco, true), atomic: Decoration.set(atomic, true) }
}

const olMarker = Decoration.mark({ class: 'cm-ol-marker' })
const olBoxCache = new Map<number, Decoration>()
function olBox(em: number) {
  let d = olBoxCache.get(em)
  if (!d) {
    d = Decoration.mark({ class: 'cm-ol-box', attributes: { style: `min-width:${em}em` }, inclusive: false })
    olBoxCache.set(em, d)
  }
  return d
}

function normalizeHref(href: string) {
  if (/^www\./i.test(href)) return `https://${href}`
  if (/^[^@\s/:]+@[^@\s/]+\.[^@\s/]+$/.test(href)) return `mailto:${href}`
  return href
}

export const livePreview = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet
    atomic: RangeSet<Decoration>
    constructor(view: EditorView) {
      const r = build(view)
      this.decorations = r.deco
      this.atomic = r.atomic
    }
    update(u: ViewUpdate) {
      if (
        u.docChanged ||
        u.viewportChanged ||
        u.selectionSet ||
        u.focusChanged ||
        syntaxTree(u.state) !== syntaxTree(u.startState)
      ) {
        const r = build(u.view)
        this.decorations = r.deco
        this.atomic = r.atomic
      }
    }
  },
  {
    decorations: (p) => p.decorations,
    provide: (plugin) =>
      EditorView.atomicRanges.of((view) => view.plugin(plugin)?.atomic ?? Decoration.none),
    eventHandlers: {
      mousedown(e) {
        if (e.button !== 0 || !(e.target instanceof Element)) return false
        // Plain click edits (places the caret, revealing the syntax); ⌘-click opens.
        if (!e.metaKey) return false
        const href = e.target.closest<HTMLElement>('.cm-link')?.dataset.href
        if (!href) return false
        e.preventDefault()
        void send({ type: 'openURL', url: normalizeHref(href) })
        return true
      },
    },
  },
)
