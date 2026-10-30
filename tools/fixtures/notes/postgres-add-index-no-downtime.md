# adding an index to events table w/o downtime

events is ~180M rows, a normal create index locks writes for like 20 min. don't.

```sql
-- can't run inside a transaction block! disable the migration tool's tx wrapper
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_events_user_created
  ON events (user_id, created_at DESC);

-- check it's valid (a failed concurrent build leaves an INVALID index behind)
SELECT indexrelid::regclass, indisvalid
FROM pg_index
WHERE indrelid = 'events'::regclass;

-- if invalid:
DROP INDEX CONCURRENTLY idx_events_user_created;
```

- drizzle: put it in a custom migration w/ `-- breakpoint` and no tx
- set `statement_timeout = 0` for the session, `lock_timeout = '5s'`
- watch progress: `SELECT * FROM pg_stat_progress_create_index;`
- took 14 min on prod replica test, ~2x CPU while building
