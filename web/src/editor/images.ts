import { syntaxTree } from '@codemirror/language'
import { EditorState, Line, Range, StateEffect, StateField, Transaction } from '@codemirror/state'
import { Decoration, DecorationSet, EditorView, WidgetType } from '@codemirror/view'
import type { SyntaxNode, Tree } from '@lezer/common'
import { isNative } from '../bridge/client'
import { collectDefs, decodeDestination, destination, type LinkDef, refLabel } from './imageNodes'
import { enclosingItem, itemContentIndent } from './listIndent'

// Images render as block widgets under their line. They live in a StateField (block decorations can't come
// from view plugins) and are independent of the selection, so moving the cursor never changes layout.

const MAX_H = 420

declare global {
  interface Window {
    /** Browser mock only: relative asset path -> data URL. */
    __nbmMockAssets?: Map<string, string>
  }
}

const hasScheme = (src: string) => /^[a-z][a-z0-9+.-]*:/i.test(src)

// Relative paths mean different files in different notes folders: URLs (WebKit's image cache), widget identity,
// and the size cache are all namespaced by the current folder's key (NotePayload.folder).
let folderKey = ''
/** Set before building the state of a note from `key`'s folder. */
export function setImageFolder(key: string) {
  folderKey = key
}
const isRelative = (src: string) => !(hasScheme(src) || src.startsWith('/') || src.startsWith('#'))
const sizeKey = (src: string, folder: string) => (folder && isRelative(src) ? `${folder}\u0000${src}` : src)

/** `lit%20(v2).png` → `lit (v2).png` when it holds valid `%XX` escapes (already URL-encoded); raw otherwise. */
function percentDecode(path: string) {
  if (!/%[0-9a-f]{2}/i.test(path)) return path
  try {
    return decodeURIComponent(path)
  } catch {
    return path // a literal `%` (e.g. `100%.png`)
  }
}

