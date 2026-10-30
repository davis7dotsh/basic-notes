#!/usr/bin/env bash
# Fetch the bundled on-device embedding model into App/Resources/Models/<name>/ (gitignored).
# Idempotent: a fast no-op when the files are present and verified. No Python/conversion needed: the app runs the
# BERT forward pass itself (Accelerate) straight from the safetensors weights.
# Env: NBM_MODEL=<name> to pick another supported model (default e5-small-v2; chosen by tools/SearchEval).
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="${NBM_MODEL:-e5-small-v2}"
case "$MODEL" in
  bge-small-en-v1.5)
    REPO=BAAI/bge-small-en-v1.5; REV=5c38ec7c405ec4b44b94cc5a9bb96e735b38267a
    SHA_MODEL=3c9f31665447c8911517620762200d2245a2518d6e7208acc78cd9db317e21ad
    SHA_CONFIG=094f8e891b932f2000c92cfc663bac4c62069f5d8af5b5278c4306aef3084750
    MANIFEST='{"id":"bge-small-en-v1.5@5c38ec7","pooling":"cls","queryPrefix":"Represent this sentence for searching relevant passages: ","documentPrefix":"","simLow":0.55,"simHigh":0.70}' ;;
  snowflake-arctic-embed-s)
    REPO=Snowflake/snowflake-arctic-embed-s; REV=e596f507467533e48a2e17c007f0e1dacc837b33
    SHA_MODEL=0350e62666ee2403db0223fc7cef6293c951cc63d1d2e71468da9a5aea3b544a
    SHA_CONFIG=4e519aa92ec40943356032afe458c8829d70c5766b109e4a57490b82f72dcfb7
    MANIFEST='{"id":"snowflake-arctic-embed-s@e596f50","pooling":"cls","queryPrefix":"Represent this sentence for searching relevant passages: ","documentPrefix":""}' ;;
  e5-small-v2)
    REPO=intfloat/e5-small-v2; REV=ffb93f3bd4047442299a41ebb6fa998a38507c52
    SHA_MODEL=45bfa60070649aae2244fbc9d508537779b93b6f353c17b0f95ceccb1c5116c1
    SHA_CONFIG=5dfb0363cd0243be179c03bcaafd1542d0fbb95e8cbcf575fff3e229342adc2f
    MANIFEST='{"id":"e5-small-v2@ffb93f3","pooling":"mean","queryPrefix":"query: ","documentPrefix":"passage: ","simLow":0.80,"simHigh":0.86,"simFloor":0.80}' ;;
  *) echo "fetch-model: unknown model $MODEL" >&2; exit 1 ;;
esac
SHA_VOCAB=07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3

ROOT=App/Resources/Models
DEST="$ROOT/$MODEL"
STAMP="$DEST/.verified-$(printf '%s' "$REV$MANIFEST" | shasum | cut -c1-12)"
[[ -f "$STAMP" && -f "$DEST/model.safetensors" && -f "$DEST/manifest.json" ]] && exit 0

# Only one model is bundled: drop any other model directories.
mkdir -p "$ROOT"
find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -name "$MODEL" -exec rm -rf {} +
mkdir -p "$DEST"

fetch() { # file sha
  local f="$1" sha="$2" out="$DEST/$1"
  if [[ -f "$out" ]] && [[ "$(shasum -a 256 "$out" | cut -d' ' -f1)" == "$sha" ]]; then return; fi
  # Reuse a local copy from models-src/ if present (dev convenience), else download.
  if [[ -f "models-src/$MODEL/$f" ]] && [[ "$(shasum -a 256 "models-src/$MODEL/$f" | cut -d' ' -f1)" == "$sha" ]]; then
    cp "models-src/$MODEL/$f" "$out.part"
  else
    echo "fetch-model: downloading $REPO/$f"
    curl -fL --retry 3 --progress-bar "https://huggingface.co/$REPO/resolve/$REV/$f" -o "$out.part"
  fi
  local got; got="$(shasum -a 256 "$out.part" | cut -d' ' -f1)"
  if [[ "$got" != "$sha" ]]; then rm -f "$out.part"; echo "fetch-model: checksum mismatch for $f" >&2; exit 1; fi
  mv "$out.part" "$out"
}
fetch config.json "$SHA_CONFIG"
fetch vocab.txt "$SHA_VOCAB"
fetch model.safetensors "$SHA_MODEL"
printf '%s\n' "$MANIFEST" > "$DEST/manifest.json"
rm -f "$DEST"/.verified-*
touch "$STAMP"
echo "fetch-model: $MODEL ready in $DEST"
