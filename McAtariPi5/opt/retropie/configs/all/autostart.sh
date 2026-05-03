#!/bin/bash

# ============================================================
#  autostart.sh - RetroPie bootup entry point (pi3 and pi5)
# ============================================================

PI5_HOSTNAME="McAtariPi5"
THIS_IS_PI5=true
PI5_DUAL_DISPLAY=true
PI3_PRESENT=true
MENU_TIMEOUT=60
BASE_PATH="/opt/retropie/emulators/mame"
CFG_PATH="$BASE_PATH/cfg"
INI_PATH="$BASE_PATH/ini"
CFG_SA_PATH="$BASE_PATH/cfg_sa"
CFG_RA_PATH="$BASE_PATH/cfg_ra"
CMD_FIFO="/tmp/dmarquees_cmd"
PI3_REMOTE_HOST="10.77.77.3"
PI3_REMOTE_PORT="5533"
MOUNTED_GAME_ART="marquees" # or "cpanel"
PANEL="DC"
SCREEN_HORIZONTAL=true

DEBUG=""  # "1" to enable debug waits, "" disables

debug_wait()
{
    if [ -n "$DEBUG" ]; then
        echo "Press ENTER to continue..."
        read -r _
    fi
}

load_persisted_options()
{
    # Detect if this is Pi5 by hostname
    HOSTNAME=$(hostname)

    if [ "$HOSTNAME" = "$PI5_HOSTNAME" ]; then
        THIS_IS_PI5=true

        PI3_PRESENT_FILE="$HOME/.pi3_present"
        if [ -f "$PI3_PRESENT_FILE" ]; then
            PI3_PRESENT=$(<"$PI3_PRESENT_FILE")
        else
            PI3_PRESENT=true
            echo "$PI3_PRESENT" > "$PI3_PRESENT_FILE"
        fi

        PI5_DUAL_DISPLAY_FILE="$HOME/.pi5_dual_display"
        if [ -f "$PI5_DUAL_DISPLAY_FILE" ]; then
            PI5_DUAL_DISPLAY=$(<"$PI5_DUAL_DISPLAY_FILE")
        else
            PI5_DUAL_DISPLAY=true
            echo "$PI5_DUAL_DISPLAY" > "$PI5_DUAL_DISPLAY_FILE"
        fi
    else
        THIS_IS_PI5=false
    fi

    # initialize default/current cheat sheet panel image
    if [[ -f $HOME/.panel ]]; then
        PANEL=$(<"$HOME/.panel")
    else
        echo "$PANEL" > "$HOME/.panel"
    fi

    SCREEN_HORIZONTAL_FILE="$HOME/.horizontal"
    if [ -f "$SCREEN_HORIZONTAL_FILE" ]; then
        SCREEN_HORIZONTAL=$(<"$SCREEN_HORIZONTAL_FILE")
    else
        SCREEN_HORIZONTAL=true
        echo "$SCREEN_HORIZONTAL" > "$SCREEN_HORIZONTAL_FILE"
    fi

    # Debug: Show all three variables and wait for user
    echo "[autostart] PI5_HOSTNAME: $PI5_HOSTNAME"
    echo "[autostart] THIS_IS_PI5: $THIS_IS_PI5"
    echo "[autostart] PI5_DUAL_DISPLAY: $PI5_DUAL_DISPLAY"
    debug_wait
}

# Function to print a severe error and wait for user acknowledgement
echo_error_and_wait()
{
    local msg="$1"
    echo
    echo "[autostart] ERROR: $msg (press ENTER to continue)"
    echo
#   read -r _
}

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

# ==========================================
#  Marquee setup: mount and daemon launch
# ==========================================
setup_dmarquees()
{
    local ZIP="$HOME/MAME_0.256_EXTRAs/marquees.zip"
    local MNT="$HOME/mnt/marquees"
    local DAEMON="$HOME/marquees/bin/dmarquees"
    local LOG="$HOME/marquees/dmarquees.log"

    if [ "$THIS_IS_PI5" = true ] && [ ! "$PI5_DUAL_DISPLAY" = true ]; then
        echo "[autostart] Pi5 with single display, skipping dmarquees setup."
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
        echo_error_and_wait "[autostart] Failed to mount $ZIP"
        return 1
    }

    # Wait a bit for DRM subsystem to be ready
    sleep 1

    # Create FIFO if not present
    if [ ! -p "$CMD_FIFO" ]; then
        mkfifo "$CMD_FIFO"
        chmod 666 "$CMD_FIFO"
    fi

    # Restart daemon if already running (testing?)
    if pgrep -x dmarquees >/dev/null; then
        echo "EXIT" > "$CMD_FIFO" 2>/dev/null || true
        sleep 0.5
        pgrep -x dmarquees >/dev/null && sudo pkill -9 dmarquees
    fi

    if ! pgrep -x dmarquees >/dev/null; then
        echo "[autostart] Starting dmarquees daemon..."
        sudo stdbuf -oL -eL "$DAEMON" >"$LOG" 2>&1 &
        sleep 1
        debug_wait
    fi

    if pgrep -x dmarquees >/dev/null; then
        echo "[autostart] dmarquees started successfully."
        debug_wait
    else
        echo_error_and_wait "[autostart] ERROR: dmarquees failed to start. Check $LOG file."
    fi
}

