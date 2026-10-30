import type { Line, Text } from '@codemirror/state'
import type { SyntaxNode, Tree } from '@lezer/common'

// Rendered list geometry (in em of the body font), shared by item lines, their continuation lines and image
// blocks inside items. Bullets and checkboxes share one marker width so task text lines up with bullet text.
export const MARKER_W = 1.5
export const INDENT_W = 1.5

const isList = (n: SyntaxNode) => n.name === 'BulletList' || n.name === 'OrderedList'

/** Nesting depth of a list item's list (0 = top level). */
export function listDepth(item: SyntaxNode) {
  let depth = 0
  for (let p = item.parent?.parent ?? null; p; p = p.parent) if (isList(p)) depth++
  return depth
}

/** Width of an ordered marker like `12. ` (number, delimiter, space): the box it renders in (`.cm-ol-box`), a little
 *  wider than the glyphs (tabular digits ≈0.6em, `. ` ≈0.53em in the UI font), so text starts exactly here. At least
 *  the bullet/checkbox width: a short number right-aligns into it, so `1.` text shares the bullet and task text column. */
export const orderedMarkerW = (digits: number) => Math.max(MARKER_W, Math.round((digits * 0.61 + 0.56) * 100) / 100)

/** Where an item's text starts, in em: its depth's indent plus its marker. */
export function itemContentIndent(item: SyntaxNode) {
  const mark = item.getChild('ListMark')
  const marker = item.parent?.name === 'OrderedList' && mark && !item.getChild('Task') ? orderedMarkerW(mark.to - mark.from - 1) : MARKER_W
  return listDepth(item) * INDENT_W + marker
}

/** The innermost list item containing `node` (not crossing code blocks), or null. */
export function enclosingItem(node: SyntaxNode | null) {
  for (let n = node; n; n = n.parent) {
    if (n.name === 'ListItem') return n
    if (n.name === 'FencedCode' || n.name === 'CodeBlock' || n.name === 'Blockquote') return null
  }
  return null
}

const leadWidth = (text: string) => /^[ \t]*/.exec(text)![0].length

/** Length of a line's blockquote prefix (`> `, `>> `): as many marks as the line has enclosing quotes, 0 outside
 *  quotes. Inside quoted code only the quote's own marks count (a `>` in the code is code). */
export function quotePrefix(tree: Tree, line: Line) {
  const at = /^[ \t]*>/.exec(line.text)
  if (!at) return 0
  let depth = 0
  for (let n: SyntaxNode | null = tree.resolveInner(line.from + at[0].length - 1, 1); n; n = n.parent) {
    if (n.name === 'Blockquote') depth++
  }
  if (!depth) return 0
  return new RegExp(`^(?:[ \\t]*>[ \\t]?){1,${depth}}`).exec(line.text)?.[0].length ?? 0
}

/** An indented continuation line of a list item (a second line of text, `  ![](…)`, or an indented blank line right
 *  after an item): its leading whitespace (after any quote marks, `quote` chars) is hidden and it sits at the item's
 *  text column. null otherwise. */
export function continuationOf(tree: Tree, doc: Text, line: Line) {
  const quote = quotePrefix(tree, line)
  const rest = line.text.slice(quote)
  const indent = leadWidth(rest)
  if (!indent) return null
  const itemAt = (l: Line) => {
    const q = quotePrefix(tree, l)
    const w = q + leadWidth(l.text.slice(q))
    return w === l.text.length ? null : enclosingItem(tree.resolveInner(l.from + w, 1))
  }
  let item: SyntaxNode | null
  if (indent < rest.length) {
    item = itemAt(line)
    if (item && doc.lineAt(item.from).number === line.number) item = null
  } else {
    item = line.number > 1 ? itemAt(doc.line(line.number - 1)) : null
  }
  return item ? { item, quote, indent } : null
}
