#!/bin/bash

OPT_DIR="/opt/retropie/configs/all/retroarch/config/Atari800"
ROM_DIR="$HOME/RetroPie/roms/atari800"

# Find the one existing game-specific .opt file
mapfile -t OPT_FILES < <(find "$OPT_DIR" -maxdepth 1 -type f -name "*.opt")

if [ "${#OPT_FILES[@]}" -ne 1 ]; then
    echo "ERROR: Expected exactly one .opt file in:"
    echo "  $OPT_DIR"
    echo "Found ${#OPT_FILES[@]}:"
    printf '  %s\n' "${OPT_FILES[@]}"
    exit 1
fi

TEMPLATE="${OPT_FILES[0]}"
echo "Template: $TEMPLATE"

find "$ROM_DIR" -maxdepth 1 -type f -iname '*basic*' -print0 |
while IFS= read -r -d '' ROM; do
    GAME=$(basename "$ROM")
    BASENAME="${GAME%.*}"
    DEST="$OPT_DIR/$BASENAME.opt"

    if [ -e "$DEST" ]; then
        echo "SKIP: $DEST already exists"
    else
        echo "CREATE: $DEST"
        cp "$TEMPLATE" "$DEST"
    fi
done