/** Relative file path inside the notes folder for a (decoded) destination: no `./`, no `?query`/`#fragment`, not URL-encoded. */
export function assetPath(src: string) {
  return percentDecode(src.replace(/^\.\//, '').replace(/[?#].*$/s, ''))
}

// Files replaced/deleted on disk behind our back (Swift's `assetsChanged`): each changed path gets a new revision, which
// goes into its URL (WebKit would otherwise keep showing the cached image for the same URL) and into widget identity.
// Keys are folder + case-folded path (the default macOS volume is case-insensitive); revisions never reset, so coming
// back to a folder never reuses a stale URL.
const revisions = new Map<string, number>()
/** Every relative asset path shown so far per folder key: a changed directory bumps everything under it. */
const shown = new Map<string, Set<string>>()
const revKey = (folder: string, path: string) => `${folder}\u0000${path.normalize('NFC').toLowerCase()}`

function revision(src: string, folder: string) {
  if (!isRelative(src)) return 0
  const path = assetPath(src)
  let paths = shown.get(folder)
  if (!paths) shown.set(folder, (paths = new Set()))
  paths.add(path)
  return revisions.get(revKey(folder, path)) ?? 0
}

/** Mark `paths` (relative to the current folder; a directory covers everything under it, `''` the whole folder) as
 *  changed on disk. */
export function bumpAssets(paths: string[]) {
  const changed = paths.map((p) => p.normalize('NFC').toLowerCase().replace(/\/+$/, ''))
  const hit = (path: string) => {
    const p = path.normalize('NFC').toLowerCase()
    return changed.some((c) => c === '' || p === c || p.startsWith(`${c}/`))
  }
  const targets = new Set(paths.filter((p) => p !== ''))
  for (const path of shown.get(folderKey) ?? []) if (hit(path)) targets.add(path)
  for (const path of targets) {
    const key = revKey(folderKey, path)
    revisions.set(key, (revisions.get(key) ?? 0) + 1)
  }
}

/** Markdown keeps `assets/foo.png`; the webview loads it from the notes folder via the nbm:// scheme
 *  (the handler percent-decodes the URL path, so it sees exactly `assetPath(src)`). */
export function resolveAsset(src: string, folder = folderKey, rev = revision(src, folder)) {
  if (!isRelative(src)) return src
  const path = assetPath(src)
  if (!isNative()) return window.__nbmMockAssets?.get(path) ?? path
  // `?f=`/`&r=` only bust caches (across folders / after the file changed); the scheme handler resolves the URL path alone.
  const params = [folder ? `f=${encodeURIComponent(folder)}` : '', rev ? `r=${rev}` : ''].filter(Boolean).join('&')
  return `nbm://notes/${path.split('/').map(encodeURIComponent).join('/')}${params ? `?${params}` : ''}`
}

// ---- natural-size cache so re-rendered images reserve their exact space (no jumps after first load) ----
type Size = { w: number; h: number }
const SIZE_KEY = 'nbm.imageSizes'
const sizes: Map<string, Size> = (() => {
  try {
    const raw = localStorage.getItem(SIZE_KEY)
    return new Map<string, Size>(raw ? (JSON.parse(raw) as [string, Size][]) : [])
  } catch {
    return new Map<string, Size>()
  }
})()
let persistTimer: ReturnType<typeof setTimeout> | undefined
function rememberSize(src: string, size: Size) {
  const prev = sizes.get(src)
  if (prev && prev.w === size.w && prev.h === size.h) return
  sizes.set(src, size)
  clearTimeout(persistTimer)
  persistTimer = setTimeout(() => {
    try {
      // Keep the cache bounded; data: URLs are never cached (they're huge and self-describing anyway).
      const entries = [...sizes.entries()].filter(([k]) => !k.startsWith('data:')).slice(-400)
      localStorage.setItem(SIZE_KEY, JSON.stringify(entries))
    } catch {
      /* storage unavailable — in-memory cache still works */
    }
  }, 500)
}

function applySize(img: HTMLImageElement, { w, h }: Size) {
  img.style.aspectRatio = `${w} / ${h}`
  img.style.width = `min(100%, ${w}px, ${Math.round((MAX_H * w) / h)}px)`
}

class ImageWidget extends WidgetType {
  constructor(
    readonly src: string,
    readonly alt: string,
    /** Inside a list item: the item's text column (rem), so the image sits under the item's text. */
    readonly indent = 0,
    /** Inside a blockquote: drawn in the quote's gutter, its border running through the image. */
    readonly quoted = false,
    readonly folder = folderKey,
    readonly rev = revision(src, folder),
  ) {
    super()
  }
  eq(other: ImageWidget) {
    return (
      other.src === this.src &&
      other.alt === this.alt &&
      other.indent === this.indent &&
      other.quoted === this.quoted &&
      other.folder === this.folder &&
      other.rev === this.rev
    )
  }
  private get sizeKey() {
    return sizeKey(this.src, this.folder)
  }
  get estimatedHeight() {
    const s = sizes.get(this.sizeKey)
    return s ? Math.min(MAX_H, s.h) + 12 : 160
  }
  toDOM(view: EditorView) {
    const wrap = document.createElement('div')
    wrap.className = this.quoted ? 'cm-image-block cm-image-quoted' : 'cm-image-block'
    if (this.indent) wrap.style.setProperty('--image-indent', `${this.indent}rem`)
    const img = document.createElement('img')
    img.alt = this.alt
    img.draggable = false
    img.decoding = 'async'
    const known = sizes.get(this.sizeKey)
    if (known) applySize(img, known)
    else wrap.classList.add('cm-image-loading')
    img.addEventListener('load', () => {
      const size = { w: img.naturalWidth, h: img.naturalHeight }
      if (!size.w || !size.h) return
      rememberSize(this.sizeKey, size)
      applySize(img, size)
      wrap.classList.remove('cm-image-loading')
      view.requestMeasure()
    })
    img.addEventListener('error', () => {
      wrap.classList.remove('cm-image-loading')
      wrap.classList.add('cm-image-failed')
      const chip = document.createElement('span')
      chip.className = 'cm-image-error'
      chip.textContent = hasScheme(this.src) ? (this.src.startsWith('data:') ? 'Image' : this.src) : (assetPath(this.src).split('/').pop() ?? this.src)
      wrap.replaceChildren(chip)
      view.requestMeasure()
    })
    img.src = resolveAsset(this.src, this.folder, this.rev)
    wrap.appendChild(img)
    // Clicking an image puts the cursor on its markdown line (which reveals the raw syntax).
    wrap.addEventListener('mousedown', (e) => {
      e.preventDefault()
      const pos = view.posAtDOM(wrap)
      const line = view.state.doc.lineAt(Math.min(pos, view.state.doc.length))
      view.dispatch({ selection: { anchor: line.to } })
      view.focus()
    })
    return wrap
  }
  ignoreEvent() {
    return true
  }
}

const imageLine = Decoration.line({ class: 'cm-image-line' })

// Decorations come from parsed `Image` nodes. To stay incremental, the field remembers the top-level block
// structure of the tree it was built from; on each update only blocks that were edited, or whose
// structure changed (a fence opened/closed above them, the background parse reaching them), are rescanned.

// Reference-style images (`![alt][ref]`) resolve through the doc's `[ref]: dest` definitions. Ordinary edits stay
// incremental; when an edit touches or creates a definition and the definitions actually change, everything is
// rebuilt (rare, and cheap enough).

type Block = { name: string; from: number; to: number }
type Defs = Map<string, LinkDef>
type ImageState = { deco: DecorationSet; blocks: Block[]; defs: Defs }

function topBlocks(tree: Tree) {
  const out: Block[] = []
  const c = tree.cursor()
  if (!c.firstChild()) return out
  do out.push({ name: c.name, from: c.from, to: c.to })
  while (c.nextSibling())
  return out
}

function inQuote(node: SyntaxNode) {
  for (let n = node.parent; n; n = n.parent) if (n.name === 'Blockquote') return true
  return false
}

/** Image widgets (+ the quiet line style for image-only lines) for every Image node inside [from, to].
 *  Returns whether the range holds a link reference definition. */
function scan(state: EditorState, tree: Tree, defs: Defs, from: number, to: number, out: Range<Decoration>[]) {
  const doc = state.doc
  const byLine = new Map<number, { line: Line; spans: [number, number][] }>()
  let sawDef = false
  tree.iterate({
    from,
    to,
    enter(ref) {
      const name = ref.name
      if (name === 'FencedCode' || name === 'CodeBlock' || name === 'InlineCode' || name === 'HTMLBlock') return false
      if (name === 'LinkReference') {
        sawDef = true
        return false
      }
      if (name !== 'Image') return
      if (ref.from < from || ref.to > to) return false
      const node = ref.node
      const url = node.getChild('URL')
      const label = url ? null : refLabel(doc, node)
      const src = url ? destination(doc, url).src : label ? defs.get(label)?.dest.src : undefined
      if (src === undefined) return false // undefined reference: plain text, nothing to preview
      const marks = node.getChildren('LinkMark')
      const alt = marks.length > 1 ? doc.sliceString(marks[0].to, marks[1].from) : ''
      const line = doc.lineAt(ref.to)
      // Lists inside the innermost quote indent it (enclosingItem stops at a quote); any quote draws its gutter.
      const item = enclosingItem(node)
      const indent = item ? itemContentIndent(item) : 0
      const quoted = inQuote(node)
      out.push(Decoration.widget({ widget: new ImageWidget(src, alt, indent, quoted), block: true, side: 1 }).range(line.to))
      const entry = byLine.get(line.number) ?? { line, spans: [] }
      entry.spans.push([ref.from, ref.to])
      byLine.set(line.number, entry)
      return false
    },
  })
  // A line holding only images (that start on it) shows its raw syntax small and faint.
  for (const { line, spans } of byLine.values()) {
    if (spans.some(([a]) => a < line.from)) continue
    const rest = spans.reduceRight((text, [a, b]) => text.slice(0, a - line.from) + text.slice(b - line.from), line.text)
    if (rest.trim() === '') out.push(imageLine.range(line.from))
  }
  return sawDef
}

// Past the end of the initial parse (long notes), a provisional textual guess reserves image space so a
// restored scroll position lands on the right line. The parser replaces it block by block as it gets there.
const GUESS_RE = /!\[([^\]\n]*)\]\(\s*<?([^)\s>]+)>?[^)\n]*\)/g

