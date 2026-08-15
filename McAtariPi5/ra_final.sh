#!/bin/bash

step() {
	echo
	echo "$1"
}

run() {
	echo "$ $*"
	"$@"
}

# Ensure ExtremeSSD is mounted before proceeding
if [ ! -d "/media/danc/ExtremeSSD" ]; then
	echo "Error: backup drive not found at /media/danc/ExtremeSSD. Aborting."
	exit 1
fi

# Copy RetroArch/EmulationStation media assets ExtremeSSD backup
step "Copying RetroArch/EmulationStation media assets from ExtremeSSD backup"
run cp -vrf /media/danc/ExtremeSSD/McAtariPi5/home/danc/ /home/
run cp -vrf /media/danc/ExtremeSSD/McAtariPi5/opt/retropie/ /opt/

# Create MAME home directory symlink
# note: -sfn replaces RetroArch mame package configs link
step "Creating/refreshing ~/.mame symlink"
run ln -sfn /opt/retropie/emulators/mame/ /home/danc/.mame

step "Replacing lr-mame ini and plugins with symlinks to canonical copies"
run rm -r /home/danc/RetroPie/BIOS/mame/ini
run ln -s /opt/retropie/emulators/mame/ini/ /home/danc/RetroPie/BIOS/mame/ini

run rm -r /home/danc/RetroPie/BIOS/mame/plugins
run ln -s /opt/retropie/emulators/mame/plugins/ /home/danc/RetroPie/BIOS/mame/plugins
