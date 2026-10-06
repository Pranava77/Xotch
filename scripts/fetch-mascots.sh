#!/usr/bin/env bash
# Downloads the page-mascot characters Xotch ships and scales them down for
# the notch. Run once when the set changes; the results are committed.
#
# page-mascot is MIT © Kamran Ahmed: https://github.com/nilbuild/page-mascot
# Each character is two 3×3 sprite sheets (nine head directions, nine
# reactions). Full size they are 1080 px square, which decodes to about
# 4.7 MB a sheet; the notch never draws a cell bigger than ~100 pt, so each
# sheet is saved as 3×3 cells of 192 px (576 px square), as HEIC: it keeps
# the transparency at about a quarter of PNG's size.
set -euo pipefail
cd "$(dirname "$0")/.."

CHARACTERS=(fox cat bunny bear frog dino hamster deer astronaut gearbot chef crt)
SOURCE="https://raw.githubusercontent.com/nilbuild/page-mascot/main"
OUT="Resources/Mascots"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"
for name in "${CHARACTERS[@]}"; do
  for sheet in directions reactions; do
    curl -fsSL "$SOURCE/public/mascots/$name-$sheet.webp" -o "$WORK/$name-$sheet.webp"
    sips -s format heic -s formatOptions 80 -z 576 576 "$WORK/$name-$sheet.webp" --out "$OUT/$name-$sheet.heic" >/dev/null
  done
  echo "  $name"
done
curl -fsSL "$SOURCE/LICENSE" -o "$OUT/LICENSE"
echo "Saved ${#CHARACTERS[@]} characters to $OUT ($(du -sh "$OUT" | cut -f1))"
