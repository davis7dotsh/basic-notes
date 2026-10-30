// Browser-only stand-in for the Swift side so the web UI can be developed/tested in a normal browser.
// Emulates: several notes, pins, back/forward history, naive search with highlights, image assets,
// trash, and the floating panel (?nopanel to disable the frame, ?vim to enable vim,
// ?note=<id> to start on a note, ?empty to start on a fresh note, ?firstrun for an empty folder; like Swift, "new
// note" on a blank new note keeps it and just sends `focus` — ?reuse=load re-sends loadNote instead).
import type { FromSwift, NoteId, NotePayload, SearchHit, ToSwift, ViewState } from './protocol'

type MockNote = { content: string; modified: number }

declare global {
  interface Window {
    __nbmMock?: {
      notes: Map<NoteId, MockNote>
      log: ToSwift[]
      current: () => NoteId
      deliver: (msg: FromSwift) => void
      /** Make the next writes fail (like an unwritable folder), for testing the failure paths. */
      fail: { save: boolean; delete: boolean }
      clipboard: string
    }
  }
}

const params = new URLSearchParams(location.search)
const H = 3_600_000
const now = Date.now()

const assets = (window.__nbmMockAssets ??= new Map<string, string>())

function demoImage(w: number, h: number, hue: number) {
  const c = document.createElement('canvas')
  c.width = w
  c.height = h
  const g = c.getContext('2d')!
  const grad = g.createLinearGradient(0, 0, w, h)
  grad.addColorStop(0, `hsl(${hue} 80% 62%)`)
  grad.addColorStop(1, `hsl(${hue + 50} 75% 45%)`)
  g.fillStyle = grad
  g.fillRect(0, 0, w, h)
  g.fillStyle = 'rgba(255,255,255,0.9)'
  g.font = `600 ${Math.round(h / 7)}px -apple-system, sans-serif`
  g.fillText(`${w}×${h}`, w * 0.08, h * 0.88)
  return c.toDataURL('image/png')
}
assets.set('assets/pasted-20261025-2130-a1b2.png', demoImage(1200, 640, 200))
assets.set('assets/pasted-20261024-0912-c3d4.png', demoImage(480, 720, 280))

function longNote() {
  const out = ['# Perf: long note', '']
  for (let i = 0; i < 5000; i++) {
    const k = i % 10
    if (k === 0) out.push(`## Section ${i / 10}`)
    else if (k === 1) out.push(`Some **bold** and _italic_ text with \`code\` and a [link](https://example.com/${i}).`)
    else if (k === 2) out.push(`- bullet item ${i}`)
    else if (k === 3) out.push(`- [${i % 20 === 3 ? 'x' : ' '}] task item ${i}`)
    else if (k === 4) out.push('```ts')
    else if (k === 5) out.push(`const value${i} = compute(${i}) // comment`)
    else if (k === 6) out.push('```')
    else if (k === 7) out.push(`> quoted line ${i}`)
    else if (k === 8) out.push(`1. ordered ${i}`)
    else out.push('')
  }
  return out.join('\n')
}

const notes = new Map<NoteId, MockNote>([
  [
    '2026-10-25-2130-demo',
    {
      modified: now - 2 * H,
      content: `# Welcome to Notes

This is a **demo** note with _emphasis_, ~~strikethrough~~, \`inline code\` and a [link](https://raycast.com).

## Tasks
- [ ] try vim with \`?vim\`
- [x] paste an image
- [ ] drag a screenshot in
  - [ ] nested task

## Lists
- First bullet that is long enough to wrap onto a second line so the hanging indent is visible
- Second
  - Nested bullet
    - Third level

1. One
2. Two
3. Three

> A blockquote that says something worth quoting, and wraps across lines when the panel is narrow.

---

\`\`\`ts
// syntax highlighting
export function greet(name: string): string {
  const n = 42
  return \`hello \${name}\` + n
}
\`\`\`

![](assets/pasted-20261025-2130-a1b2.png)

Bare URL: https://example.com/docs and www.apple.com
`,
    },
  ],
  [
    '2026-10-24-0912-meet',
    {
      modified: now - 26 * H,
      content: `Standup notes

- shipped the bridge contract
- [ ] review search ranking
- [x] fix the panel resize jitter

![](assets/pasted-20261024-0912-c3d4.png)
`,
    },
  ],
  [
    '2026-10-12-1800-trip',
    {
      modified: new Date(new Date().getFullYear(), 9, 12, 18).getTime(),
      content: `# Lisbon trip ideas

Pastéis de nata at Manteigaria. Tram 28 early in the morning. LX Factory on Sunday.
`,
    },
  ],
  [
    '2026-09-03-1100-recipe',
    {
      modified: now - 40 * 24 * H,
      content: `Sourdough schedule

Feed starter at 9pm, mix dough at 8am, bulk ferment 5h, shape, cold retard overnight. Bake 250°C covered 20 min, uncovered 25.
`,
    },
  ],
  ['2026-08-01-0800-long', { modified: now - 90 * 24 * H, content: longNote() }],
])

