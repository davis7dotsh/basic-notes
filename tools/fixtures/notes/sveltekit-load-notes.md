# sveltekit load fn notes

- `+page.server.ts` → runs on server only, can hit db directly, return must be serializable (devalue, so Dates/Maps ok)
- `+page.ts` → universal, runs on server for SSR then in browser on nav
- `+layout.server.ts` data is available to all children via `data` prop / `parent()`

```ts
import type { PageServerLoad } from "./$types";
import { error } from "@sveltejs/kit";

export const load: PageServerLoad = async ({ params, locals, setHeaders }) => {
  const note = await locals.db.getNote(params.id);
  if (!note) error(404, "not found");
  setHeaders({ "cache-control": "private, max-age=0" });
  return { note, related: locals.db.related(params.id) }; // un-awaited promise streams in
};
```

- streaming: return a promise (not top-level awaited) and `{#await data.related}` in the page
- `depends("app:notes")` + `invalidate("app:notes")` to re-run after a form action
- don't call `await parent()` early, it waterfalls
- remote functions (`query`, `command`, `form`) are the new hotness, try on next project
