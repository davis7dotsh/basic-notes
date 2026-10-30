import { searchIcon } from '../search/overlay'

// ⌘K action menu (Raycast-style). The actions themselves live in main.ts — each one is the same function its
// shortcut runs; this is only the list: filter, keyboard/mouse selection, run. Shares the ⌘P overlay's shell
// (`.search`, `.search-field`, `.search-list`) so both always look alike.

export type Action = {
  title: string
  section: string
  /** Shortcut keycaps, e.g. ['⌘', '⇧', 'C']. */
  keys?: string[]
  /** Extra words that find it (not highlighted). */
  keywords?: string
  run(): void
}

export type ActionsDeps = {
  /** What's available right now (labels reflect state). Read on every render. */
  actions(): Action[]
  /** Closed with focus going back (Esc, or before an action runs). */
  closed(): void
  /** Opened/closed (both directions, notify or not). */
  openChanged(open: boolean): void
}

type Match = { action: Action; score: number; marks: number[] }

/** Prefix > word start > substring > subsequence > keyword. null = no match. */
function match(action: Action, q: string): Match | null {
  const t = action.title.toLowerCase()
  const span = (i: number) => Array.from({ length: q.length }, (_, k) => i + k)
  if (t.startsWith(q)) return { action, score: 4, marks: span(0) }
  const word = t.indexOf(` ${q}`)
  if (word >= 0) return { action, score: 3, marks: span(word + 1) }
  const sub = t.indexOf(q)
  if (sub >= 0) return { action, score: 2, marks: span(sub) }
  const marks: number[] = []
  let at = 0
  for (const ch of q) {
    if (ch === ' ') continue
    at = t.indexOf(ch, at)
    if (at < 0) break
    marks.push(at++)
  }
  if (at >= 0) return { action, score: 1, marks }
  if (action.keywords?.toLowerCase().includes(q)) return { action, score: 0, marks: [] }
  return null
}

function marked(text: string, marks: number[]) {
  const frag = document.createDocumentFragment()
  const set = new Set(marks)
  let i = 0
  while (i < text.length) {
    const on = set.has(i)
    let j = i
    while (j < text.length && set.has(j) === on) j++
    if (on) {
      const m = document.createElement('mark')
      m.textContent = text.slice(i, j)
      frag.append(m)
    } else frag.append(text.slice(i, j))
    i = j
  }
  return frag
}

