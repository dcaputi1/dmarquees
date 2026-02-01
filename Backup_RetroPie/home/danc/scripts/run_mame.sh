#!/bin/bash

# --- CONFIG PATHS ---
MAME_ROOT="/opt/retropie/emulators/mame"
CFG_DIR="$MAME_ROOT/cfg"
CFG_RA="$MAME_ROOT/cfg_ra"
CFG_SA="$MAME_ROOT/cfg_sa"

# --- CLEANUP FUNCTION ---
# Un-Swap cfg folder: deactivate SA and activate RA
cleanup() {
    if [ -d "$CFG_DIR" ]; then
        mv "$CFG_DIR" "$CFG_SA"
    fi
    if [ -d "$CFG_RA" ]; then
        mv "$CFG_RA" "$CFG_DIR"
    fi
}
trap cleanup EXIT

# --- SWAP CFG FOLDERS (mame emulator is essentially SA) ---
# RetroArch maps are NFG: deactivate RA and activate SA
if [ -d "$CFG_DIR" ]; then
    mv "$CFG_DIR" "$CFG_RA"
fi
if [ -d "$CFG_SA" ]; then
    mv "$CFG_SA" "$CFG_DIR"
fi

# --- LOAD ROL (screen rotation) FLAG ---
source ~/.rol_flag 2>/dev/null

# --- CONDITIONAL INI PATH ---
INI_PATH="$MAME_ROOT/ini"

if [ "$ROL_FLAG" = "-rol" ]; then
    INI_PATH="$INI_PATH;$MAME_ROOT/ini_horz_ror"
fi

# --- RUN MAME ---
"$MAME_ROOT/mame" \
    -joystickprovider sdljoy \
    -inipath "$INI_PATH" \
    -cfg_directory "$CFG_DIR" \
    $ROL_FLAG \
    "$@"
