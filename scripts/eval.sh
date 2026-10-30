#!/usr/bin/env bash
# Build and run the search eval harness. Args go to SearchEval (e.g. --verbose, --q "query", --scale 0, --store).
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${DERIVED:-build/dd-eval}"
[[ -x scripts/fetch-model.sh ]] && scripts/fetch-model.sh
xcodegen generate --quiet
xcodebuild -project BasicNotes.xcodeproj -scheme SearchEval -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build -quiet 2>&1 | grep -E "error|warning" | grep -v "^ *|" || true
"$DERIVED/Build/Products/Release/SearchEval" "$@"
