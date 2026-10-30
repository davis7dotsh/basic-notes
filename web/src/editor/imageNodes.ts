import type { Text } from '@codemirror/state'
import type { SyntaxNode, Tree } from '@lezer/common'
import type { ImageRef } from '../bridge/protocol'

// Image references come from the Lezer parse, never a regex: that's what keeps code (fences, spans, quoted
// fences, multi-line spans) and escaped `\![…]` out, and what handles `(balanced (parens))` destinations.

let entityEl: HTMLTextAreaElement | undefined
/** A named HTML5 entity (`amp`, `copy`, `notin`…) → its text, or null if unknown. */
function namedEntity(name: string) {
  entityEl ??= document.createElement('textarea')
  entityEl.innerHTML = `&${name};`
  const out = entityEl.value
  // Every entity is 1–2 UTF-16 units. Unknown names come back verbatim, and legacy prefixes (`&notit;` → `¬it;`)
  // keep their tail, so anything longer wasn't a real `&name;`.
  return out.length > 2 ? null : out
}

function numericEntity(digits: string, hex: boolean) {
  const cp = parseInt(digits, hex ? 16 : 10)
  return cp === 0 || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff) ? '�' : String.fromCodePoint(cp)
}

const ESCAPES = /\\([!-/:-@[-`{-~])|&(?:#([xX])([0-9a-fA-F]{1,6})|#([0-9]{1,7})|([A-Za-z][A-Za-z0-9]{1,31}));/g

/** CommonMark link destination → its literal value: backslash escapes and entity/numeric character references. */
export const decodeDestination = (s: string) =>
  s.includes('\\') || s.includes('&')
    ? s.replace(ESCAPES, (m, esc: string | undefined, x: string | undefined, hexDigits: string | undefined, dec: string | undefined, name: string | undefined) => {
        if (esc !== undefined) return esc
        if (x !== undefined && hexDigits !== undefined) return numericEntity(hexDigits, true)
        if (dec !== undefined) return numericEntity(dec, false)
        return (name !== undefined && namedEntity(name)) || m
      })
    : s

/** The destination of a `URL` node: the range inside `<…>` if bracketed (the original source text), plus its decoded value. */
export function destination(doc: Text, url: SyntaxNode): ImageRef {
  let { from, to } = url
  if (doc.sliceString(from, from + 1) === '<' && doc.sliceString(to - 1, to) === '>') {
    from++
    to--
  }
  return { from, to, src: decodeDestination(doc.sliceString(from, to)) }
}

const normLabel = (s: string) => s.replace(/^\[|\]$/g, '').trim().replace(/\s+/g, ' ').toLowerCase()

/** Label of a reference-style image: `![alt][label]`, `![label][]`, `![label]`. null if it's inline. */
export function refLabel(doc: Text, image: SyntaxNode) {
  if (image.getChild('URL')) return null
  const label = image.getChild('LinkLabel')
  const text = label ? doc.sliceString(label.from, label.to) : ''
  if (normLabel(text)) return normLabel(text)
  // Collapsed/shortcut: the alt text is the label.
  const marks = image.getChildren('LinkMark')
  if (marks.length < 2) return null
  return normLabel(doc.sliceString(marks[0].to, marks[1].from)) || null
}

const SKIP = new Set(['FencedCode', 'CodeBlock', 'InlineCode', 'HTMLBlock'])

/** A link reference definition `[label]: dest` — its whole node range and its destination. */
export type LinkDef = { from: number; to: number; dest: ImageRef }

function linkDef(doc: Text, node: SyntaxNode): [string, LinkDef] | null {
  const label = node.getChild('LinkLabel')
  const url = node.getChild('URL')
  if (!label || !url) return null
  const key = normLabel(doc.sliceString(label.from, label.to))
  return key ? [key, { from: node.from, to: node.to, dest: destination(doc, url) }] : null
}

/** Every link reference definition in the tree (first definition of a label wins). Only walks block nodes. */
export function collectDefs(doc: Text, tree: Tree) {
  const defs = new Map<string, LinkDef>()
  tree.iterate({
    enter(ref) {
      if (ref.name === 'LinkReference') {
        const def = linkDef(doc, ref.node)
        if (def && !defs.has(def[0])) defs.set(def[0], def[1])
        return false
      }
      // Definitions are blocks (top level, quotes, list items): no need to descend into leaf blocks.
      if (ref.name === 'Paragraph' || ref.name.startsWith('ATXHeading') || ref.name.startsWith('SetextHeading') || SKIP.has(ref.name)) return false
    },
  })
  return defs
}

/** Every real image in a fully parsed tree, as destination ranges (reference images point at their definition), in
 *  order of first use (`at`). */
export function collectImages(doc: Text, tree: Tree): ImageRef[] {
  const inline: ImageRef[] = []
  const labels = new Map<string, number>() // label → first use
  tree.iterate({
    enter(ref) {
      if (ref.name === 'Image') {
        const node = ref.node
        const url = node.getChild('URL')
        if (url) inline.push({ ...destination(doc, url), at: node.from })
        else {
          const label = refLabel(doc, node)
          if (label && !labels.has(label)) labels.set(label, node.from)
        }
        return
      }
      if (ref.name === 'LinkReference' || SKIP.has(ref.name)) return false
    },
  })
  const defs = collectDefs(doc, tree)
  const referenced = [...labels].flatMap(([label, at]) => {
    const dest = defs.get(label)?.dest
    return dest ? [{ ...dest, at }] : []
  })
  // De-duplicate by destination (several images may share one definition), keeping the earliest use.
  const byDest = new Map<number, ImageRef>()
  for (const r of [...inline, ...referenced]) {
    const seen = byDest.get(r.from)
    if (!seen || (r.at ?? r.from) < (seen.at ?? seen.from)) byDest.set(r.from, r)
  }
  return [...byDest.values()].sort((a, b) => (a.at ?? a.from) - (b.at ?? b.from))
}
