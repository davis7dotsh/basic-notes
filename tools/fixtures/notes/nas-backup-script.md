# backup script for the nas

runs nightly via launchd (see the plist note). syncs ~/Developer + photos export to the synology over tailscale

```bash
#!/usr/bin/env bash
set -euo pipefail

NAS_HOST="nas.example-tailnet.ts.net"
DEST="/volume1/backups/studio"
LOG="$HOME/Library/Logs/nas-backup.log"

exec >>"$LOG" 2>&1
echo "=== $(date -Iseconds) start ==="

if ! tailscale ping -c 1 --timeout=5s "$NAS_HOST" >/dev/null; then
  echo "nas unreachable, bailing"
  exit 1
fi

rsync -avh --delete \
  --exclude 'node_modules/' \
  --exclude '.svelte-kit/' \
  --exclude 'target/' \
  --exclude 'DerivedData/' \
  "$HOME/Developer/" "admin@$NAS_HOST:$DEST/developer/"

rsync -avh "$HOME/Pictures/export/" "admin@$NAS_HOST:$DEST/photos/"

echo "=== $(date -Iseconds) done ==="
```

- ssh key auth already set up (`~/.ssh/id_ed25519_nas`)
- first run took 3h, nightly is ~4 min
- TODO: healthchecks.io ping at the end so i know when it silently stops
