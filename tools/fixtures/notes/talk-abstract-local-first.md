# talk abstract — local-first
**Your app doesn't need a server (probably)**
Most apps we build are CRUD over a network round-trip: every click waits on a server 80ms away. Local-first flips this — the data lives on the device, the UI is instant, and sync happens in the background. In this talk I'll walk through building a real app with SQLite in the browser (OPFS + wasm), a sync layer, and conflict resolution that doesn't require a PhD in CRDTs. We'll cover when local-first is the right call, when it absolutely isn't, and the sharp edges nobody puts in their blog posts.
- 25 min version for Austin, 20 min cut for the Lisbon meetup. submitted to 3 more CFPs for spring
