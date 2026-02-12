# Dan C. - custom launch script (invoked by runcommand.sh $3=ROM filename)
# With the marquees daemon running, send the command to load the artwork
# Also configures UltraStik to 4-way mode for games that need it

echo "runcommand-onlaunch started $date" > /tmp/rc.out

#SYSTEM="$1"
#EMULATOR="$2"
ROM="$3"
#CMD="$4"

# send ROM name to marquee daemon
echo "checking rom $ROM" >> /tmp/rc.out
if [[ -n "$ROM" ]]; then
    romzip="$(basename "$ROM")"
    command="${romzip%.zip}"
    
    # Check if game needs special joystick configuration
    # Q*bert uses a 45° rotated joystick (diagonal-primary)
    if [[ "$command" == "qbert" ]]; then
        echo "Q*bert detected - using diagonal joystick config" >> /tmp/rc.out
        # Configure UltraStik for Q*bert's 45° rotated control
        sudo ultrastikcmd -c 1 -u "/home/danc/IvarArcade/tools/UltraStikMaps/4-WayQBert.um" >> /tmp/rc.out 2>&1
    else
        # Check if game needs 4-way joystick configuration
        INI_FILE="/opt/retropie/emulators/mame/ini/${command}.ini"
        if [[ -f "$INI_FILE" ]]; then
            # Check if the INI file contains joystick_map (indicating 4-way game)
            if grep -q "^joystick_map" "$INI_FILE"; then
                echo "4-way game detected: $command" >> /tmp/rc.out
                # Configure UltraStik for 4-way mode with sticky diagonals
                sudo ultrastikcmd -c 1 -u "/home/danc/IvarArcade/tools/UltraStikMaps/4-Way.um" >> /tmp/rc.out 2>&1
            else
                echo "8-way game (has INI but no joystick_map): $command" >> /tmp/rc.out
                # Configure UltraStik for 8-way with easy diagonals
                sudo ultrastikcmd -c 1 -u "/home/danc/IvarArcade/tools/UltraStikMaps/8-WayEasyDiagonals.um" >> /tmp/rc.out 2>&1
            fi
        else
            echo "No custom INI file found, assuming 8-way: $command" >> /tmp/rc.out
            # Configure UltraStik for 8-way with easy diagonals
            sudo ultrastikcmd -c 1 -u "/home/danc/IvarArcade/tools/UltraStikMaps/8-WayEasyDiagonals.um" >> /tmp/rc.out 2>&1
        fi
    fi
    # Write the ROM short name to the marquee command file
    # NOTE: do this last! (race condition)
    # ALSO: we ignore all rom commands from RA unless sent from here with "RC:" prepended
	echo "input $romzip : sending command $command to marquee daemon" >> /tmp/rc.out
    echo "RC:$command" > /tmp/dmarquees_cmd
fi

echo "runcommand-onlauch exit $date" >> /tmp/rc.out
