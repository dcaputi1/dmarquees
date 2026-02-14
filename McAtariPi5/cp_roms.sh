# Copy the entire 0.256 internet archive backup
cp -vf /media/danc/ExtremeSSD/Mame/mame-merged/mame-merged/*.zip /home/danc/RetroPie/roms/arcade/
cp -vrf /media/danc/ExtremeSSD/Mame/MAME_0.256_EXTRAs/ /home/danc/

# Copy the MAME (bios-devices) archive from old MAME stuff - just in case? (shouldn't this be in BIOS/roms?)
cp -vf /media/danc/ExtremeSSD/Mame/mame-merged/BIOS/roms/*.zip /home/danc/RetroPie/BIOS/mame/

# OMG! why is this not in the internet archive 0.256 rom set?
cp -vf /media/danc/ExtremeSSD/Mame/roms_fav/pacman.zip /home/danc/RetroPie/roms/arcade/