function guess(state: EditorState, from: number, out: Range<Decoration>[]) {
  const doc = state.doc
  if (from >= doc.length) return
  for (let n = doc.lineAt(from).number + 1; n <= doc.lines; n++) {
    const line = doc.line(n)
    if (line.text.indexOf('![') < 0) continue
    for (const m of line.text.matchAll(GUESS_RE)) {
      out.push(Decoration.widget({ widget: new ImageWidget(decodeDestination(m[2]), m[1]), block: true, side: 1 }).range(line.to))
    }
  }
}

function build(state: EditorState, defs: Defs = collectDefs(state.doc, syntaxTree(state))): ImageState {
  const tree = syntaxTree(state)
  const out: Range<Decoration>[] = []
  scan(state, tree, defs, 0, tree.length, out)
  guess(state, tree.length, out)
  return { deco: Decoration.set(out, true), blocks: topBlocks(tree), defs }
}

const sameDefs = (a: Defs, b: Defs) => a.size === b.size && [...a].every(([k, d]) => b.get(k)?.dest.src === d.dest.src)

const key = (b: Block) => `${b.name}:${b.from}:${b.to}`

/** Rebuild every image widget (after `bumpAssets`): changed files get new widgets/URLs, unchanged ones keep their DOM. */
export const refreshImages = StateEffect.define<null>()

