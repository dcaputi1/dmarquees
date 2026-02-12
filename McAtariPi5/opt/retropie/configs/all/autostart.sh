#!/bin/bash

TIMEOUT=60
BASE_PATH="/opt/retropie/emulators/mame"
CFG_PATH="$BASE_PATH/cfg"
INI_PATH="$BASE_PATH/ini"

# Keep StandAlone and RetroArch config files seperate
CFG_SA_PATH="$BASE_PATH/cfg_sa"
CFG_RA_PATH="$BASE_PATH/cfg_ra"

# Track which zip is currently mounted (marquees or cpanel)
CURRENT_MOUNT_STATE="/tmp/current_mount_state"

launch_desktop()
{
    # Legacy Wayfire (if present)
    if command -v wayfire-pi >/dev/null 2>&1; then
        echo "[autostart] Launching Wayfire desktop..."
        wayfire-pi
        return
    fi
    
    # Trixie uses this crap
    sudo systemctl start lightdm
}

# ==========================================
#  Marquee setup: mount and daemon launch
# ==========================================

setup_dmarquees()
{
    local fe_mode="$1"   # frontend mode: SA (standalone MAME) or RA (RetroArch)
    local ZIP="/home/danc/MAME_0.256_EXTRAs/marquees.zip"
    local MNT="/home/danc/mnt/marquees"
    local CMD_FIFO="/tmp/dmarquees_cmd"
    local DAEMON="/home/danc/marquees/bin/dmarquees"
    local LOG="/home/danc/marquees/dmarquees.log"

    echo "[autostart] Setting up marquee..."

    # Ensure mount point exists
    mkdir -p "$MNT"

    # Unmount if it’s already mounted (just in case)
    if mountpoint -q "$MNT"; then
        fusermount -u "$MNT"
        sleep 0.5
    fi

    # Make sure allow_other is permitted
    if ! grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
        echo "user_allow_other" | sudo tee -a /etc/fuse.conf >/dev/null
    fi

    # Mount marquees.zip read-only for all users
    echo "[autostart] Mounting marquees.zip..."
    fuse-zip -r -o allow_other "$ZIP" "$MNT" || {
        echo "[autostart] Failed to mount $ZIP"
        return 1
    }

    # Wait a bit for DRM subsystem to be ready
    sleep 1

    # Create FIFO if not present
    if [ ! -p "$CMD_FIFO" ]; then
        mkfifo "$CMD_FIFO"
        chmod 666 "$CMD_FIFO"
    fi

    # Launch dmarquee as root if not already running
    if ! pgrep -x dmarquees >/dev/null; then
        echo "[autostart] Starting dmarquees daemon..."
        sudo stdbuf -oL -eL "$DAEMON" -f "$fe_mode" >"$LOG" 2>&1 &
        sleep 1
    else
        echo "[autostart] dmarquees already running."
    fi
    
    if pgrep -x dmarquees >/dev/null; then
        echo "[autostart] dmarquees started successfully."
    else
        echo "[autostart] ERROR: dmarquees failed to start. Check $LOG file."
    fi
}

# ==========================================
#  Marquee shutdown: cleanly stop daemon + unmount
# ==========================================

shutdown_dmarquees()
{
    local MNT="/home/danc/mnt/marquees"
    local CMD_FIFO="/tmp/dmarquees_cmd"
    local LOG="/home/danc/marquees/dmarquees.log"

    echo "[autostart] Shutting down marquees..."

    # Signal daemon to exit if running
    if pgrep -x dmarquees >/dev/null; then
        echo "EXIT" > "$CMD_FIFO" 2>/dev/null
        sleep 0.5
        # If still alive, force kill
        if pgrep -x dmarquees >/dev/null; then
            sudo pkill -9 dmarquees
        fi
    fi

    # Unmount marquees FUSE mount
    if mountpoint -q "$MNT"; then
        echo "[autostart] Unmounting $MNT..."
        fusermount -u "$MNT" || sudo umount -f "$MNT"
        sleep 0.5
    fi

    # Remove FIFO
    [ -p "$CMD_FIFO" ] && rm -f "$CMD_FIFO"

    echo "[autostart] Marquees stopped and cleaned up."
}

# ==========================================
#  Banner Art Swap: toggle between marquees and cpanel
# ==========================================

swap_banner_art()
{
    local MNT="/home/danc/mnt/marquees"
    local MARQUEES_ZIP="/home/danc/MAME_0.256_EXTRAs/marquees.zip"
    local CPANEL_ZIP="/home/danc/MAME_0.256_EXTRAs/cpanel.zip"
    local CMD_FIFO="/tmp/dmarquees_cmd"
    
    # Check what's currently mounted
    if [ -f "$CURRENT_MOUNT_STATE" ]; then
        MOUNTED=$(cat "$CURRENT_MOUNT_STATE")
    else
        MOUNTED="marquees"
        echo "marquees" > "$CURRENT_MOUNT_STATE"
    fi
    
    echo "[autostart] Current mount: $MOUNTED"
    
    # Unmount current
    if mountpoint -q "$MNT"; then
        echo "[autostart] Unmounting $MOUNTED..."
        fusermount -u "$MNT"
        sleep 0.5
    fi
    
    # Toggle to the other one
    if [ "$MOUNTED" = "marquees" ]; then
        # Switch to cpanel
        echo "[autostart] Mounting cpanel.zip..."
        fuse-zip -r -o allow_other "$CPANEL_ZIP" "$MNT" || {
            echo "[autostart] Failed to mount $CPANEL_ZIP"
            # Try to restore marquees if cpanel mount failed
            fuse-zip -r -o allow_other "$MARQUEES_ZIP" "$MNT"
            return 1
        }
        echo "cpanel" > "$CURRENT_MOUNT_STATE"
        echo "[autostart] Switched to Control Panel artwork"
    else
        # Switch back to marquees
        echo "[autostart] Mounting marquees.zip..."
        fuse-zip -r -o allow_other "$MARQUEES_ZIP" "$MNT" || {
            echo "[autostart] Failed to mount $MARQUEES_ZIP"
            return 1
        }
        echo "marquees" > "$CURRENT_MOUNT_STATE"
        echo "[autostart] Switched to Marquee artwork"
    fi
    
    # Signal daemon to refresh (commented out - frontend marquees aren't loaded from zip files)
 #   if pgrep -x dmarquees >/dev/null; then
 #       echo "REFRESH" > "$CMD_FIFO" 2>/dev/null || true
 #   fi
    
    sleep 1
}

