#!/bin/bash

# --- CONFIG PATHS ---
MAME_ROOT="/opt/retropie/emulators/mame"
CFG_DIR="$MAME_ROOT/cfg"

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
