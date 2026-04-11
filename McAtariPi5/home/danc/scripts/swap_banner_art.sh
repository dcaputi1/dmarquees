#!/bin/bash


# ==========================================
#  Banner Art Swap: toggle between marquees and cpanel
# ==========================================

MNT="$HOME/mnt/marquees"
MARQUEES_ZIP="$HOME/MAME_0.256_EXTRAs/marquees.zip"
CPANEL_ZIP="$HOME/MAME_0.256_EXTRAs/cpanel.zip"
CMD_FIFO="/tmp/dmarquees_cmd"
CURRENT_MOUNT_STATE="/tmp/current_mount_state"
SENDER_SCRIPT="$HOME/scripts/dmarquees-send.sh"

# Read PI3_PRESENT from persisted file if it exists (match autostart.sh)
# Match autostart.sh: default PI3_PRESENT to true, then override if file exists
PI3_PRESENT=true
PI3_PRESENT_FILE="$HOME/.pi3_present"
if [ -f "$PI3_PRESENT_FILE" ]; then
    PI3_PRESENT=$(cat "$PI3_PRESENT_FILE")
fi
# If PI3_PRESENT is true, send SWAPART to Pi3 and exit
if [ "$PI3_PRESENT" = "true" ]; then
    "$SENDER_SCRIPT" "SWAPART"
    exit $?
fi

# Check what's currently mounted
if [ -f "$CURRENT_MOUNT_STATE" ]; then
    MOUNTED=$(cat "$CURRENT_MOUNT_STATE")
else
    MOUNTED="marquees"
    echo "marquees" > "$CURRENT_MOUNT_STATE"
fi

echo "[swap_banner_art] Current mount: $MOUNTED"

# Unmount current
if mountpoint -q "$MNT"; then
    echo "[swap_banner_art] Unmounting $MOUNTED..."
    fusermount -u "$MNT"
    sleep 0.5
fi

# Toggle to the other one
if [ "$MOUNTED" = "marquees" ]; then
    # Switch to cpanel
    echo "[swap_banner_art] Mounting cpanel.zip..."
    fuse-zip -r -o allow_other "$CPANEL_ZIP" "$MNT" || {
        echo "[swap_banner_art] Failed to mount $CPANEL_ZIP"
        # Try to restore marquees if cpanel mount failed
        fuse-zip -r -o allow_other "$MARQUEES_ZIP" "$MNT"
        exit 1
    }
    echo "cpanel" > "$CURRENT_MOUNT_STATE"
    echo "[swap_banner_art] Switched to Control Panel artwork"
else
    # Switch back to marquees
    echo "[swap_banner_art] Mounting marquees.zip..."
    fuse-zip -r -o allow_other "$MARQUEES_ZIP" "$MNT" || {
        echo "[swap_banner_art] Failed to mount $MARQUEES_ZIP"
        exit 1
    }
    echo "marquees" > "$CURRENT_MOUNT_STATE"
    echo "[swap_banner_art] Switched to Marquee artwork"
fi

# Signal daemon to refresh
if pgrep -x dmarquees >/dev/null; then
    "$SENDER_SCRIPT" "REFRESH" 2>/dev/null || true
fi