#!/bin/bash

TIMEOUT=60
BASE_PATH="/opt/retropie/emulators/mame"
CFG_PATH="$BASE_PATH/cfg"
INI_PATH="$BASE_PATH/ini"

# Resolve the primary non-root account; allow explicit override via ARCADE_USER.
if [ -z "$ARCADE_USER" ]; then
    ARCADE_USER="${SUDO_USER:-${LOGNAME:-${USER:-}}}"
    if [ -z "$ARCADE_USER" ] || [ "$ARCADE_USER" = "root" ]; then
        ARCADE_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
    fi
    if [ -z "$ARCADE_USER" ] || [ "$ARCADE_USER" = "root" ]; then
        ARCADE_USER="$(find /home -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n 1)"
    fi
    if [ -z "$ARCADE_USER" ] || [ "$ARCADE_USER" = "root" ]; then
        ARCADE_USER="pi"
    fi
fi

# Keep StandAlone and RetroArch config files seperate
CFG_SA_PATH="$BASE_PATH/cfg_sa"
CFG_RA_PATH="$BASE_PATH/cfg_ra"

# Track which zip is currently mounted (marquees or cpanel)
CURRENT_MOUNT_STATE="/tmp/current_mount_state"

DMARQUEES_TRANSPORT_CFG_NAME=".dmarquees_transport.conf"
DMARQUEES_DEFAULT_REMOTE_HOST="10.77.77.3"
DMARQUEES_DEFAULT_REMOTE_PORT="5533"
DMARQUEES_TRANSPORT="LOCAL"
DMARQUEES_REMOTE_HOST="$DMARQUEES_DEFAULT_REMOTE_HOST"
DMARQUEES_REMOTE_PORT="$DMARQUEES_DEFAULT_REMOTE_PORT"

TTY_CONSOLE_TOKEN="console=tty1"

send_remote_netbridge_cmd()
{
    local host="$1"
    local port="$2"
    local cmd="$3"

    {
        printf '%s\n' "$cmd"
        sleep 0.1
    } > /dev/tcp/"$host"/"$port" 2>/dev/null
}

toggle_tty_console_boot()
{
    local host port

    ensure_dmarquees_transport_cfg
    load_dmarquees_transport_cfg

    host="$DMARQUEES_REMOTE_HOST"
    port="$DMARQUEES_REMOTE_PORT"

    if [ -z "$host" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        dialog --msgbox "Remote Pi3 host/port is not configured." 6 52
        return 0
    fi

    if ! dialog --title "Pi3 tty1 Console Boot" --yesno "Send remote toggle command to Pi3?\n\nTarget: $host:$port\nCommand: PI3_TTY_TOGGLE\n\nThis only flips the cmdline.txt console=tty1 token and requires a Pi3 reboot." 11 72; then
        return 0
    fi

    if send_remote_netbridge_cmd "$host" "$port" "PI3_TTY_TOGGLE"; then
        dialog --msgbox "Remote Pi3 toggle request sent to $host:$port.\n\nReboot Pi3 after a few seconds to apply." 8 70
    else
        dialog --msgbox "Failed to send PI3_TTY_TOGGLE to $host:$port.\nCheck network reachability and Pi3 netbridge service." 7 72
        return 1
    fi
}

persist_frontend_choice()
{
    # Persist only frontend launch choices so utility actions (T/Y/B/S) do not
    # become the default selection on the next boot.
    case "$1" in
        E|V|M|P|C|X)
            echo "DEF_KEY=\"$1\"" > "$HOME/.def_key"
            echo "DEF_KEY=\"$1\"" > "$HOME/.opt_key"
            echo "OPT_KEY=\"$1\"" >> "$HOME/.opt_key"
            ;;
    esac
}

dmarquees_transport_cfg_path()
{
    local HOME_DIR="/home/$ARCADE_USER"
    echo "$HOME_DIR/$DMARQUEES_TRANSPORT_CFG_NAME"
}

