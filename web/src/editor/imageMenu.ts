import { isolateHistory } from '@codemirror/commands'
import { EditorView, ViewPlugin, ViewUpdate } from '@codemirror/view'
import { isNative, send } from '../bridge/client'
import { toast } from '../ui/toast'

type ImageTarget = { from: number; to: number; src: string; folder: string; img: HTMLImageElement }

async function imagePNG(img: HTMLImageElement) {
  const canvas = document.createElement('canvas')
  canvas.width = img.naturalWidth
  canvas.height = img.naturalHeight
  const context = canvas.getContext('2d')
  if (!context || !canvas.width || !canvas.height) throw new Error('Image is unavailable')
  context.drawImage(img, 0, 0)
  return new Promise<Blob>((resolve, reject) => {
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('Could not encode image'))), 'image/png')
  })
}

async function copyImage({ src, folder, img }: ImageTarget) {
  try {
    if (isNative()) await send({ type: 'copyImage', src, folder })
    // Start the clipboard write during the click; WebKit requires user activation even when encoding is async.
    else await navigator.clipboard.write([new ClipboardItem({ 'image/png': imagePNG(img) })])
    toast('Copied image')
  } catch (error) {
    console.error('copyImage failed', error)
    toast('Couldn’t copy image', 'error')
  }
}

export const imageContextMenu = ViewPlugin.fromClass(
  class {
    menu: HTMLElement | null = null
    events: AbortController | null = null

    constructor(readonly view: EditorView) {}

    open(event: MouseEvent, target: ImageTarget) {
      this.close()
      const menu = document.createElement('div')
      menu.className = 'image-menu'
      menu.setAttribute('role', 'menu')
      menu.setAttribute('aria-label', 'Image actions')
      const button = (label: string, run: () => void) => {
        const item = document.createElement('button')
        item.type = 'button'
        item.setAttribute('role', 'menuitem')
        item.textContent = label
        item.addEventListener('click', () => {
          this.close(true)
          run()
        })
        menu.appendChild(item)
        return item
      }
      const copy = button('Copy image', () => void copyImage(target))
      copy.disabled = !target.img.complete || !target.img.naturalWidth
      const remove = button('Delete image', () => {
        this.view.dispatch({
          changes: { from: target.from, to: target.to },
          selection: { anchor: target.from },
          annotations: isolateHistory.of('full'),
          userEvent: 'delete.image',
        })
      })
      remove.className = 'image-menu-delete'
      remove.disabled = this.view.state.readOnly

      this.menu = menu
      this.events = new AbortController()
      const { signal } = this.events
      const outside = (e: Event) => {
        if (e.target instanceof Node && !menu.contains(e.target)) this.close()
      }
      document.addEventListener('pointerdown', outside, { capture: true, signal })
      document.addEventListener('contextmenu', outside, { capture: true, signal })
      document.addEventListener('focusin', outside, { signal })
      window.addEventListener('blur', () => this.close(), { signal })
      window.addEventListener('resize', () => this.close(), { signal })
      this.view.scrollDOM.addEventListener('scroll', () => this.close(), { signal })
      document.body.appendChild(menu)
      const inset = 6
      menu.style.left = `${Math.max(inset, Math.min(event.clientX, window.innerWidth - menu.offsetWidth - inset))}px`
      menu.style.top = `${Math.max(inset, Math.min(event.clientY, window.innerHeight - menu.offsetHeight - inset))}px`
      ;(copy.disabled ? remove : copy).focus({ preventScroll: true })
    }

    // Called before app shortcuts so Escape dismisses the menu without hiding the panel.
    keydown(e: KeyboardEvent) {
      if (!this.menu) return false
      if (e.key === 'Escape' || e.key === 'Tab') {
        this.close(true)
      } else if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) {
        const items = [...this.menu.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')]
        const index = items.findIndex((item) => item === document.activeElement)
        const next = e.key === 'Home' ? 0 : e.key === 'End' ? items.length - 1 : (index + (e.key === 'ArrowUp' ? -1 : 1) + items.length) % items.length
        items[next]?.focus({ preventScroll: true })
      } else {
        if (e.metaKey || e.ctrlKey) this.close(true)
        return false
      }
      e.preventDefault()
      e.stopPropagation()
      return true
    }

    close(focus = false) {
      if (!this.menu) return
      this.events?.abort()
      this.events = null
      this.menu.remove()
      this.menu = null
      if (focus) this.view.focus()
    }

    update(update: ViewUpdate) {
      // Menu ranges belong to this exact document/selection. Edits and note switches dismiss them.
      if (update.docChanged || update.selectionSet) this.close()
    }

    destroy() {
      this.close()
    }
  },
)
