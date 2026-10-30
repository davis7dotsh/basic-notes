# sqlite fts5 notes

for the notes app search

```sql
CREATE VIRTUAL TABLE notes_fts USING fts5(
  title, body,
  content='notes', content_rowid='id',
  tokenize = 'porter unicode61 remove_diacritics 2'
);

-- keep in sync w/ triggers
CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
  INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN
  INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
END;

-- weighted: title hits count 10x
SELECT id, bm25(notes_fts, 10.0, 1.0) AS score, snippet(notes_fts, 1, '<b>', '</b>', '…', 12)
FROM notes_fts WHERE notes_fts MATCH ? ORDER BY score LIMIT 20;
```

- prefix search: `'kube*'`, add `prefix='2 3'` option for speed
- the trigram tokenizer handles substring (`llama` matches `ollama`) but index is ~3x bigger
- porter stems "running" → "run" but NOT "ran"
- user input must be escaped — wrap each term in double quotes or MATCH throws on `-` and `:`
