import { send } from '../bridge/client'
import type { NoteId, SearchHit } from '../bridge/protocol'

// ⌘P overlay. Ranking is Swift's; this is the UI: query on every keystroke, stale replies dropped by
// sequence number, fixed-height rows inside a list that fills the panel (no layout shift as results change).
// With a query, the last row is always `New note “query”` — and the whole empty state when nothing matches.

export type SearchDeps = {
  open(id: NoteId): void
  create(query: string): void
  remove(id: NoteId): Promise<boolean>
  togglePin(id: NoteId): Promise<void>
  closed(): void
  /** Opened/closed (both directions, notify or not). */
  openChanged(open: boolean): void
}

const ROW_H = 52
const FIRST_RESULTS_WAIT = 90

const pinIcon = `<svg viewBox="0 0 16 16" width="11" height="11" aria-hidden="true"><path fill="currentColor" d="M9.8 1.6a.9.9 0 0 1 1.3 0l3.3 3.3a.9.9 0 0 1 0 1.3l-.6.6a.9.9 0 0 1-1 .2l-2.2 2.2.3 2.6a.9.9 0 0 1-.3.7l-.5.5a.9.9 0 0 1-1.3 0L6.4 10.6 3 14l-1-1 3.4-3.4-2.4-2.4a.9.9 0 0 1 0-1.3l.5-.5a.9.9 0 0 1 .7-.3l2.6.3 2.2-2.2a.9.9 0 0 1 .2-1z"/></svg>`
const plusIcon = `<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>`
export const searchIcon = `<svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><circle cx="7" cy="7" r="4.6" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M10.5 10.5 14 14" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>`

export function relativeTime(ms: number, now = Date.now()) {
  const d = now - ms
  if (d < 60_000) return 'now'
  if (d < 3_600_000) return `${Math.floor(d / 60_000)}m`
  const date = new Date(ms)
  const today = new Date(now)
  const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime()
  if (ms >= startOfToday) return `${Math.floor(d / 3_600_000)}h`
  if (ms >= startOfToday - 86_400_000) return 'Yesterday'
  const opts: Intl.DateTimeFormatOptions =
    date.getFullYear() === today.getFullYear() ? { month: 'short', day: 'numeric' } : { month: 'short', day: 'numeric', year: 'numeric' }
  return date.toLocaleDateString('en-US', opts)
}

function normalizeRanges(ranges: [number, number][], len: number) {
  const sorted = ranges
    .map(([a, b]) => [Math.max(0, Math.min(a, len)), Math.max(0, Math.min(b, len))] as [number, number])
    .filter(([a, b]) => b > a)
    .sort((x, y) => x[0] - y[0])
  const out: [number, number][] = []
  for (const r of sorted) {
    const last = out[out.length - 1]
    if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1])
    else out.push([r[0], r[1]])
  }
  return out
}

function highlighted(text: string, ranges: [number, number][]) {
  const frag = document.createDocumentFragment()
  let pos = 0
  for (const [a, b] of normalizeRanges(ranges, text.length)) {
    if (a > pos) frag.append(text.slice(pos, a))
    const mark = document.createElement('mark')
    mark.textContent = text.slice(a, b)
    frag.append(mark)
    pos = b
  }
  if (pos < text.length) frag.append(text.slice(pos))
  return frag
}

/**
 * Snippets are raw Markdown lines; drop the syntax (block markers, `**`, backticks, link targets…) for
 * display while remapping the highlight ranges onto the cleaned text.
 */