ensure_dmarquees_transport_cfg()
{
    local cfg_path
    cfg_path="$(dmarquees_transport_cfg_path)"

    if [ ! -f "$cfg_path" ]; then
        cat > "$cfg_path" <<EOF
DMARQUEES_TRANSPORT="LOCAL"
DMARQUEES_REMOTE_HOST="$DMARQUEES_DEFAULT_REMOTE_HOST"
DMARQUEES_REMOTE_PORT="$DMARQUEES_DEFAULT_REMOTE_PORT"
EOF
        chown "$ARCADE_USER:$ARCADE_USER" "$cfg_path" 2>/dev/null || true
    fi
}

load_dmarquees_transport_cfg()
{
    DMARQUEES_TRANSPORT="LOCAL"
    DMARQUEES_REMOTE_HOST="$DMARQUEES_DEFAULT_REMOTE_HOST"
    DMARQUEES_REMOTE_PORT="$DMARQUEES_DEFAULT_REMOTE_PORT"

    local cfg_path
    cfg_path="$(dmarquees_transport_cfg_path)"
    if [ -f "$cfg_path" ]; then
        # shellcheck disable=SC1090
        source "$cfg_path"
    fi

    case "$DMARQUEES_TRANSPORT" in
        LOCAL|TCP)
            ;;
        UDP)
            # Backward compatibility: migrate legacy UDP mode to TCP.
            DMARQUEES_TRANSPORT="TCP"
            ;;
        *)
            DMARQUEES_TRANSPORT="LOCAL"
            ;;
    esac

    if ! [[ "$DMARQUEES_REMOTE_PORT" =~ ^[0-9]+$ ]]; then
        DMARQUEES_REMOTE_PORT="$DMARQUEES_DEFAULT_REMOTE_PORT"
    fi
}

save_dmarquees_transport_cfg()
{
    local cfg_path
    cfg_path="$(dmarquees_transport_cfg_path)"

    cat > "$cfg_path" <<EOF
DMARQUEES_TRANSPORT="$DMARQUEES_TRANSPORT"
DMARQUEES_REMOTE_HOST="$DMARQUEES_REMOTE_HOST"
DMARQUEES_REMOTE_PORT="$DMARQUEES_REMOTE_PORT"
EOF
    chown "$ARCADE_USER:$ARCADE_USER" "$cfg_path" 2>/dev/null || true
}

