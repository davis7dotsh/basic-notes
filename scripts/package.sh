#!/usr/bin/env bash
# Release build → build/dist/BasicNotes.zip (drag the .app into /Applications).
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED=build/dd-release scripts/build.sh Release
rm -rf build/dist && mkdir -p build/dist
ditto -c -k --keepParent build/dd-release/Build/Products/Release/BasicNotes.app build/dist/BasicNotes.zip
echo "packaged: build/dist/BasicNotes.zip ($(du -h build/dist/BasicNotes.zip | cut -f1))"
