sql: top N per group

latest 3 videos per channel by views

```sql
SELECT *
FROM (
  SELECT
    v.*,
    ROW_NUMBER() OVER (PARTITION BY v.channel_id ORDER BY v.view_count DESC) AS rn
  FROM videos v
  WHERE v.published_at > now() - interval '90 days'
) ranked
WHERE rn <= 3;
```

- RANK() if you want ties to share a spot, DENSE_RANK() if no gaps
- postgres alt: `LATERAL` join w/ `LIMIT 3`, faster w/ an index on (channel_id, view_count desc)
- sqlite supports window fns since 3.25