# ==========================================
#  Marquee shutdown: cleanly stop daemon + unmount
# ==========================================
shutdown_dmarquees()
{
    local FOUND_DMARQUEES=false

    # Signal the dmarquees daemon to exit
    if pgrep -x dmarquees >/dev/null; then
        FOUND_DMARQUEES=true

        echo "[autostart] Shutting down marquees..."
        echo "EXIT" > "$CMD_FIFO" 2>/dev/null || true

        sleep 0.5

        # Force-kill if still alive
        if pgrep -x dmarquees >/dev/null; then
            sudo pkill -9 dmarquees
        fi
    fi

    # Remove FIFO
    [ -p "$CMD_FIFO" ] && rm -f "$CMD_FIFO"

    if [ $FOUND_DMARQUEES = true ]; then
        echo "[autostart] dmarquees stopped and cleaned up."
    fi
}

send_dmarquees_cmd()
{
    local cmd="$1"
    if [ -x "$HOME/scripts/dmarquees-send.sh" ]; then
        "$HOME/scripts/dmarquees-send.sh" "$cmd"
    fi

    echo "$cmd" > "$CMD_FIFO"
}

# ==========================================
#  Pygame frontend wrapper + main menu
# ==========================================
run_pic_frontend()
{
    # Invoke the pygame menu; choice letter is persisted to .def_key on exit.
    # Stderr goes to a log so SDL/pygame noise never pollutes the TTY.
    if [ ! -f "$HOME/scripts/pic_frontend.py" ]; then
        return 1
    fi

    # Save terminal state before invoking pygame.  SDL2/pygame can leave the
    # TTY in raw/cbreak mode if it exits abnormally (os._exit skips all Python
    # cleanup).  Restoring it here ensures the dialog fallback gets a working
    # keyboard whether pic_frontend succeeded, failed, or crashed.
    local _saved_tty
    _saved_tty=$(stty -g 2>/dev/null)

    python3 "$HOME/scripts/pic_frontend.py" 2>/tmp/pic_frontend.err
    local _pf_exit=$?

    if [ -n "$_saved_tty" ]; then
        stty "$_saved_tty" 2>/dev/null || stty sane 2>/dev/null
    else
        stty sane 2>/dev/null
    fi
    return $_pf_exit
}

# Main menu: pygame pic_frontend only (for dialog/text UI fallback use autostart-nogui.sh)
main_menu()
{
    while true; do
        restore_cfg
        python3 "$HOME/scripts/leds_off.py"
        send_dmarquees_cmd "NA"

        echo "[autostart] calling run_pic_frontend..."
        debug_wait
        run_pic_frontend
        local PF_EXIT=$?
        echo "[autostart] pic_frontend exit code: $PF_EXIT"
        debug_wait

        if [ $PF_EXIT -ne 0 ]; then
            echo "[autostart] pic_frontend failed (exit=$PF_EXIT). Check /tmp/pic_frontend.err. Exiting to shell."
            break
        fi

        # Reload all persisted options so SCREEN_HORIZONTAL and other state
        # reflect any changes made inside the pic_frontend advanced menu.
        load_persisted_options

        local CHOICE
        CHOICE=$(<"$HOME/.def_key")

        echo "[autostart] pic_frontend choice from .def_key: '$CHOICE'"
        debug_wait

        case $CHOICE in
            E)
                mv $CFG_RA_PATH $CFG_PATH
                send_dmarquees_cmd "RA"
                echo "Running EmulationStation... .horizontal = $SCREEN_HORIZONTAL"
                debug_wait
                if [ "$SCREEN_HORIZONTAL" = false ]; then
                    echo "ROL_FLAG=\"-rol\"" > $HOME/.rol_flag
                    emulationstation --screenrotate 3 --screensize 1200 1600 #auto
                else
                    echo "ROL_FLAG=\"-norol\"" > $HOME/.rol_flag
                    emulationstation #auto
                fi
                continue
                ;;
            M)
                send_dmarquees_cmd "SA"
                mv $CFG_SA_PATH $CFG_PATH
                echo "Running MAME... .horizontal = $SCREEN_HORIZONTAL"
                debug_wait
                if [ "$SCREEN_HORIZONTAL" = false ]; then
                    mame -rol -inipath "/opt/retropie/emulators/mame/ini;/opt/retropie/emulators/mame/ini_horz_ror" -cfg_directory $CFG_PATH -joystickprovider sdljoy
                else
                    mame -norol -inipath "/opt/retropie/emulators/mame/ini" -cfg_directory $CFG_PATH -joystickprovider sdljoy
                fi
                continue
                ;;
            C)
                # exit to command prompt (do not continue main menu loop)
                break
                ;;
            X|*)
                shutdown_dmarquees
                launch_desktop
                break
                ;;
        esac
    done
}

start_netbridge()
{
    # Start the network link listener (netbridge)
    if [ -x "$HOME/scripts/dmarquees-netbridge.py" ]; then
        if ! pgrep -f dmarquees-netbridge.py >/dev/null; then
            nohup python3 "$HOME/scripts/dmarquees-netbridge.py" > "$HOME/marquees/dmarquees-netbridge.log" 2>&1 &
        fi
    else
        echo_error_and_wait "$HOME/scripts/dmarquees-netbridge.py not found or not executable. Pi3 network bridge commands will NOT work."
    fi
}


# ---------------------------------------------------
# AUTOSTART.SH MAIN PROCESS
# ---------------------------------------------------

load_persisted_options

if [ "$THIS_IS_PI5" != true ] || [ "$PI5_DUAL_DISPLAY" = true ]; then
    echo "[autostart] calling setup_dmatquees..."
    debug_wait
    setup_dmarquees
fi

if [ "$THIS_IS_PI5" = true ]; then
    echo "[autostart] calling check_xinmo_status..."
    debug_wait
    check_xinmo_status

    main_menu

else # This is Pi3...

    start_netbridge
    echo "[autostart] Pi3 running dmarquees netbridge (ENTER key will exit autostart.sh)"
    read -r _
fi
