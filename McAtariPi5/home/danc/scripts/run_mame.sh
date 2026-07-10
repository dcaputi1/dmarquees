#!/bin/bash

# --- CONFIG PATHS ---
MAME_ROOT="/opt/retropie/emulators/mame"
CFG_DIR="$MAME_ROOT/cfg"
CTRLR_FILE="$HOME/.ctrlr"
CTRLR_CFG_DEFAULT="allctrlrs.cfg"

resolve_ctrlr_name()
{
    local cfg_name="$1"
    cfg_name="${cfg_name##*/}"
    cfg_name="${cfg_name%.cfg}"
    echo "$cfg_name"
}

# --- LOAD ROL (screen rotation) FLAG ---
source ~/.rol_flag 2>/dev/null

# --- CONDITIONAL INI PATH ---
INI_PATH="$MAME_ROOT/ini"

if [ "$ROL_FLAG" = "-rol" ]; then
    INI_PATH="$INI_PATH;$MAME_ROOT/ini_horz_ror"
fi

if [ -f "$CTRLR_FILE" ]; then
    CTRLR_CFG=$(<"$CTRLR_FILE")
else
    CTRLR_CFG="$CTRLR_CFG_DEFAULT"
    echo "$CTRLR_CFG" > "$CTRLR_FILE"
fi

CTRLR_NAME=$(resolve_ctrlr_name "$CTRLR_CFG")

# --- RUN MAME ---
"$MAME_ROOT/mame" \
    -joystickprovider sdljoy \
    -inipath "$INI_PATH" \
    -cfg_directory "$CFG_DIR" \
    -ctrlr "$CTRLR_NAME" \
    $ROL_FLAG \
    "$@"
