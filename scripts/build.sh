#!/usr/bin/env bash
# Build web bundle + app.
# Usage: scripts/build.sh [Debug|Release] [extra xcodebuild args...]
# Env: DERIVED=<derived data dir> (default build/DerivedData; use your own when building in parallel)
#      SKIP_WEB=1 to reuse the existing App/Resources/Web bundle
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
DERIVED="${DERIVED:-build/DerivedData}"
if [[ -z "${SKIP_WEB:-}" ]]; then (cd web && bun install --silent && bun run --silent build >/dev/null); fi
[[ -x scripts/fetch-model.sh ]] && scripts/fetch-model.sh
xcodegen generate --quiet
xcodebuild -project BasicNotes.xcodeproj -scheme BasicNotes -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build -quiet "${@:2}"
echo "built: $DERIVED/Build/Products/$CONFIG/BasicNotes.app"
