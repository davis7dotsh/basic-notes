// Small bottom-center toast, plus the persistent "Not saved" mark. Both are absolutely positioned, so they
// never shift layout.
let el: HTMLElement | null = null
let timer: ReturnType<typeof setTimeout> | undefined

const root = () => document.getElementById('app') ?? document.body

export function toast(text: string, tone: 'info' | 'error' = 'info') {
  if (!el) {
    el = document.createElement('div')
    el.className = 'toast'
    el.setAttribute('role', 'status')
    root().appendChild(el)
  }
  el.textContent = text
  el.dataset.tone = tone
  // Restart the fade-in even when a toast is already showing.
  el.classList.remove('show')
  void el.offsetWidth
  el.classList.add('show')
  clearTimeout(timer)
  timer = setTimeout(() => el?.classList.remove('show'), tone === 'error' ? 2600 : 1500)
}

let unsavedEl: HTMLElement | null = null

/** Quiet, persistent corner mark while edits haven't reached disk. */
export function setUnsaved(on: boolean) {
  if (!unsavedEl) {
    if (!on) return
    unsavedEl = document.createElement('div')
    unsavedEl.className = 'unsaved'
    unsavedEl.textContent = 'Not saved'
    unsavedEl.setAttribute('role', 'status')
    root().appendChild(unsavedEl)
  }
  unsavedEl.classList.toggle('show', on)
  document.documentElement.classList.toggle('has-unsaved', on)
}