export function createActions(app: HTMLElement, deps: ActionsDeps) {
  const root = document.createElement('div')
  root.className = 'search actions'
  root.hidden = true
  root.innerHTML = `<div class="search-field">${searchIcon}<input type="text" spellcheck="false" autocomplete="off" placeholder="Search actions" aria-label="Search actions" /></div><div class="search-list actions-list" role="listbox"></div>`
  app.appendChild(root)
  const input = root.querySelector('input')!
  const list = root.querySelector<HTMLElement>('.search-list')!

  let isOpen = false
  let shown: Action[] = []
  let rows: HTMLElement[] = []
  let selected = 0
  let lastMouse = { x: -1, y: -1 }

  function render() {
    const q = input.value.trim().toLowerCase()
    const all = deps.actions()
    // No query: every action, in sections. A query: the matches, best first (ties keep menu order), no sections.
    const matches: Match[] = q
      ? all
          .map((a) => match(a, q))
          .filter((m) => m !== null)
          .sort((a, b) => b.score - a.score)
      : all.map((action) => ({ action, score: 0, marks: [] }))
    shown = matches.map((m) => m.action)
    rows = []
    selected = 0
    list.textContent = ''
    list.scrollTop = 0
    if (!matches.length) {
      const empty = document.createElement('div')
      empty.className = 'search-empty'
      empty.textContent = 'No matching actions'
      list.append(empty)
      return
    }
    let section = ''
    matches.forEach(({ action, marks }, i) => {
      if (!q && action.section !== section) {
        section = action.section
        const header = document.createElement('div')
        header.className = 'actions-section'
        header.textContent = section
        list.append(header)
      }
      const row = document.createElement('div')
      row.className = 'actions-row' + (i === selected ? ' selected' : '')
      row.setAttribute('role', 'option')
      row.dataset.index = String(i)
      const title = document.createElement('span')
      title.className = 'actions-row-title'
      title.append(marked(action.title, marks))
      row.append(title)
      if (action.keys) {
        const keys = document.createElement('span')
        keys.className = 'actions-keys'
        for (const k of action.keys) {
          const cap = document.createElement('kbd')
          cap.textContent = k
          keys.append(cap)
        }
        row.append(keys)
      }
      list.append(row)
      rows.push(row)
    })
  }

  function reveal() {
    const row = rows[selected]
    if (!row) return
    // A section's first row brings its header along.
    const prev = row.previousElementSibling
    const top = prev instanceof HTMLElement && prev.classList.contains('actions-section') ? prev.offsetTop : row.offsetTop
    const bottom = row.offsetTop + row.offsetHeight
    const pad = 6
    if (top < list.scrollTop + pad) list.scrollTop = Math.max(0, top - pad)
    else if (bottom > list.scrollTop + list.clientHeight - pad) list.scrollTop = bottom - list.clientHeight + pad
  }

  function select(i: number) {
    if (!rows.length) return
    const next = Math.max(0, Math.min(rows.length - 1, i))
    if (next === selected) return
    rows[selected]?.classList.remove('selected')
    selected = next
    rows[selected]?.classList.add('selected')
    reveal()
  }

  function open() {
    if (isOpen) {
      input.focus()
      input.select()
      return
    }
    isOpen = true
    deps.openChanged(true)
    input.value = ''
    render()
    root.hidden = false
    document.documentElement.classList.add('actions-open')
    input.focus()
  }

  function close(notify = true) {
    if (!isOpen) return
    isOpen = false
    deps.openChanged(false)
    root.hidden = true
    document.documentElement.classList.remove('actions-open')
    if (notify) deps.closed()
  }

  function runSelected() {
    const action = shown[selected]
    if (!action) return
    // Focus is back in the editor before the action runs (formatting applies there; vim keeps its mode).
    close()
    action.run()
  }

  input.addEventListener('input', render)
  input.addEventListener('keydown', (e) => {
    const ctrl = e.ctrlKey && !e.metaKey && !e.altKey
    const page = Math.max(1, Math.floor(list.clientHeight / 34) - 1)
    if (e.key === 'ArrowDown' || (ctrl && (e.key === 'n' || e.key === 'j'))) select(selected + 1)
    else if (e.key === 'ArrowUp' || (ctrl && (e.key === 'p' || e.key === 'k'))) select(selected - 1)
    else if (e.key === 'PageDown') select(selected + page)
    else if (e.key === 'PageUp') select(selected - page)
    else if (e.key === 'Enter' && !e.isComposing) runSelected()
    else if (e.key === 'Tab') {
      /* keep focus in the field */
    } else return
    e.preventDefault()
  })

  list.addEventListener('mousemove', (e) => {
    // Only real pointer movement selects — not rows scrolling under a resting cursor.
    if (e.clientX === lastMouse.x && e.clientY === lastMouse.y) return
    lastMouse = { x: e.clientX, y: e.clientY }
    const row = e.target instanceof Element ? e.target.closest<HTMLElement>('.actions-row') : null
    if (row) select(Number(row.dataset.index))
  })
  list.addEventListener('mousedown', (e) => e.preventDefault()) // keep focus in the input
  list.addEventListener('click', (e) => {
    const row = e.target instanceof Element ? e.target.closest<HTMLElement>('.actions-row') : null
    if (!row) return
    select(Number(row.dataset.index))
    runSelected()
  })

  return {
    open,
    close,
    isOpen: () => isOpen,
    toggle: () => (isOpen ? close() : open()),
    focus: () => input.focus(),
    /** Paste-like insert into the filter (replaces the input's selection). */
    insertText(text: string) {
      if (!isOpen) return
      input.focus()
      input.setRangeText(text.replace(/\s+/g, ' '), input.selectionStart ?? input.value.length, input.selectionEnd ?? input.value.length, 'end')
      render()
    },
  }
}