function update(value: ImageState, tr: Transaction): ImageState {
  if (tr.effects.some((e) => e.is(refreshImages))) return build(tr.state)
  const tree = syntaxTree(tr.state)
  if (!tr.docChanged && tree === syntaxTree(tr.startState)) return value
  const changes = tr.changes
  const edited: [number, number][] = []
  changes.iterChangedRanges((_fA, _tA, fromB, toB) => void edited.push([fromB, toB]))
  const touched = (from: number, to: number) => edited.some(([a, b]) => a <= to && b >= from)

  const blocks = topBlocks(tree)
  const covered = tree.length
  const old = value.blocks
    .map((b) => ({ name: b.name, from: changes.mapPos(b.from, 1), to: changes.mapPos(b.to, -1) }))
    .filter((b) => b.to >= b.from)
  const oldKeys = new Set(old.filter((b) => !touched(b.from, b.to)).map(key))
  const newKeys = new Set(blocks.map(key))

  const dirty: [number, number][] = [...edited]
  for (const b of blocks) if (!oldKeys.has(key(b)) || touched(b.from, b.to)) dirty.push([b.from, b.to])
  for (const b of old) if (b.from < covered && !newKeys.has(key(b))) dirty.push([b.from, Math.min(b.to, covered)])
  // Past the end of a partial tree nothing is known yet: keep the old blocks (and their images) there.
  const kept = old.filter((b) => b.from >= covered)

  let deco = value.deco.map(changes)
  const doc = tr.state.doc
  const ranges = dirty
    .map(([a, b]) => [doc.lineAt(Math.min(a, doc.length)).from, doc.lineAt(Math.min(b, doc.length)).to] as [number, number])
    .sort((x, y) => x[0] - y[0])
  const merged: [number, number][] = []
  for (const r of ranges) {
    const last = merged[merged.length - 1]
    if (last && r[0] <= last[1] + 1) last[1] = Math.max(last[1], r[1])
    else merged.push([r[0], r[1]])
  }
  // Definitions as of before this change, moved to their new positions.
  const mapped: Defs = new Map()
  for (const [k, d] of value.defs) {
    const from = changes.mapPos(d.from, 1)
    const to = changes.mapPos(d.to, -1)
    mapped.set(k, { from, to: Math.max(from, to), dest: { ...d.dest, from: changes.mapPos(d.dest.from, 1), to: changes.mapPos(d.dest.to, -1) } })
  }
  let defsTouched = [...mapped.values()].some((d) => merged.some(([a, b]) => a <= d.to && b >= d.from))
  for (const [from, to] of merged) {
    const add: Range<Decoration>[] = []
    if (scan(tr.state, tree, mapped, from, to, add)) defsTouched = true
    deco = deco.update({ filter: (f) => f < from || f > to, filterFrom: from, filterTo: to, add, sort: true })
  }
  if (defsTouched) {
    const defs = collectDefs(doc, tree)
    if (!sameDefs(defs, mapped)) return build(tr.state, defs)
    return { deco, blocks: kept.length ? [...blocks, ...kept] : blocks, defs }
  }
  return { deco, blocks: kept.length ? [...blocks, ...kept] : blocks, defs: mapped }
}

export const images = StateField.define<ImageState>({
  create: (state) => build(state),
  update,
  provide: (f) => EditorView.decorations.from(f, (v) => v.deco),
})
