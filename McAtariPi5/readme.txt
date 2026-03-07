steps to create an SD image baseline
------------------------------------

preliminary:
a. use pi imager tool to create an SD pi5 64-bit full OS image with:
   enabled wifi credentials, wifi country US, user danc, host McAtariPi5
b. boot to desktop GUI
c. enable raspberry pi connect
   (email: dcaputi@optonline.net, pass: E....D....123!)
d. install updates
e. preferences, pi config, localization US UTF-8 for all
f. reboot and run:
> locale (confirm all US UTF-8)
> git clone https://github.com/dcaputi1/IvarArcade.git
  then reload this readme.txt from ~/IvarArcade/McAtariPi5, make sure nothing above changed
> git clone --depth=1 https://github.com/RetroPie/RetroPie-Setup.git
  2/28/2026 - use dcaputi1/Retropie-Setup.git for Trixie
> cd RetroPie-Setup
> sudo ./retropie_setup.sh
g. install all core packs
   12/30/2025 - RetroArch must be installed from source! (compatable with lr-mame)
h. install experimantal mame package (~2 hours from source)
   1/15/2026 - installed from binary
i. install experimental lr-mame (~2 hours from source)
   1/11/2026 - installed from binary
j. enable autostart emulationstation
   note: deferring this step later will corrupt custom autostart.sh
k. install optional package Skyscraper
l. edit autostart.sh and replace 'emulationstation' with desktop launch
   'wayfire-pi' for Bookworm, 'sudo systemctl start lightdm' for Trixie
> sudo chown -R danc /opt/retropie

steps:
1. ~/IvarArcade/McAtariPi5/cp_roms.sh (~1 hours)
2. add paths for mame and (optional) retroarch, frontends to /etc/profile (user long path)
   :/opt/retropie/emulators/mame:/opt/retropie/emulators/retroarch/bin
3. sudo ~/IvarArcade/McAtariPi5/analyze_games.sh (installs tinyxml2 and python3-hid packages)
4. mkdir -p /opt/retropie/configs/all/retroarch/config/MAME
5. build and install IvarArcade project components:
   cd ~/IvarArcade
   make all
   make install-force # deploys binaries, scripts, plugins, etc...
6. reboot (for path to take effect)
7. clone, build, install ultrastikcmd tool for per-game joystick mapping:
   mkdir -p ~/IvarArcade/tools/linux
   cd ~/IvarArcade/tools/linux
   git clone https://github.com/dcaputi1/UltrastikCmd.git
   cd UltrastikCmd
   ./build.sh
   sudo ldconfig -v | grep libhid
   (verify ldconfig shows libhid.so.0 -> libhid.so.0.0.0)
8. run ~/IvarArcade/McAtariPi5/ra_final.sh (formerly cp_opt.sh)
9. run ~/IvarArcade/analyze_games/analyze_games (not sudo!)
10.sudo ~/scripts/set_asound.sh (for Trixie sound problem - not needed for Bookworm Debian base OS)

optional:
A. sudo apt install meld
C. sudo apt install jstest-gtk
D. sudo apt install code
required:
E. sudo apt install fuse-zip (mounts zip file w/ PNGs)
   sudo nano /etc/fuse.conf and uncomment #user_allow_other

problem log:
1/11/26 [x] ES launch in-game tab menu, return/backspace swapped
        [ ] file missed: /opt/retropie/configs/all/retroarch/retroarch.cfg (NA?)
        [x] file diffs: /opt/retropie/configs/arcade/retroarch.cfg
            input_playerN_joypad_index (2,3,4,0,1)
            cfg_ra/sa coins
        [x] qbert.ini joymap NFG
        [x] git and AI got stupid: I wound up logged into GIT as dcaputi1-dev
        from then on, using the GUI or AI for source control was impossible.
        No clue how it happened or how to avoid it in the future.
        Re-baseline the SD card and pay more attention when launching VS Code!
1/14/26 [x] Missing ES controler setup (goes straight to Gamepad setup)
        added install-force target
1/15/26 can't run ES game
        [ ] missing /opt/retropie/reroarch/retroarch.cfg
        [x] link to mame in /opt/retropie/configs/mame/mame (maybe should be parent)
        [ ] mame installed in /opt/retropie/retroarch/mame (does it work SA?)
        [ ] missing /opt/retropie/emulators/retroarch/bin/retroarch
1/16/26 [x] redo SD baseline because too many diffs yesterday (BTW, other comments lost to bad CM)
1/17/26 [x] tracking link to mame in mame/mame from 1/15 - weird...
        apparently retroarch mame package install creates a ~/.mame symlink to /opt/retropie/configs/mame so that when my cp_opt.sh does this:
        ln -s /opt/retropie/emulators/mame/ /home/danc/.mame
        we create a link 'mame' in /opt/retropie/configs/mame to /opt/retropie/emulators/mame
        [x] cp_opt.sh - no scripts in ~/scripts (get rid of step for now) where are all my scripts?
        [x] move cp_opt.sh to last step (make install-final must run first)
        [x] xinmo swap failed (never updated after moved from joycode 4-5 to 2-3)
        [x] moved default.cfg R/O to EOF (but no can do - see next comment)
        [x] xinmo swap unable to write default.cfg (keep it 666)
1/20/26 [x] redo again - games don't load (make install-force wasn't run?)
1/24/26 [X] leds don't work unless start buttons are defined (some games use player buttons)
1/31/26 [X] running sa mame vector game in ra breaks tab menu return key
        [x] fix pics, vids, marquees - skyscraper needed 
2/13/26 Re-baseline -
        [x] cp_roms.sh not executable
        [x] make install-force failed (missing chown -R danc /opt/retropie)
        [x] ra_final.sh log shows twice (once with '+' once without)
        [x] analyze_games failed: couldn't write ini files (re: install-force fail)
        [x] ra asteriods fail (missings +x on run_mame.sh)
        [x] sa asteriods inputs NFG
        [ ] sa popeye performance/sound bad
2/26/26 Trixie baseline
        [x] build all packages from source and keep code in tmp/build
        [x] UltrastikCmd build fail - AI fixed (I hope!)
        [ ] iCode Atari paddles integration - always using js0-js4 NFG!
            For now, I'll just plug iCode in after startup.
        [ ] enhance xinmo-swap to deal with ALL random jsN device order?
        [ ] trouble with USB power - need to add another 5v supply?
2/28/26 [x] need custom 2-way joystick map for 4-way far left/right (Defender)
        [x] autostart on Trixie: ES doesn't start but Command Prompt runs ES
            also, exit to desktop prompts for password (note prelim.j above)
3/3/26  [x] defender 2-way Ultrastik map NFG using L/R as "reverse"
3/6/26  [x] defender L/R reverse NFG either, using defenderlr plugin