send_dmarquees_cmd()
{
    local cmd="$1"
    local HOME_DIR="/home/$ARCADE_USER"
    local SENDER="$HOME_DIR/scripts/dmarquees-send.sh"
    local cfg_path
    cfg_path="$(dmarquees_transport_cfg_path)"

    if [ -x "$SENDER" ]; then
        DMARQUEES_TRANSPORT_CFG="$cfg_path" DMARQUEES_CMD_FIFO="/tmp/dmarquees_cmd" "$SENDER" "$cmd"
    else
        echo "$cmd" > /tmp/dmarquees_cmd
    fi
}

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
    local HOME_DIR="/home/$ARCADE_USER"
    local ZIP="$HOME_DIR/MAME_0.256_EXTRAs/marquees.zip"
    local MNT="$HOME_DIR/mnt/marquees"
    local CMD_FIFO="/tmp/dmarquees_cmd"
    local DAEMON="$HOME_DIR/marquees/bin/dmarquees"
    local LOG="$HOME_DIR/marquees/dmarquees.log"

    ensure_dmarquees_transport_cfg
    load_dmarquees_transport_cfg

    if [ "$DMARQUEES_TRANSPORT" != "LOCAL" ]; then
        echo "[autostart] Marquee transport mode: $DMARQUEES_TRANSPORT ($DMARQUEES_REMOTE_HOST:$DMARQUEES_REMOTE_PORT)"
        echo "[autostart] Starting local Pi5 splash daemon while game art is driven remotely."

        if pgrep -x dmarquees >/dev/null; then
            echo "EXIT" > "$CMD_FIFO" 2>/dev/null || true
            sleep 0.5
            pgrep -x dmarquees >/dev/null && sudo pkill -9 dmarquees
        fi

        if mountpoint -q "$MNT"; then
            fusermount -u "$MNT" || sudo umount -f "$MNT"
            sleep 0.5
        fi

        if [ ! -p "$CMD_FIFO" ]; then
            mkfifo "$CMD_FIFO"
            chmod 666 "$CMD_FIFO"
        fi

        if ! pgrep -x dmarquees >/dev/null; then
            echo "[autostart] Starting dmarquees splash daemon (-s)..."
            sudo stdbuf -oL -eL "$DAEMON" -u "$ARCADE_USER" -f "$fe_mode" -d /dev/dri/card1 -o HDMI-A-2 -s >"$LOG" 2>&1 &
            sleep 1
        fi

        if pgrep -x dmarquees >/dev/null; then
            echo "[autostart] Pi5 splash daemon running."
        else
            echo "[autostart] ERROR: Pi5 splash daemon failed to start. Check $LOG file."
        fi

        return 0
    fi

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

    # Restart daemon in LOCAL mode so splash-mode settings from remote mode do not persist.
    if pgrep -x dmarquees >/dev/null; then
        echo "EXIT" > "$CMD_FIFO" 2>/dev/null || true
        sleep 0.5
        pgrep -x dmarquees >/dev/null && sudo pkill -9 dmarquees
    fi

    if ! pgrep -x dmarquees >/dev/null; then
        echo "[autostart] Starting dmarquees daemon..."
        sudo stdbuf -oL -eL "$DAEMON" -u "$ARCADE_USER" -f "$fe_mode" -d /dev/dri/card1 -o HDMI-A-2 >"$LOG" 2>&1 &
        sleep 1
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
    local HOME_DIR="/home/$ARCADE_USER"
    local CMD_FIFO="/tmp/dmarquees_cmd"

    ensure_dmarquees_transport_cfg
    load_dmarquees_transport_cfg

    echo "[autostart] Shutting down marquees..."

    # Signal the local splash daemon to exit
    if pgrep -x dmarquees >/dev/null; then
        echo "EXIT" > "$CMD_FIFO" 2>/dev/null || true
        sleep 0.5
        # Force-kill if still alive
        if pgrep -x dmarquees >/dev/null; then
            sudo pkill -9 dmarquees
        fi
    fi

    # Remove FIFO
    [ -p "$CMD_FIFO" ] && rm -f "$CMD_FIFO"

    if [ "$DMARQUEES_TRANSPORT" != "LOCAL" ]; then
        echo "[autostart] Network transport mode active ($DMARQUEES_TRANSPORT $DMARQUEES_REMOTE_HOST:$DMARQUEES_REMOTE_PORT)."
        echo "[autostart] Remote daemon on Pi3 was left running."
    fi

    echo "[autostart] Marquees stopped and cleaned up."
}

select_dmarquees_transport()
{
    ensure_dmarquees_transport_cfg
    load_dmarquees_transport_cfg

    local default_item="L"
    [ "$DMARQUEES_TRANSPORT" = "TCP" ] && default_item="R"

    local remote_label="Pi3 Game Marquees  (Pi5 splash + Pi3 art)"
    local local_label="Pi5 Splash Only    (no Pi3 game art)"
    if [ "$DMARQUEES_TRANSPORT" = "LOCAL" ]; then
        local_label="$local_label [active]"
    else
        remote_label="$remote_label [active]"
    fi

    local choice
    choice=$(dialog --title "Marquee Transport" --default-item "$default_item" --menu "Select command transport" 14 68 2 \
        R "$remote_label" \
        L "$local_label" \
        2>&1 > /dev/tty)

    if [ -z "$choice" ]; then
        return 0
    fi

    local host="$DMARQUEES_REMOTE_HOST"
    local port="$DMARQUEES_REMOTE_PORT"
    local mode="LOCAL"

    if [ "$choice" = "R" ]; then
        host=$(dialog --title "Remote Host" --inputbox "Remote Pi3 IP/hostname:" 8 60 "$host" 2>&1 > /dev/tty)
        if [ -z "$host" ]; then
            return 0
        fi

        port=$(dialog --title "Remote Port" --inputbox "Remote Pi3 port:" 8 40 "$port" 2>&1 > /dev/tty)
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            dialog --msgbox "Invalid port: $port" 6 40
            return 1
        fi

        mode="TCP"
    fi

    DMARQUEES_TRANSPORT="$mode"
    DMARQUEES_REMOTE_HOST="$host"
    DMARQUEES_REMOTE_PORT="$port"
    save_dmarquees_transport_cfg

    # The Pi5 splash daemon always runs locally regardless of transport mode.
    # Just (re)start it so it picks up the new frontend mode.
    setup_dmarquees NA

    if [ "$DMARQUEES_TRANSPORT" = "LOCAL" ]; then
        dialog --msgbox "Marquee transport set to LOCAL\nGame marquees: Pi5 splash only (no Pi3)" 8 64
    else
        dialog --msgbox "Marquee transport set to TCP\nGame marquees: Pi3 at $DMARQUEES_REMOTE_HOST:$DMARQUEES_REMOTE_PORT\nSplash daemon: Pi5 card1 (always active)" 9 68
    fi
}