export function cleanSnippet(text: string, ranges: [number, number][]) {
  const keep = new Uint8Array(text.length).fill(1)
  // Backslash escapes (`\*literal\*`): the backslash goes, the escaped character always stays.
  const literal = new Uint8Array(text.length)
  for (const m of text.matchAll(/\\[!-/:-@[-`{-~]/g)) {
    const at = m.index ?? 0
    if (literal[at]) continue // `\\` escapes the backslash itself
    keep[at] = 0
    literal[at + 1] = 1
  }
  const drop = (from: number, to: number) => {
    for (let i = from; i < to; i++) if (!literal[i]) keep[i] = 0
  }
  const lead = /^\s*(?:#{1,6}\s+|>\s*)*(?:(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)?/.exec(text)
  if (lead) drop(0, lead[0].length)
  for (const m of text.matchAll(/!?\[([^\]\n]*)\]\((?:[^()\n]|\([^()\n]*\))*\)/g)) {
    const at = m.index ?? 0
    const open = m[0].startsWith('!') ? 2 : 1
    drop(at, at + open)
    drop(at + open + m[1].length, at + m[0].length)
  }
  for (const m of text.matchAll(/\*\*|__|~~|`+/g)) drop(m.index ?? 0, (m.index ?? 0) + m[0].length)
  // Single `*`/`_` emphasis markers hugging a word.
  for (const m of text.matchAll(/(?<![\w*_])[*_](?=[^\s*_])|(?<=[^\s*_])[*_](?![\w*_])/g)) drop(m.index ?? 0, (m.index ?? 0) + 1)
  const map = new Int32Array(text.length + 1)
  let out = ''
  for (let i = 0; i < text.length; i++) {
    map[i] = out.length
    if (!keep[i]) continue
    const ws = /\s/.test(text[i])
    if (ws && (out === '' || out.endsWith(' '))) continue // collapse whitespace runs
    out += ws ? ' ' : text[i]
  }
  map[text.length] = out.length
  const mapped = ranges
    .map(([a, b]) => [map[Math.max(0, Math.min(a, text.length))], map[Math.max(0, Math.min(b, text.length))]] as [number, number])
    .filter(([a, b]) => b > a)
  return { text: out, ranges: mapped }
}

/** Keep the first highlight visible in a one-line snippet: trim leading context to a word boundary. */
function windowSnippet(raw: string, rawRanges: [number, number][]) {
  const { text: clean, ranges: rs } = cleanSnippet(raw, rawRanges)
  const first = normalizeRanges(rs, clean.length)[0]
  if (!first || first[0] <= 42) return { text: clean, ranges: rs }
  let cut = first[0] - 28
  const space = clean.lastIndexOf(' ', cut + 8)
  if (space > cut - 12 && space < first[0]) cut = space + 1
  const shifted = rs.map(([a, b]) => [a - cut + 1, b - cut + 1] as [number, number])
  return { text: '…' + clean.slice(cut), ranges: shifted }
}

/** Copies the app made to keep both versions of a note look like the original; say which they are. */
const kindTag = (id: NoteId) => (id.includes('-conflict-') ? 'conflict' : id.includes('-recovered-') ? 'recovered' : null)

export function createSearch(app: HTMLElement, deps: SearchDeps) {
  const root = document.createElement('div')
  root.className = 'search'
  root.hidden = true
  root.innerHTML = `<div class="search-field">${searchIcon}<input type="text" spellcheck="false" autocomplete="off" placeholder="Search notes" aria-label="Search notes" /></div><div class="search-list" role="listbox"></div>`
  app.appendChild(root)
  const input = root.querySelector('input')!
  const list = root.querySelector<HTMLElement>('.search-list')!

  let isOpen = false
  let hits: SearchHit[] = []
  let selected = 0
  let seq = 0
  /** seq of the newest reply rendered: below `seq`, the rows on screen are for an older query. */
  let shown = 0
  /** Enter arrived while the newest query was in flight: act once its rows land. */
  let enterQueued = false
  let answered = false
  let expectLoad = false
  let lastMouse = { x: -1, y: -1 }
  let session = 0

  const query = () => input.value.trim()
  /** Hits, then the create row when there's a query. */
  const rowCount = () => hits.length + (query() ? 1 : 0)
  const onCreateRow = () => selected === hits.length && query() !== ''


  async function run(q: string, keep: { id?: NoteId; index?: number } = {}) {
    const my = ++seq
    let result: SearchHit[]
    try {
      result = await send<SearchHit[]>({ type: 'search', query: q })
    } catch {
      result = []
    }
    if (my !== seq || !isOpen) return
    shown = my
    hits = Array.isArray(result) ? result : []
    answered = true
    if (keep.id !== undefined) {
      const i = hits.findIndex((h) => h.id === keep.id)
      selected = i >= 0 ? i : Math.min(keep.index ?? 0, rowCount() - 1)
    } else if (keep.index !== undefined) selected = Math.min(keep.index, rowCount() - 1)
    else selected = 0
    selected = Math.max(0, selected)
    render()
    if (enterQueued) {
      enterQueued = false
      openSelected()
    }
  }

  function createRow(i: number) {
    const row = document.createElement('div')
    row.className = 'search-row search-create' + (i === selected ? ' selected' : '')
    row.setAttribute('role', 'option')
    row.dataset.index = String(i)
    const icon = document.createElement('span')
    icon.className = 'search-create-icon'
    icon.innerHTML = plusIcon
    const main = document.createElement('div')
    main.className = 'search-row-main search-row-title'
    const q = document.createElement('span')
    q.className = 'search-create-query'
    q.textContent = `“${query()}”`
    main.append('New note ', q)
    const hint = document.createElement('span')
    hint.className = 'search-row-meta search-create-hint'
    hint.textContent = '⌘↩'
    row.append(icon, main, hint)
    return row
  }

  function render() {
    list.textContent = ''
    if (!hits.length && !query()) {
      if (answered) {
        const empty = document.createElement('div')
        empty.className = 'search-empty'
        empty.textContent = 'No notes yet'
        list.append(empty)
      }
      return
    }
    hits.forEach((hit, i) => {
      const row = document.createElement('div')
      row.className = 'search-row' + (i === selected ? ' selected' : '')
      row.setAttribute('role', 'option')
      row.dataset.index = String(i)
      const main = document.createElement('div')
      main.className = 'search-row-main'
      const title = document.createElement('div')
      title.className = 'search-row-title'
      // Titles arrive as plain text (Swift strips the Markdown): shown as-is.
      title.append(highlighted(hit.title || 'Untitled', hit.title ? hit.titleHighlights : []))
      const s = windowSnippet(hit.snippet, hit.snippetHighlights)
      if (s.text.trim()) {
        const snippet = document.createElement('div')
        snippet.className = 'search-row-snippet'
        snippet.append(highlighted(s.text, s.ranges))
        main.append(title, snippet)
      } else main.append(title) // title-only: centered in the (fixed-height) row
      const meta = document.createElement('div')
      meta.className = 'search-row-meta'
      const tag = kindTag(hit.id)
      if (tag) {
        const el = document.createElement('span')
        el.className = 'search-row-tag'
        el.textContent = tag
        meta.append(el)
      }
      if (hit.pinned) {
        const pin = document.createElement('span')
        pin.className = 'search-row-pin'
        pin.innerHTML = pinIcon
        if (hit.pinIndex !== null && hit.pinIndex <= 9) pin.append(`⌘${(hit.pinIndex + 1) % 10}`)
        meta.append(pin)
      }
      const time = document.createElement('span')
      time.className = 'search-row-time'
      time.textContent = relativeTime(hit.modified)
      meta.append(time)
      row.append(main, meta)
      list.append(row)
    })
    if (query()) list.append(createRow(hits.length))
    reveal()
  }

  function reveal() {
    const top = selected * ROW_H
    const pad = 6
    if (top < list.scrollTop) list.scrollTop = Math.max(0, top - pad)
    else if (top + ROW_H > list.scrollTop + list.clientHeight - pad) list.scrollTop = top + ROW_H - list.clientHeight + pad * 2
  }

  function select(i: number) {
    const n = rowCount()
    if (!n) return
    const next = Math.max(0, Math.min(n - 1, i))
    if (next === selected) return
    list.children[selected]?.classList.remove('selected')
    selected = next
    list.children[selected]?.classList.add('selected')
    reveal()
  }

  async function open() {
    if (isOpen) {
      input.focus()
      input.select()
      return
    }
    isOpen = true
    const mine = ++session
    deps.openChanged(true)
    enterQueued = false
    answered = false
    hits = []
    selected = 0
    input.value = ''
    list.textContent = ''
    list.scrollTop = 0
    // Take focus now, still invisible: type-ahead lands in the query, never in the note (or as vim commands).
    root.classList.add('pending')
    root.hidden = false
    input.focus()
    const first = run('')
    // Show once the first results are in (or very soon), so the list never flashes empty.
    await Promise.race([first, new Promise((r) => setTimeout(r, FIRST_RESULTS_WAIT))])
    if (!isOpen || mine !== session) return
    root.classList.remove('pending')
    document.documentElement.classList.add('searching')
    if (document.activeElement !== input) input.focus()
  }

  function close(notify = true) {
    if (!isOpen) return
    isOpen = false
    deps.openChanged(false)
    enterQueued = false
    seq++
    root.hidden = true
    root.classList.remove('pending')
    document.documentElement.classList.remove('searching')
    if (notify) deps.closed()
  }

  const current = () => (onCreateRow() ? null : (hits[selected] ?? null))

  function openSelected() {
    if (onCreateRow()) return create()
    const hit = current()
    if (!hit) return
    close(false)
    deps.open(hit.id)
  }

  function create() {
    const q = query()
    close(false)
    deps.create(q)
  }

  input.addEventListener('input', () => void run(input.value))
  input.addEventListener('keydown', (e) => {
    const ctrl = e.ctrlKey && !e.metaKey && !e.altKey
    if (e.key !== 'Enter' && e.key !== 'Shift' && e.key !== 'Meta') enterQueued = false
    if (e.key === 'ArrowDown' || (ctrl && (e.key === 'n' || e.key === 'j'))) select(selected + 1)
    else if (e.key === 'ArrowUp' || (ctrl && (e.key === 'p' || e.key === 'k'))) select(selected - 1)
    else if (e.key === 'Enter' && e.metaKey) create()
    else if (e.key === 'Enter' && !e.isComposing) {
      if (shown !== seq) enterQueued = true // rows on screen are for an older query
      else openSelected()
    }
    else if (e.key === 'PageDown') select(selected + Math.max(1, Math.floor(list.clientHeight / ROW_H) - 1))
    else if (e.key === 'PageUp') select(selected - Math.max(1, Math.floor(list.clientHeight / ROW_H) - 1))
    else if (e.key === 'Tab') {
      /* keep focus in the field */
    } else return
    e.preventDefault()
  })

  list.addEventListener('mousemove', (e) => {
    // Only real pointer movement selects — not rows scrolling under a resting cursor.
    if (e.clientX === lastMouse.x && e.clientY === lastMouse.y) return
    lastMouse = { x: e.clientX, y: e.clientY }
    const row = e.target instanceof Element ? e.target.closest<HTMLElement>('.search-row') : null
    if (row) select(Number(row.dataset.index))
  })
  list.addEventListener('mousedown', (e) => e.preventDefault()) // keep focus in the input
  list.addEventListener('click', (e) => {
    const row = e.target instanceof Element ? e.target.closest<HTMLElement>('.search-row') : null
    if (!row) return
    selected = Number(row.dataset.index)
    openSelected()
  })

  return {
    open,
    close,
    isOpen: () => isOpen,
    toggle: () => (isOpen ? close() : void open()),
    focus: () => input.focus(),
    /** Paste-like insert into the query (replaces the input's selection). */
    insertText(text: string) {
      if (!isOpen) return
      input.focus()
      input.setRangeText(text.replace(/\s+/g, ' '), input.selectionStart ?? input.value.length, input.selectionEnd ?? input.value.length, 'end')
      void run(input.value)
    },
    /** True once if the next loadNote is a side effect of an overlay action (keep the overlay open). */
    consumeExpectedLoad() {
      const v = expectLoad
      expectLoad = false
      return v
    },
    refresh() {
      if (isOpen) void run(input.value, { id: current()?.id, index: selected })
    },
    async togglePinSelected() {
      const hit = current()
      if (!hit) return
      await deps.togglePin(hit.id)
      if (isOpen) await run(input.value, { id: hit.id, index: selected })
    },
    async deleteSelected() {
      const hit = current()
      if (!hit) return
      const index = selected
      expectLoad = true
      setTimeout(() => (expectLoad = false), 1500)
      const removed = await deps.remove(hit.id)
      if (!removed) expectLoad = false
      if (isOpen) await run(input.value, { index })
    },
  }
}

export type Search = ReturnType<typeof createSearch>
