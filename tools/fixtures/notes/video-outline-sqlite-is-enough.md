# video outline: sqlite is enough

target 14-16 min. thumbnail: me + sqlite logo + "is all you need?" (no, too cliché) → "I deleted Postgres"

## hook (0:00–0:45)
- show the app: 2M rows, p99 latency 3ms, one file
- "everyone told me this wouldn't scale"
- promise: by the end you'll know exactly when you DON'T need postgres

## part 1: why people dismiss it (0:45–3:00)
- "it's a toy db" — show it's in every phone, browser, plane
- concurrency myth → WAL mode explained w/ a diagram
- single writer — fine for 99% of CRUD apps

## part 2: the setup (3:00–7:00)
- PRAGMAs: journal_mode=WAL, synchronous=NORMAL, busy_timeout=5000, foreign_keys=ON
- better-sqlite3 vs bun:sqlite vs libsql — quick benchmark
- litestream to R2 for backups → restore demo, kill the box live
- drizzle schema, same as w/ pg

## part 3: where it breaks (7:00–11:00)
- multi-region writes → turso / just use pg
- heavy analytics → duckdb
- many app servers → needs a network db
- write-heavy queue workloads
- be honest here, this is what makes the video good

## part 4: real numbers (11:00–13:30)
- k6 load test: reads/s, writes/s on a $5 hetzner box
- compare to managed pg at $25/mo

## outro (13:30–end)
- decision flowchart graphic
- CTA: repo link, next vid = local-first notes app

## b-roll / assets
- [ ] WAL diagram (excalidraw)
- [ ] flowchart graphic → ask Petra
- [ ] k6 runs recorded
- [ ] screen rec of litestream restore

## sponsor
- Branchbase?? no lol, conflicts w/ the message. use Shellby slot here
