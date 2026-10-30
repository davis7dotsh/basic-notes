# errors as values in TS

tiny version, when i don't want to pull in effect

```ts
export type Result<T, E> = { ok: true; value: T } | { ok: false; error: E };

export const ok = <T>(value: T) => ({ ok: true, value }) as const;
export const err = <E>(error: E) => ({ ok: false, error }) as const;

export const tryAsync = async <T>(fn: () => Promise<T>) => {
  try {
    return ok(await fn());
  } catch (e) {
    return err(e instanceof Error ? e : new Error(String(e)));
  }
};

// usage
const res = await tryAsync(() => db.query.notes.findFirst({ where: eq(notes.id, id) }));
if (!res.ok) return json({ message: res.error.message }, { status: 500 });
```

- tag errors w/ `_tag: "NotFound" | "DbDown"` so callers can switch on them exhaustively
- once there are >3 tagged errors flowing around, just use Effect
