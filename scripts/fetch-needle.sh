#!/usr/bin/env bash
# Downloads Cactus's needle engine for macOS (Apple silicon), which runs the
# Whistle speech model for dictation. Run once when updating; the results are
# committed under Vendor/Needle. Apache-2.0: https://huggingface.co/Cactus-Compute/needle3
#
# Pinned to a revision and checked against known SHA-256 sums, so an update
# upstream can't change what Xotch builds with by surprise.
set -euo pipefail
cd "$(dirname "$0")/.."

REVISION="2ae11323dc000f5e70c49f7403efa6af12ba9e67"
SOURCE="https://huggingface.co/Cactus-Compute/needle3/resolve/$REVISION"
OUT="Vendor/Needle"
mkdir -p "$OUT"

fetch() {
  curl -fsSL "$SOURCE/$1" -o "$OUT/$2"
  local sum
  sum="$(shasum -a 256 "$OUT/$2" | cut -d' ' -f1)"
  [[ "$sum" == "$3" ]] || { echo "Checksum mismatch for $2: $sum" >&2; exit 1; }
}

fetch macos-arm64/libneedle.a libneedle.a 98da47c15e1065b4cdc7ddc55e825be78414d4586832db3becaeded39a373df4
fetch macos-arm64/needle.h needle.h 914bbd00423939b02fc349f91cdb7c12531b3f5bb7105b743e0e93c7e409d7b1
curl -fsSL "$SOURCE/LICENSE" -o "$OUT/LICENSE"
echo "Saved the needle engine to $OUT"
