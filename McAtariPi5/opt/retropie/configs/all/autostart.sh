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
MAME_INI="$INI_PATH/mame.ini"
CFG_SA_PATH="$BASE_PATH/cfg_sa"
CFG_RA_PATH="$BASE_PATH/cfg_ra"
CMD_FIFO="/tmp/dmarquees_cmd"
PI3_REMOTE_HOST="10.77.77.3"
PI3_REMOTE_PORT="5533"
MOUNTED_GAME_ART="marquees" # or "cpanel"
PANEL="DC"

DEBUG=""  # set to 1 to enable debug_wait

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

advanced_menu()
{
    while true; do
        # Show current boolean states
        local dual_display_state pi3_present_state
        if [ "$PI5_DUAL_DISPLAY" = true ]; then
            dual_display_state="ON"
        else
            dual_display_state="OFF"
        fi
        if [ "$PI3_PRESENT" = true ]; then
            pi3_present_state="ON"
        else
            pi3_present_state="OFF"
        fi

        local PANEL_IMAGE
        if [ "$PANEL" = "DC" ]; then
            PANEL_IMAGE="UltraStick/Spinners"
        elif [ "$PANEL" = "MC" ]; then
            PANEL_IMAGE="Atari/FightStick"
        else
            PANEL_IMAGE="None/Blank"
        fi

        local ADV_ITEMS=(
            D "Toggle Pi5 Dual Display:   $dual_display_state"
            P "Toggle Pi3 Present:        $pi3_present_state"
            S "Swap Xin-Mo Player 1 & 2"
            I "Panel Image...             $PANEL_IMAGE"
            Q "Return to Main Menu"
        )

        local ADV_CHOICE

        ADV_CHOICE=$(dialog --title "Advanced Config Initial Setup/Options" --menu "Advanced options:" 16 60 5 \
            "${ADV_ITEMS[@]}" \
            2>&1 > /dev/tty)

        case $ADV_CHOICE in
            D)
                # Toggle PI5_DUAL_DISPLAY
                if [ "$PI5_DUAL_DISPLAY" = true ]; then
                    PI5_DUAL_DISPLAY=false
                else
                    PI5_DUAL_DISPLAY=true
                fi
                # Persist change in file
                sed -i "s/^PI5_DUAL_DISPLAY=.*/PI5_DUAL_DISPLAY=$PI5_DUAL_DISPLAY/" "$0"
                ;;
            P)
                # Toggle PI3_PRESENT
                if [ "$PI3_PRESENT" = true ]; then
                    PI3_PRESENT=false
                else
                    PI3_PRESENT=true
                fi
                # Persist change in file
                sed -i "s/^PI3_PRESENT=.*/PI3_PRESENT=$PI3_PRESENT/" "$0"
                ;;
            S)
                $HOME/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg_ra 1
                $HOME/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg_sa 1
                check_xinmo_status
                continue
                ;;
            I)
                # Panel Image submenu
                local PANEL_ITEMS=(
                    N "None/Blank"
                    A "Atari FS"
                    U "UltraStick"
                )
                local PANEL_CHOICE
                PANEL_CHOICE=$(dialog --title "Panel Image Selection" --menu "Choose panel image type:" 12 40 3 \
                    "N" "None/Blank" \
                    "A" "Atari FS" \
                    "U" "UltraStick" \
                    2>&1 > /dev/tty)

                case $PANEL_CHOICE in
                    N)
                        PANEL_IMAGE="NA"
                        ;;
                    A)
                        PANEL_IMAGE="MC"
                        ;;
                    U)
                        PANEL_IMAGE="DC"
                        ;;
                esac
                echo "$PANEL_IMAGE" > "$HOME/.panel"
                continue
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

persist_frontend_choice()
{
    echo "$1" > "$HOME/.def_key"
}

# Main menu logic as a function
main_menu()
{
    local DEF_KEY="X"
    if [[ -f $HOME/.def_key ]]; then
        DEF_KEY=$(<"$HOME/.def_key")
        # Backward compatibility: strip DEF_KEY= and quotes if present
        DEF_KEY=${DEF_KEY#DEF_KEY=}
        DEF_KEY=${DEF_KEY%\"}
        DEF_KEY=${DEF_KEY#\"}
    fi

    while true; do
        restore_cfg
        python3 $HOME/scripts/leds_off.py
        send_dmarquees_cmd "NA"

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
        CHOICE=$(dialog --timeout $MENU_TIMEOUT --title "Arcade Menu" --default-item "$DEF_KEY" \
            --menu "Choose Fontend: (timeout $MENU_TIMEOUT secs)\n\n$XINMO_STATUS_MSG" 16 50 4 \
            "${MENU_ITEMS[@]}" \
            2>&1 > /dev/tty)

###     printf "\033[2J\033[H"  DO NOT USE (was 'clear' which was worse!)

        if [[ "$CHOICE" == "" ]]; then
            CHOICE=$DEF_KEY
        fi
        persist_frontend_choice "$CHOICE"
        case $CHOICE in
            E)
                mv $CFG_RA_PATH $CFG_PATH
                cp "$MAME_INI.ra" "$MAME_INI"
                echo "ROL_FLAG=\"-norol\"" > $HOME/.rol_flag
                send_dmarquees_cmd "RA"
                emulationstation #auto
                continue
                ;;
            V)
                mv $CFG_RA_PATH $CFG_PATH
                cp "$MAME_INI.ra" "$MAME_INI"
                echo "ROL_FLAG=\"-rol\"" > $HOME/.rol_flag
                send_dmarquees_cmd "RA"
                emulationstation --screenrotate 3 --screensize 1200 1600 #auto
                continue
                ;;
            M)
                send_dmarquees_cmd "SA"
                mv $CFG_SA_PATH $CFG_PATH
                cp "$MAME_INI.sa" "$MAME_INI"
                mame -norol -inipath "/opt/retropie/emulators/mame/ini" -cfg_directory $CFG_PATH -joystickprovider sdljoy
                continue
                ;;
            P)
                send_dmarquees_cmd "SA"
                mv $CFG_SA_PATH $CFG_PATH
                cp "$MAME_INI.sa" "$MAME_INI"
                mame -rol -inipath "/opt/retropie/emulators/mame/ini;/opt/retropie/emulators/mame/ini_horz_ror" -cfg_directory $CFG_PATH -joystickprovider sdljoy
                continue
                ;;
            A)
                advanced_menu
                continue
                ;;
            C)
                # exit to command prompt (do not continue main menu loop)
                ;;
            *)
                shutdown_dmarquees
                launch_desktop
                ;;
        esac
        break
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
    echo "[autostart] calling setup_dmatquees"
    debug_wait
    setup_dmarquees
fi

if [ "$THIS_IS_PI5" = true ]; then

    check_xinmo_status
    main_menu

else # This is Pi3...

    start_netbridge
    echo "[autostart] Pi3 running dmarquees netbridge (ENTER key will exit autostart.sh)"
    read -r _
fi
