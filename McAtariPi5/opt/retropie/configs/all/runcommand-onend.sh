# Dan C. - custom game end script (invoked by runcommand.sh)
# With the marquees daemon running, send "NA" to load the RA marquee

echo "RA" > /tmp/dmarquees_cmd
sudo ultrastikcmd -c 1 -u "/home/danc/IvarArcade/tools/UltraStikMaps/Analog.um" >> /tmp/rc.out 2>&1
