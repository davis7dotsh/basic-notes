#!/usr/bin/env bash
# Refresh the flat exports used outside the app. Xcode compiles the layered icon itself.
set -euo pipefail
cd "$(dirname "$0")/.."
exporter="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
"$exporter" App/Resources/Moonstone.icon --export-image --output-file assets/icon.png \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 --design-generation 27
sips -z 512 512 assets/icon.png --out raycast/assets/extension-icon.png >/dev/null
