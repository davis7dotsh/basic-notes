import { closeBrackets, closeBracketsKeymap } from '@codemirror/autocomplete'
import { defaultKeymap, history, historyKeymap, toggleBlockComment, toggleComment } from '@codemirror/commands'
import { indentUnit, syntaxTree } from '@codemirror/language'
import { Annotation, EditorSelection, EditorState, Extension, Prec, Transaction } from '@codemirror/state'
import { drawSelection, dropCursor, EditorView, keymap, placeholder, ViewPlugin, ViewUpdate } from '@codemirror/view'
import { send } from '../bridge/client'
import { absorbListMarker, formatKeymap, wrapOnType } from './commands'
import { dropImages } from './dnd'
import { historySlot, redoSelection } from './historyEdit'
import { images } from './images'
import { highlighting, markdownSupport } from './language'
import { livePreview } from './livePreview'
import { passageHighlight } from './searchPassage'
import { normalCaret, surrogateGuard } from './unicode'
import { vimCompartment, vimExtension } from './vimMode'

export type EditorHooks = {
  /** A user (or external) edit changed the doc. */
  docChanged(external: boolean): void
  /** Selection or scroll moved (for viewState persistence). */
  viewChanged(): void
  layoutChanged(view: EditorView): void
}

let hooks: EditorHooks = { docChanged() {}, viewChanged() {}, layoutChanged() {} }
let vimOn = false

/** Marks transactions that apply on-disk changes so they don't count as local edits. */
export const External = Annotation.define<boolean>()

// ⌘[ / ⌘] are app navigation, not indent; the app-level handler claims them before CM sees them. HTML comment toggles
// (⌘/, ⌃⇧A) aren't note editing, and ⌃⇧A is the Mac "select to line start".
const editingKeymap = defaultKeymap.filter(
  (b) => b.key !== 'Mod-[' && b.key !== 'Mod-]' && b.run !== toggleComment && b.run !== toggleBlockComment,
)

// The caret blinks from a timer, not CodeMirror's infinite CSS animation, which costs about twice as much
// while the panel is up (measured in the app: ~0.66% vs ~0.3% CPU). It stops when the editor isn't focused.
// styles.css turns the CSS animation off.
const BLINK_MS = 530
const caretBlink = ViewPlugin.fromClass(
  class {
    timer: ReturnType<typeof setTimeout> | undefined
    off = false
    constructor(readonly view: EditorView) {
      window.addEventListener('focus', this.restart)
      window.addEventListener('blur', this.restart)
      document.addEventListener('visibilitychange', this.restart)
      this.restart()
    }
    update(u: ViewUpdate) {
      // Solid while typing/moving, like the native caret.
      if (u.selectionSet || u.docChanged || u.focusChanged) this.restart()
    }
    restart = () => {
      clearTimeout(this.timer)
      this.timer = undefined
      this.set(false)
      if (this.view.hasFocus && document.visibilityState === 'visible') this.timer = setTimeout(this.tick, BLINK_MS)
    }
    tick = () => {
      if (!this.view.hasFocus) return this.restart()
      this.set(!this.off)
      this.timer = setTimeout(this.tick, BLINK_MS)
    }
    set(off: boolean) {
      if (off === this.off) return
      this.off = off
      this.view.dom.classList.toggle('cm-caret-off', off)
    }
    destroy() {
      clearTimeout(this.timer)
      window.removeEventListener('focus', this.restart)
      window.removeEventListener('blur', this.restart)
      document.removeEventListener('visibilitychange', this.restart)
      this.view.dom.classList.remove('cm-caret-off')
    }
  },
)

function extensions(): Extension[] {
  return [
    vimCompartment.of(vimExtension(vimOn)), // vim first so its keymap wins
    Prec.high(keymap.of(formatKeymap)),
    history(),
    historySlot.of([]),
    surrogateGuard,
    drawSelection(),
    caretBlink,
    dropCursor(),
    closeBrackets(),
    keymap.of([...closeBracketsKeymap, ...historyKeymap, ...editingKeymap]),
    EditorView.lineWrapping,
    EditorState.tabSize.of(4),
    indentUnit.of('  '),
    markdownSupport(),
    highlighting,
    livePreview,
    passageHighlight,
    images,
    wrapOnType,
    absorbListMarker,
    dropImages,
    placeholder('Start writing…'),
    EditorView.contentAttributes.of({ spellcheck: 'true', autocorrect: 'off', autocapitalize: 'off', 'aria-label': 'Note' }),
    // Keep the bottom padding in view when typing at the end of a scrolling note.
    EditorView.scrollMargins.of(() => ({ bottom: 44 })),
    // Editor exceptions (a throwing command, a decoration bug) land in the app log, not just a console nobody sees.
    EditorView.exceptionSink.of((e: unknown) => {
      console.error(e)
      const message = e instanceof Error ? `${e.message}\n${e.stack ?? ''}` : String(e)
      void send({ type: 'log', level: 'error', message: `editor exception: ${message}` }).catch(() => {})
    }),
    EditorView.updateListener.of((u) => {
      if (u.docChanged) hooks.docChanged(u.transactions.some((tr) => tr.annotation(External) === true))
      if (u.selectionSet) hooks.viewChanged()
      if (u.docChanged || u.geometryChanged || u.viewportChanged || syntaxTree(u.state) !== syntaxTree(u.startState)) hooks.layoutChanged(u.view)
    }),
    EditorView.domEventHandlers({
      scroll() {
        hooks.viewChanged()
      },
    }),
  ]
}

export function createState(doc: string, selection: EditorSelection) {
  return EditorState.create({ doc, selection, extensions: extensions() })
}

export function createEditor(parent: HTMLElement, h: EditorHooks) {
  hooks = h
  return new EditorView({
    parent,
    state: createState('', EditorSelection.single(0)),
    // Redo's selection is fixed up after the fact: history transactions skip filters, and extenders can't set a selection.
    dispatchTransactions(trs, view) {
      view.update(trs)
      const last = trs[trs.length - 1]
      const selection = last && redoSelection(last)
      if (selection) view.dispatch({ selection, annotations: Transaction.addToHistory.of(false) })
    },
  })
}

export function setVim(view: EditorView, on: boolean) {
  if (on === vimOn) return
  vimOn = on
  // Leaving vim drops any visual-block ranges: plain Mac editing is single-cursor. Entering it collapses a plain-mode
  // selection to a caret — a range in Normal mode would act as a Visual selection the indicator doesn't show.
  const main = view.state.selection.main
  const selection = on ? normalCaret(view.state.doc, main.anchor, main.head) : EditorSelection.create([main])
  view.dispatch({ effects: vimCompartment.reconfigure(vimExtension(on)), selection })
}

export const isVimOn = () => vimOn
