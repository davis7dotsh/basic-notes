# notes app ideas (raycast notes but mine)

## why
- raycast notes is 90% of what i want but: no real search, no sync to plain files, can't script it
- i want plain .md files on disk, a floating window, instant search

## v1 must-haves
- [x] global hotkey → floating window (see swift notes)
- [x] notes = .md files in `~/Notes`, first line = title
- [ ] search: hybrid
  - keyword (fts5, bm25, title boosted)
  - fuzzy title (as-you-type, typos)
  - semantic (local embeddings, small model, no network)
  - merge w/ reciprocal rank fusion, k=60
- [ ] cmd+n new, cmd+p switcher, cmd+backspace delete w/ undo
- [ ] markdown preview toggle, but editing is just text
- [ ] remember last open note + scroll position

## v2 maybe
- backlinks `[[like this]]`
- pin notes to the top
- quick capture from the menu bar w/o opening the window
- iOS reader app syncing via icloud drive folder
- "ask your notes" w/ a local LLM — careful, don't make it a chatbot

## search eval
- build a fixture corpus (~90 notes) + query set w/ categories: exact, fuzzy, code, fulltext, semantic
- metric: MRR@10 + hit@1 per category
- the semantic queries should share zero words w/ the target, otherwise it's just testing keyword search

## perf budget
- open window → focused text field: < 50ms
- keystroke → results: < 30ms for 5k notes
- embedding a note on save: async, < 200ms, never block typing

## name ideas
- floatnote (domain taken), jot, scratch, notesbutmine

## open qs
- watch the folder w/ FSEvents or just rescan on focus?
- how to handle 2 notes w/ the same title (show folder? date?)
- ship as a raycast extension first to validate? nah, the floating window is the point
