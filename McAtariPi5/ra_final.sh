#!/bin/bash

log() {
    set +x
    printf "%s\n" "$@"
    set -x
}

set -x

# Copy RetroArch/EmulationStation media assets ExtremeSSD backup
cp -vrf /media/danc/ExtremeSSD/McAtariPi5/home/danc/ /home/

# Create MAME home directory symlink
# note: -sfn replaces RetroArch mame package configs link
ln -sfn /opt/retropie/emulators/mame/ /home/danc/.mame

log "get rid of lr-mame's ini and plugins and replace with symlink to canonical copies"
rm -r /home/danc/RetroPie/BIOS/mame/ini
ln -s /opt/retropie/emulators/mame/ini/ /home/danc/RetroPie/BIOS/mame/ini

rm -r /home/danc/RetroPie/BIOS/mame/plugins
ln -s /opt/retropie/emulators/mame/plugins/ /home/danc/RetroPie/BIOS/mame/plugins