const pins: NoteId[] = ['2026-10-25-2130-demo', '2026-10-24-0912-meet']
const viewStates = new Map<NoteId, ViewState>()
const back: NoteId[] = []
const forward: NoteId[] = []
const log: ToSwift[] = []
let current: NoteId = params.get('note') ?? '2026-10-25-2130-demo'
if (params.has('firstrun')) notes.clear()
let vimEnabled = params.has('vim')

const deliver = (msg: FromSwift) => setTimeout(() => window.__nbm?.receive(msg), 0)
const mock = { notes, log, current: () => current, deliver, fail: { save: false, delete: false }, clipboard: '' }
window.__nbmMock = mock

const pinIndex = (id: NoteId) => {
  const i = pins.indexOf(id)
  return i < 0 ? null : i
}

const payload = (id: NoteId, isNew = false): NotePayload => ({
  id,
  content: notes.get(id)?.content ?? '',
  pinned: pinIndex(id) !== null,
  pinIndex: pinIndex(id),
  isNew,
  viewState: viewStates.get(id) ?? null,
  canGoBack: back.length > 0,
  canGoForward: forward.length > 0,
})

function show(id: NoteId, isNew = false) {
  current = id
  deliver({ type: 'loadNote', note: payload(id, isNew) })
}

function navigate(id: NoteId, isNew = false) {
  if (id !== current) {
    back.push(current)
    forward.length = 0
  }
  show(id, isNew)
}

