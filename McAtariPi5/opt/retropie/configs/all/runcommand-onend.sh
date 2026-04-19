# Dan C. - custom game end script (invoked by runcommand.sh)
# With the marquees daemon running, send "NA" to load the RA marquee

SENDER_SCRIPT="$HOME/scripts/dmarquees-send.sh"

if [[ -x "$SENDER_SCRIPT" ]]; then
	DMARQUEES_CMD_FIFO="/tmp/dmarquees_cmd" "$SENDER_SCRIPT" "RA"
fi

echo "RA" > /tmp/dmarquees_cmd

sudo ultrastikcmd -c 1 -u "/home/danc/IvarArcade/tools/UltraStikMaps/Analog.um" >> /tmp/rc.out 2>&1
