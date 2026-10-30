import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language'
import { languages } from '@codemirror/language-data'
import { Autolink, LeafBlock, MarkdownConfig, Strikethrough, TaskList } from '@lezer/markdown'
import { tags as t } from '@lezer/highlight'

// A paragraph is one leaf block, and Lezer parses a leaf (block scan + inline parse) in a single
// uninterruptible step with no reuse inside it. A note written as thousands of consecutive lines is
// one giant paragraph, so every keystroke reparsed all of it (~40ms/key at 4k lines). Ending
// paragraphs every N lines keeps parse work local and lets incremental reuse do its job. Only
// emphasis spanning the exact chunk boundary of a >N-line paragraph renders differently.
const PARAGRAPH_CHUNK = 40
const leafLines = new WeakMap<LeafBlock, number>()
const chunkParagraphs: MarkdownConfig = {
  parseBlock: [
    {
      name: 'ChunkParagraphs',
      endLeaf(_cx, line, leaf) {
        const n = (leafLines.get(leaf) ?? 1) + 1
        leafLines.set(leaf, n)
        // Never split right before a setext underline (it would turn into an hr / stray text).
        return n > PARAGRAPH_CHUNK && !/^\s*(?:=+|-+)\s*$/.test(line.text.slice(line.pos))
      },
    },
  ],
}

// CommonMark + the small GFM subset from the spec (strike, tasks, bare-URL autolinks). No tables/footnotes.
export const markdownSupport = () => [
  markdown({
    codeLanguages: languages,
    extensions: [Strikethrough, TaskList, Autolink, chunkParagraphs],
    completeHTMLTags: false,
    addKeymap: false, // Enter/Backspace list handling lives in commands.ts
    pasteURLAsLink: true,
  }),
  // Brackets only — auto-pairing quotes is hostile in prose.
  markdownLanguage.data.of({ closeBrackets: { brackets: ['(', '[', '{'] } }),
]

const v = (name: string) => `var(--syn-${name})`

export const highlightStyle = HighlightStyle.define([
  // Markdown
  { tag: [t.heading1, t.heading2, t.heading3, t.heading4, t.heading5, t.heading6], fontWeight: '650' },
  { tag: t.strong, fontWeight: '650' },
  { tag: t.emphasis, fontStyle: 'italic' },
  { tag: t.strikethrough, textDecoration: 'line-through', textDecorationColor: 'var(--muted)' },
  { tag: t.processingInstruction, color: 'var(--faint)' },
  { tag: t.contentSeparator, color: 'var(--faint)' },
  { tag: t.url, color: 'var(--link)' },
  { tag: t.labelName, color: 'var(--muted)' },
  { tag: t.quote, color: 'var(--quote)' },
  // Code (fenced blocks)
  { tag: [t.keyword, t.controlKeyword, t.definitionKeyword, t.moduleKeyword, t.operatorKeyword, t.modifier], color: v('keyword') },
  { tag: [t.string, t.special(t.string), t.character, t.attributeValue], color: v('string') },
  { tag: t.regexp, color: v('regexp') },
  { tag: [t.number, t.bool, t.null, t.atom, t.unit], color: v('number') },
  { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: v('comment'), fontStyle: 'italic' },
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName], color: v('function') },
  { tag: [t.typeName, t.className, t.namespace, t.standard(t.variableName)], color: v('type') },
  { tag: [t.propertyName, t.attributeName], color: v('property') },
  { tag: [t.tagName, t.angleBracket], color: v('tag') },
  { tag: [t.meta, t.annotation, t.self], color: v('meta') },
  { tag: [t.definition(t.variableName), t.definition(t.propertyName)], color: v('definition') },
  { tag: t.invalid, color: v('invalid') },
])

export const highlighting = syntaxHighlighting(highlightStyle)
