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

DMARQUEES_TRANSPORT_CFG_NAME=".dmarquees_transport.conf"
DMARQUEES_DEFAULT_REMOTE_HOST="10.77.77.3"
DMARQUEES_DEFAULT_REMOTE_PORT="5533"
DMARQUEES_TRANSPORT="LOCAL"
DMARQUEES_REMOTE_HOST="$DMARQUEES_DEFAULT_REMOTE_HOST"
DMARQUEES_REMOTE_PORT="$DMARQUEES_DEFAULT_REMOTE_PORT"

TTY_CONSOLE_TOKEN="console=tty1"

# XinMo status check function
check_xinmo_status()
{
    python3 "$HOME/scripts/xinmo-swapcheck.py"
    status=$?

    if [ $status -eq 1 ]; then
        XINMO_STATUS_MSG="XinMo: Swap Required"
    else
        XINMO_STATUS_MSG="XinMo: OK"
    fi

    XINMO_STATUS_CODE=$status
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


launch_desktop()
{
    # Try legacy Wayfire (if present)
    if command -v wayfire-pi >/dev/null 2>&1; then
        echo "[autostart] Launching Wayfire desktop..."
        wayfire-pi
        return
    fi

    # Trixie uses this
    sudo systemctl start lightdm
}

# --- Advanced submenu logic ---

advanced_menu()
{
    while true; do
        local ADV_ITEMS=(
            Y "Pi3 tty Console  Remote Toggle"
            B "Banner Art Swap  Marquees/C-Panels"
            Q "Return to Main Menu"
        )
        local ADV_CHOICE
        ADV_CHOICE=$(dialog --title "Advanced Config Initial Setup/Options" --menu "Advanced options:" 12 60 3 \
            "${ADV_ITEMS[@]}" \
            2>&1 > /dev/tty)
        case $ADV_CHOICE in
            Y)
                toggle_tty_console_boot
                ;;
            B)
                swap_banner_art
                ;;
            Q|"" )
                break
                ;;
        esac
    done
}



# ==========================================
#  Marquee setup: mount and daemon launch
# ==========================================
setup_dmarquees()
{
    local fe_mode="$1"   # frontend mode: SA (standalone MAME) or RA (RetroArch)
    local ZIP="$HOME/MAME_0.256_EXTRAs/marquees.zip"
    local MNT="$HOME/mnt/marquees"
    local CMD_FIFO="/tmp/dmarquees_cmd"
    local DAEMON="$HOME/marquees/bin/dmarquees"
    local LOG="$HOME/marquees/dmarquees.log"

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
            sudo stdbuf -oL -eL "$DAEMON" -f "$fe_mode" -d /dev/dri/card1 -o HDMI-A-2 -s >"$LOG" 2>&1 &
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
        sudo stdbuf -oL -eL "$DAEMON" -f "$fe_mode" -d /dev/dri/card1 -o HDMI-A-2 >"$LOG" 2>&1 &
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

    echo "[autostart] dmarquees stopped and cleaned up."
}



# ==========================================
#  Banner Art Swap: toggle between marquees and cpanel
# ==========================================

swap_banner_art()
{
    local MNT="$HOME/mnt/marquees"
    local MARQUEES_ZIP="$HOME/MAME_0.256_EXTRAs/marquees.zip"
    local CPANEL_ZIP="$HOME/MAME_0.256_EXTRAs/cpanel.zip"
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

# Main menu logic as a function

main_menu()
{
    local DEF_KEY="X"
    while true; do
        restore_cfg
        python3 $HOME/scripts/leds_off.py

        # Use global XINMO_STATUS_CODE and XINMO_STATUS_MSG set at startup or after swap

        MENU_ITEMS=(
            E "EmulationStation Normal/Horizontal"
            V "Vertical Arcade  Portrait/Vertical"
            M "MAME Landscape   Normal/Horizontal"
            P "MAME Portrait    Portrait/Vertical"
            A "Advanced Config  Initial Setup/Opt"
            C "Command Prompt   Do not launch GUI"
            X "Exit to Desktop  X/Wayland Desktop"
        )

        # Add XinMo status message to the menu box
        CHOICE=$(dialog --timeout $TIMEOUT --title "Arcade Menu" --default-item "$DEF_KEY" \
            --menu "Choose Fontend: (timeout 1 min.)\n\n$XINMO_STATUS_MSG" 16 50 4 \
            "${MENU_ITEMS[@]}" \
            2>&1 > /dev/tty)
        printf "\033[2J\033[H"
        if [[ "$CHOICE" == "" ]]; then
            CHOICE=$DEF_KEY
        fi
        persist_frontend_choice "$CHOICE"
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
            A)
                advanced_menu
                continue
                ;;
            C)
                # exit to command prompt (do not continue main menu loop)
                ;;
            S)
                $HOME/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg_ra 1
                $HOME/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg_sa 1
                check_xinmo_status
                continue
                ;;
            *)
                shutdown_dmarquees
                launch_desktop
                ;;
        esac
        break
    done
}


# Check XinMo status once at startup
check_xinmo_status

# Auto-start MAIN MENU display on Pi5 boot
main_menu
