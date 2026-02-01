#!/usr/bin/env bash
set -euo pipefail

ROMDIR="$HOME/RetroPie/roms/arcade"
PLATFORM="mame"
SCRAPER="screenscraper"   # arcadedb for metadata; screenscraper for art
LIST="$HOME/favorites_mame.txt"

# Force where gamelist/media get generated (so we know where to look)
OUTDIR="$HOME/RetroPie/roms/arcade"
MARQ_DIR="$OUTDIR/media/marquees"

SCRAPE_FLAGS=(
  --flags videos
  --flags noresize
  --flags onlymissing
)

GEN_FLAGS=(
  --flags videos
)

mkdir -p "$(dirname "$LIST")"

if (( $# == 0 )); then
  echo "Usage: $(basename "$0") <rom.zip> [more.zip ...]"
  exit 2
fi

# Add ROMs to persistent include list
for rom in "$@"; do
  [[ -e "$ROMDIR/$rom" ]] || { echo "ERROR: ROM not found: $ROMDIR/$rom"; exit 3; }
  echo "$rom" >> "$LIST"
done

# Deduplicate
sort -u "$LIST" -o "$LIST"

echo "==> Scraping missing assets (no resize)"
Skyscraper -p "$PLATFORM" -s "$SCRAPER" -i "$ROMDIR" \
  "${SCRAPE_FLAGS[@]}" \
  --includefrom "$LIST"

echo "==> Generating gamelist/media into: $OUTDIR"
Skyscraper -p "$PLATFORM" -s cache -i "$ROMDIR" -g "$OUTDIR" \
  "${GEN_FLAGS[@]}" \
  --includefrom "$LIST"

# Archive the generated gamelist with a timestamp
if [[ -f "$OUTDIR/gamelist.xml" ]]; then
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  mv "$OUTDIR/gamelist.xml" "$OUTDIR/gamelist_$TIMESTAMP.xml"
  echo "==> Archived gamelist to: gamelist_$TIMESTAMP.xml"
fi

# echo
# echo "==> Marquee resolutions in: $MARQ_DIR"
# if [[ ! -d "$MARQ_DIR" ]]; then
#   echo "  (no marquee output directory found)"
#   exit 0
# fi
#
# find "$MARQ_DIR" -type f -iname '*.png' -print0 \
# | xargs -0 -r file \
# | sed -nE 's/^(.*): .* ([0-9]+) x ([0-9]+).*/  \1  ->  \2x\3/p'