# Function to restore existing cfg directory to original name
restore_cfg()
{
    if [ -d "$CFG_PATH" ]; then
        if [ ! -d "$CFG_SA_PATH" ]; then
            echo "Restoring cfg to cfg_sa"
            mv "$CFG_PATH" "$CFG_SA_PATH"
        elif [ ! -d "$CFG_RA_PATH" ]; then
            echo "Restoring cfg to cfg_ra"
            mv "$CFG_PATH" "$CFG_RA_PATH"
        else
            echo "Removing old 'cfg' directory"
            rm -rf "$CFG_PATH"
        fi
    fi
}

# launch the marquee daemon
setup_dmarquees NA

# Initialize mount state file if it doesn't exist
if [ ! -f "$CURRENT_MOUNT_STATE" ]; then
    echo "marquees" > "$CURRENT_MOUNT_STATE"
fi

# Check for fight stick xin-mo controller swap
python3 $HOME/scripts/xinmo-swapcheck.py
status=$?

# Read the last key ~/.def_key to use as the default choice
if [[ -f $HOME/.def_key ]]; then
    source $HOME/.def_key
else
    DEF_KEY="X"
fi

###########################################
# Front-End Chooser Menu loop

while true; do

# Begin by restoring the cfg folder to cfg_sa or cfg_ra
restore_cfg

# Turn off Panel1 LEDS
python3 $HOME/scripts/leds_off.py

# === Build menu items dynamically ===
MENU_ITEMS=(
    E "EmulationStation Normal/Horizontal"
    V "Vertical Arcade  Portrait/Vertical"
    M "MAME Lanscape    Normal/Horizontal"
    P "MAME Portrait    Portrait/Vertical"
    B "Banner Art Swap  Marquees/C-Panels"
    C "Command Prompt   Do not launch GUI"
    X "Exit to Desktop  X/Wayland Desktop"
)

if [ $status -eq 1 ]; then
    MENU_ITEMS+=(S "[DEFAULT] Swap Xin-Mo Controllers")
    DEF_KEY="S"
fi

# Invoke the "Choice" dialog box menu...
CHOICE=$(dialog --timeout $TIMEOUT --title "Arcade Menu" --default-item "$DEF_KEY" --menu "Choose Fontend: (timeout 1 min.)" 15 50 4 \
      "${MENU_ITEMS[@]}" \
       2>&1 > /dev/tty)

### clear   WARNING: this kills dmarquees ability to display artwork!
printf "\033[2J\033[H"

if [[ "$CHOICE" == "" ]]; then
   CHOICE=$DEF_KEY
fi

echo "DEF_KEY=\"$CHOICE\"" > $HOME/.def_key

# Launch the selected frontend with the appropriate parameters...
case $CHOICE in
E)
   mv $CFG_RA_PATH $CFG_PATH
   echo "ROL_FLAG=\"-norol\"" > $HOME/.rol_flag
   echo "RA" > /tmp/dmarquees_cmd
   emulationstation #auto
   echo "NA" > /tmp/dmarquees_cmd
   continue
   ;;
V)
   mv $CFG_RA_PATH $CFG_PATH
   echo "ROL_FLAG=\"-rol\"" > $HOME/.rol_flag
   echo "RA" > /tmp/dmarquees_cmd
   emulationstation --screenrotate 3 --screensize 1200 1600 #auto
   echo "NA" > /tmp/dmarquees_cmd
   continue
   ;;
M)
   echo "SA" > /tmp/dmarquees_cmd
   mv $CFG_SA_PATH $CFG_PATH
   mame -norol -inipath "/opt/retropie/emulators/mame/ini" -cfg_directory $CFG_PATH -joystickprovider sdljoy
   echo "NA" > /tmp/dmarquees_cmd
   continue
   ;;
P)
   echo "SA" > /tmp/dmarquees_cmd
   mv $CFG_SA_PATH $CFG_PATH
   mame -rol -inipath "/opt/retropie/emulators/mame/ini;/opt/retropie/emulators/mame/ini_horz_ror" -cfg_directory $CFG_PATH -joystickprovider sdljoy
   echo "NA" > /tmp/dmarquees_cmd
   continue
   ;;
B)
   # B - Banner Art Swap (toggle between marquees and cpanel)
   swap_banner_art
   continue
   ;;
C)
   # C for command prompt (do nothing)
   ;;
S)
   # S - swap controllers
   $HOME/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg_ra 1
   $HOME/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg_sa 1
   status=0
   continue
   ;;
*)
   shutdown_dmarquees
   launch_desktop
   ;;
esac

break

done

# end by restoring the cfg folder to cfg_sa or cfg_ra (in case any edits were made while running a frontend)
# also restore js3/js4 swapped config files back to normal
restore_cfg
$HOME/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg_ra 0
$HOME/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg_sa 0

shutdown_dmarquees