# ==========================================
#  Banner Art Swap: toggle between marquees and cpanel
# ==========================================

swap_banner_art()
{
    local HOME_DIR="/home/$ARCADE_USER"
    local MNT="$HOME_DIR/mnt/marquees"
    local MARQUEES_ZIP="$HOME_DIR/MAME_0.256_EXTRAs/marquees.zip"
    local CPANEL_ZIP="$HOME_DIR/MAME_0.256_EXTRAs/cpanel.zip"
    local CMD_FIFO="/tmp/dmarquees_cmd"

    ensure_dmarquees_transport_cfg
    load_dmarquees_transport_cfg

    # In TCP mode the mount and the daemon both live on Pi3.
    # Send SWAPART over the network; the netbridge handles the actual zip swap
    # and sends REFRESH to the local Pi3 daemon automatically.
    if [ "$DMARQUEES_TRANSPORT" != "LOCAL" ]; then
        echo "[autostart] TCP mode: delegating art swap to Pi3 via SWAPART command"
        send_dmarquees_cmd "SWAPART"
        return $?
    fi

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

# Read the last key (~/.opt_key preferred for compatibility) to use as default.
if [[ -f $HOME/.opt_key ]]; then
    source $HOME/.opt_key
elif [[ -f $HOME/.def_key ]]; then
    source $HOME/.def_key
else
    DEF_KEY="X"
fi

if [[ -z "$DEF_KEY" && -n "$OPT_KEY" ]]; then
    DEF_KEY="$OPT_KEY"
fi

case "$DEF_KEY" in
    E|V|M|P|C|X)
        ;;
    *)
        DEF_KEY="X"
        ;;
esac

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
    T "Marquee Pi3/Pi5  Remote/Local Swap"
    Y "Pi3 tty Console  Remote Toggle"
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

### clear   WARNING: this clear command kills dmarquees ability to display artwork!
printf "\033[2J\033[H"

if [[ "$CHOICE" == "" ]]; then
   CHOICE=$DEF_KEY
fi

persist_frontend_choice "$CHOICE"

# Launch the selected frontend with the appropriate parameters...
case $CHOICE in
E)
   mv $CFG_RA_PATH $CFG_PATH
   echo "ROL_FLAG=\"-norol\"" > $HOME/.rol_flag
    send_dmarquees_cmd "RA"
   emulationstation #auto
    send_dmarquees_cmd "NA"
   continue
   ;;
V)
   mv $CFG_RA_PATH $CFG_PATH
   echo "ROL_FLAG=\"-rol\"" > $HOME/.rol_flag
    send_dmarquees_cmd "RA"
   emulationstation --screenrotate 3 --screensize 1200 1600 #auto
    send_dmarquees_cmd "NA"
   continue
   ;;
M)
    send_dmarquees_cmd "SA"
   mv $CFG_SA_PATH $CFG_PATH
   mame -norol -inipath "/opt/retropie/emulators/mame/ini" -cfg_directory $CFG_PATH -joystickprovider sdljoy
    send_dmarquees_cmd "NA"
   continue
   ;;
P)
    send_dmarquees_cmd "SA"
   mv $CFG_SA_PATH $CFG_PATH
   mame -rol -inipath "/opt/retropie/emulators/mame/ini;/opt/retropie/emulators/mame/ini_horz_ror" -cfg_directory $CFG_PATH -joystickprovider sdljoy
    send_dmarquees_cmd "NA"
   continue
   ;;
T)
    select_dmarquees_transport
    continue
    ;;
Y)
    toggle_tty_console_boot
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

