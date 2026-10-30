# regexes i keep rewriting

## emails (good enough, not RFC 5322, don't @ me)
```
^[^\s@]+@[^\s@]+\.[^\s@]+$
```

## semver w/ optional prerelease
```
^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$
```

## youtube video id from any url format
```ts
const YT_ID = /(?:youtu\.be\/|youtube\.com\/(?:watch\?v=|shorts\/|embed\/))([\w-]{11})/;
const id = url.match(YT_ID)?.[1];
```

## markdown links → [text](url)
```ts
const MD_LINK = /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g;
for (const [, text, href] of body.matchAll(MD_LINK)) { ... }
```

## first markdown heading (for note titles)
```ts
const H1 = /^\s*#{1,6}\s+(.+?)\s*#*\s*$/m;
```

## ISO date in a filename
```
(\d{4})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])
```

## strip ANSI color codes from logs
```ts
const ANSI = /\x1b\[[0-9;]*m/g;
log.replace(ANSI, "");
```

## US phone, loose
```
^\(?(\d{3})\)?[-.\s]?(\d{3})[-.\s]?(\d{4})$
```

## trailing whitespace (vim)
```
:%s/\s\+$//e
```

## camelCase → kebab-case
```ts
s.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase();
```

## hex color
```
^#(?:[0-9a-fA-F]{3}){1,2}$
```

## lookbehind for prices w/o the $
```ts
"$42.50 and $7".match(/(?<=\$)\d+(?:\.\d{2})?/g); // ["42.50", "7"]
```

## notes to self
- `\b` doesn't work w/ unicode in JS unless you use the `u` flag + `\p{L}` tricks
- named groups: `(?<year>\d{4})` → `m.groups.year`
- regex101.com, set flavor to ECMAScript
- if the regex is longer than one line, write a parser
