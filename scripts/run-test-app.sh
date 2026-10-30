#!/usr/bin/env bash
# Launch an isolated, automation-enabled instance (fresh temp notes/state/defaults) and wait for its server.
# Usage: scripts/run-test-app.sh [--build] [--app PATH] [--notes DIR] [--port N] [--register]
#   --build     build first (DERIVED=build/dd-test, includes the web bundle unless SKIP_WEB=1)
#   --app       app bundle to run (default: $DERIVED/Build/Products/Debug/BasicNotes.app)
#   --notes     use this notes folder instead of a fresh temp one
#   --register  register the bundle with LaunchServices (so `open basicnotes://…` reaches it)
#   --exclusive also quit every other running BasicNotes (deeplinks then have exactly one target)
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${DERIVED:-build/dd-test}"
PORT="${NBM_AUTOMATION_PORT:-47823}"
APP="" NOTES="" BUILD=0 REGISTER=0 EXCLUSIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=1 ;;
    --app) APP="$2"; shift ;;
    --notes) NOTES="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    --register) REGISTER=1 ;;
    --exclusive) EXCLUSIVE=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
APP="${APP:-$DERIVED/Build/Products/Debug/BasicNotes.app}"
[[ $BUILD == 1 ]] && DERIVED="$DERIVED" scripts/build.sh
[[ -x "$APP/Contents/MacOS/BasicNotes" ]] || { echo "no app at $APP (use --build)" >&2; exit 1; }
APP="$(cd "$APP" && pwd)"

# One test instance per port: stop whatever holds this port plus the instance we started on it before.
# --exclusive also stops every other BasicNotes (so `open basicnotes://…` has a single target).
PIDDIR=/tmp/nbm-test-pids; mkdir -p "$PIDDIR"
victims="$(lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null || true) $(cat "$PIDDIR/$PORT.pid" 2>/dev/null || true)"
[[ $EXCLUSIVE == 1 ]] && victims="$victims $(pgrep -x BasicNotes 2>/dev/null || true)"
for pid in $victims; do ps -p "$pid" -o comm= 2>/dev/null | grep -q BasicNotes && kill "$pid" 2>/dev/null || true; done
for _ in $(seq 1 30); do alive=0; for pid in $victims; do kill -0 "$pid" 2>/dev/null && alive=1; done; [[ $alive == 0 ]] && break; sleep 0.1; done
for pid in $victims; do ps -p "$pid" -o comm= 2>/dev/null | grep -q BasicNotes && kill -9 "$pid" 2>/dev/null || true; done
rm -f "$PIDDIR/$PORT.pid"

ROOT="$(mktemp -d /tmp/nbm-test.XXXXXX)"
NOTES="${NOTES:-$ROOT/notes}"
mkdir -p "$NOTES" "$ROOT/state"
SUITE="nbm-test.${ROOT##*.}"
if [[ $REGISTER == 1 ]]; then
  # Make this bundle the only registered handler for basicnotes:// (other dev builds get unregistered;
  # LaunchServices re-registers them whenever they're launched/rebuilt).
  LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSR" -dump 2>/dev/null | sed -n 's/^path: *\(.*BasicNotes\.app\) (0x.*/\1/p' | sort -u | while read -r other; do
    [[ "$other" != "$APP" && "$other" != /Applications/* ]] && "$LSR" -u "$other" 2>/dev/null || true
  done
  "$LSR" -f "$APP"
fi

NBM_AUTOMATION=1 NBM_AUTOMATION_PORT="$PORT" NBM_NOTES_DIR="$NOTES" NBM_STATE_DIR="$ROOT/state" NBM_DEFAULTS_SUITE="$SUITE" \
  nohup "$APP/Contents/MacOS/BasicNotes" >"$ROOT/app.log" 2>&1 &
PID=$!
disown "$PID" 2>/dev/null || true
echo "$PID" > "$PIDDIR/$PORT.pid"

NBM_AUTOMATION_PORT="$PORT" "$(dirname "$0")/nbm" wait 20 || { echo "app log:"; tail -20 "$ROOT/app.log"; exit 1; }
others="$(pgrep -x BasicNotes | grep -vx "$PID" | tr '\n' ' ' || true)"
[[ -n "${others// /}" ]] && echo "note: other BasicNotes running (pids $others) — deeplinks may go there; use --exclusive" >&2
cat <<INFO
pid       $PID
port      $PORT
notes     $NOTES
state     $ROOT/state
defaults  $SUITE
log       $ROOT/app.log
INFO
