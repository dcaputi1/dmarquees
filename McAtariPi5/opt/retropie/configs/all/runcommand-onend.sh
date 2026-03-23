# Dan C. - custom game end script (invoked by runcommand.sh)
# With the marquees daemon running, send "NA" to load the RA marquee

ARCADE_HOME="${ARCADE_HOME:-/home/danc}"
SENDER_SCRIPT="${DMARQUEES_SENDER_SCRIPT:-$ARCADE_HOME/scripts/dmarquees-send.sh}"
TRANSPORT_CFG="${DMARQUEES_TRANSPORT_CFG:-$ARCADE_HOME/.dmarquees_transport.conf}"

if [[ -x "$SENDER_SCRIPT" ]]; then
	DMARQUEES_TRANSPORT_CFG="$TRANSPORT_CFG" DMARQUEES_CMD_FIFO="/tmp/dmarquees_cmd" "$SENDER_SCRIPT" "RA"
else
	echo "RA" > /tmp/dmarquees_cmd
fi
sudo ultrastikcmd -c 1 -u "/home/danc/IvarArcade/tools/UltraStikMaps/Analog.um" >> /tmp/rc.out 2>&1