const titleOf = (content: string) => (content.split('\n').find((l) => l.trim()) ?? '').replace(/^#+\s*/, '').trim()

function rangesOf(text: string, terms: string[]) {
  const lower = text.toLowerCase()
  const out: [number, number][] = []
  for (const t of terms) {
    for (let i = lower.indexOf(t); i >= 0; i = lower.indexOf(t, i + t.length)) out.push([i, i + t.length])
  }
  return out
}

function search(query: string): SearchHit[] {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  const hits: SearchHit[] = []
  for (const [id, n] of notes) {
    const title = titleOf(n.content) || 'Untitled'
    const lines = n.content.split('\n')
    const body = lines.slice(lines.findIndex((l) => l.trim()) + 1)
    const lower = n.content.toLowerCase()
    if (terms.length && !terms.every((t) => lower.includes(t))) continue
    const snippetLine = terms.length
      ? (body.find((l) => terms.some((t) => l.toLowerCase().includes(t))) ?? body.find((l) => l.trim()) ?? '')
      : (body.find((l) => l.trim()) ?? '')
    const snippet = snippetLine.replace(/^[#>\-*\s[\]x]+/, '').trim()
    const titleHighlights = rangesOf(title, terms)
    const pinned = pinIndex(id) !== null
    hits.push({
      id,
      title,
      snippet,
      snippetHighlights: rangesOf(snippet, terms),
      titleHighlights,
      modified: n.modified,
      pinned,
      pinIndex: pinIndex(id),
      matchKind: !terms.length ? 'recent' : titleHighlights.length ? 'title' : 'text',
      score: (titleHighlights.length ? 10 : 1) + n.modified / 1e13,
    })
  }
  if (!terms.length) {
    return hits.sort((a, b) => {
      if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
      if (a.pinned && b.pinned) return (a.pinIndex ?? 0) - (b.pinIndex ?? 0)
      return b.modified - a.modified
    })
  }
  return hits.sort((a, b) => b.score - a.score)
}

// ---- panel emulation: the 300×700 floating panel (44px native header + webview) ----
function frame() {
  if (params.has('nopanel')) return
  const style = document.createElement('style')
  style.textContent = `
    html.mock-panel, html.mock-panel body { background: light-dark(#d9dde3, #0b0b0c); }
    html.mock-panel body { display: flex; justify-content: center; align-items: flex-start; padding-top: 48px; }
    html.mock-panel #app { width: 300px; height: 700px; flex: none; border-radius: 12px; overflow: hidden;
      background: light-dark(rgba(255,255,255,.78), rgba(30,30,31,.78));
      box-shadow: 0 0 0 0.5px rgba(0,0,0,.25), 0 18px 50px rgba(0,0,0,.28); }
    html.mock-panel .editor-host, html.mock-panel .search { top: 44px; }
    html.mock-panel .editor-host { position: absolute; left: 0; right: 0; bottom: 0; height: auto; }
  `
  document.head.appendChild(style)
  document.documentElement.classList.add('mock-panel')
}

export async function mockSend(msg: ToSwift): Promise<unknown> {
  log.push(msg)
  switch (msg.type) {
    case 'ready':
      frame()
      deliver({ type: 'init', settings: { vimEnabled } })
      if (params.has('empty') || params.has('firstrun')) {
        current = `mock-${Date.now()}`
        show(current, true)
      } else show(current)
      return null
    case 'save':
      if (mock.fail.save) throw new Error('mock: You don’t have permission to save the file.')
      notes.set(msg.id, { content: msg.content, modified: Date.now() })
      return { ok: true }
    case 'viewState':
      viewStates.set(msg.id, msg.viewState)
      return null
    case 'search':
      return search(msg.query)
    case 'open':
      navigate(msg.id)
      return null
    case 'newNote':
      if (!(notes.get(current)?.content ?? '').trim() && current.startsWith('mock-')) {
        // Already on a blank new note: Swift keeps it.
        if (params.get('reuse') === 'load') show(current, true)
        else deliver({ type: 'focus' })
        return null
      }
      navigate(`mock-${Date.now()}`, true)
      return null
    case 'deleteNote': {
      if (mock.fail.delete) throw new Error('mock: couldn’t move to Trash')
      notes.delete(msg.id)
      const p = pins.indexOf(msg.id)
      if (p >= 0) pins.splice(p, 1)
      if (msg.id === current) {
        const next = [...notes.entries()].sort((a, b) => b[1].modified - a[1].modified)[0]?.[0]
        if (next) show(next)
        else show(`mock-${Date.now()}`, true)
      }
      return { ok: true }
    }
    case 'togglePin': {
      const p = pins.indexOf(msg.id)
      if (p >= 0) pins.splice(p, 1)
      else pins.push(msg.id)
      for (const id of [msg.id, ...pins]) deliver({ type: 'pinState', id, pinned: pinIndex(id) !== null, pinIndex: pinIndex(id) })
      return { pinned: pinIndex(msg.id) !== null, pinIndex: pinIndex(msg.id) }
    }
    case 'openPin': {
      const id = pins[msg.index]
      if (id) navigate(id)
      return null
    }
    case 'back': {
      const id = back.pop()
      if (id) {
        forward.push(current)
        show(id)
      }
      return null
    }
    case 'forward': {
      const id = forward.pop()
      if (id) {
        back.push(current)
        show(id)
      }
      return null
    }
    case 'saveImage': {
      const path = `assets/${msg.filename?.replace(/[^\w.-]/g, '-') ?? `pasted-${Date.now()}.png`}`
      assets.set(path, `data:${msg.mime};base64,${msg.base64}`)
      return { path }
    }
    case 'copyNote':
      console.info('[mock] copyNote', msg.markdown.length, 'chars markdown,', msg.html.length, 'chars html,', msg.images.length, 'images')
      return { ok: true }
    case 'setClipboard':
      mock.clipboard = msg.text
      return null
    case 'openSettings':
      vimEnabled = !vimEnabled // handy for testing: ⌘, toggles vim in the mock
      deliver({ type: 'settings', settings: { vimEnabled } })
      return null
    default:
      console.debug('[mock bridge]', msg)
      return null
  }
}
