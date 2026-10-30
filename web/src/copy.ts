import { Marked } from 'marked'

// ⌘⇧C: HTML rendition of the note. Image src stays relative (`assets/…`); Swift inlines everything.
// `breaks`: a single newline is a line break, as it looks in the editor.
const md = new Marked({ gfm: true, breaks: true })

/** marked passes character references in destinations through as written (`assets/A&AMP;B.png`, `&Delta;.png`),
 *  and Swift only knows a few named ones. A DOM round trip decodes every reference the way the editor does and
 *  re-serializes attributes with only the basic escapes (`&amp;`, `&quot;`, `&nbsp;`, `&lt;`, `&gt;`). */
function normalizeImageSrcs(html: string) {
  if (!/<img\b/i.test(html)) return html
  // The parsed attribute value is already decoded; serializing writes it back with plain escapes only.
  return new DOMParser().parseFromString(html, 'text/html').body.innerHTML
}

export const renderHTML = (markdown: string) => normalizeImageSrcs(md.parse(markdown, { async: false }))
