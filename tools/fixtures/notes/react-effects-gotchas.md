# react effects gotchas

stuff i keep re-learning when reviewing PRs

## 1. always return the cleanup
```tsx
useEffect(() => {
  const ctrl = new AbortController();
  fetch(`/api/notes/${id}`, { signal: ctrl.signal })
    .then((r) => r.json())
    .then(setNote)
    .catch((e) => {
      if (e.name !== "AbortError") setError(e);
    });
  return () => ctrl.abort(); // useEffect cleanup — runs before next effect + on unmount
}, [id]);
```
- without the abort you get the race where id=2 resolves after id=3 and overwrites it

## 2. event listeners
```tsx
useEffect(() => {
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "k" && e.metaKey) setOpen((o) => !o);
  };
  window.addEventListener("keydown", onKey);
  return () => window.removeEventListener("keydown", onKey);
}, []);
```
- same fn reference for add/remove or it leaks

## 3. strict mode double-invokes in dev
- effects mount → unmount → mount. if your cleanup is wrong you'll see dupes immediately. this is a feature

## 4. you probably don't need the effect
- derived state → just compute it in render, or `useMemo` if expensive
- "reset state when prop changes" → use a `key` instead
- fetching → use the router's loader / react-query, not raw effects

## 5. stale closures
```tsx
useEffect(() => {
  const t = setInterval(() => setCount((c) => c + 1), 1000); // functional update, not count + 1
  return () => clearInterval(t);
}, []);
```

## 6. deps lint
- `react-hooks/exhaustive-deps` is right like 95% of the time. if you're disabling it, write a comment why

## links
- https://react.dev/learn/you-might-not-need-an-effect
- https://react.dev/learn/synchronizing-with-effects
- that Dan Abramov "complete guide to useEffect" post, still the best

## misc
- useLayoutEffect only for measuring DOM before paint (tooltips)
- `useSyncExternalStore` for subscribing to stuff outside react (window size, a store)
- refs don't trigger re-renders, don't put them in deps
- callback refs for "run when this node mounts"
- if two effects need to share a value, they probably want to be one effect
