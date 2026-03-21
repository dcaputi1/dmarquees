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
11.if using Pi3 as remote marquee node, configure transport + verify from Pi5:
   cat > ~/.dmarquees_transport.conf <<'EOF'
   DMARQUEES_TRANSPORT="TCP"
   DMARQUEES_REMOTE_HOST="10.77.77.3"
   DMARQUEES_REMOTE_PORT="5533"
   EOF
   /home/danc/scripts/dmarquees-healthcheck.sh --ssh danc@10.77.77.3

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

===========================================
Pi3 Light OS baseline setup
===========================================
   set locale ALL=EN_US.UTF-8 (no clue)
   sudo mkdir -p /media/danc/ExtremeSSD
   sudo mount /dev/sda1 /media/danc/ExtremeSSD
   mkdir -p ~/MAME_0.256_EXTRAs
   cp -v /media/danc/ExtremeSSD/Mame/MAME_0.256_EXTRAs/marquees.zip ~/MAME_0.256_EXTRAs/
   cp -v /media/danc/ExtremeSSD/Mame/MAME_0.256_EXTRAs/cpanel.zip ~/MAME_0.256_EXTRAs/
   sudo apt update
   sudo apt install -y git
   git clone https://github.com/dcaputi1/IvarArcade.git
   cd IvarArcade
   sudo apt install -y build-essential libdrm-dev libpng-dev libtinyxml2-dev fuse-zip
   sudo make install-pi3

1b) Configure direct wired link static IPs (NetworkManager):

   # Pi3 side (run on Pi3)
   sudo nmcli con add type ethernet ifname eth0 con-name eth0-static ip4 10.77.77.3/24
   sudo nmcli con up eth0-static

   # Pi5 side (run on Pi5 once per baseline; keep wired link subnet in sync)
   sudo nmcli con add type ethernet ifname eth0 con-name eth0-static ip4 10.77.77.5/24
   sudo nmcli con up eth0-static

   # Verify from Pi5
   ping -c2 10.77.77.3

   # Set marquee transport on Pi5 to wired Pi3 endpoint
   cat > ~/.dmarquees_transport.conf <<'EOF'
   DMARQUEES_TRANSPORT="TCP"
   DMARQUEES_REMOTE_HOST="10.77.77.3"
   DMARQUEES_REMOTE_PORT="5533"
   EOF

   # Optional (recommended for full healthcheck SSH checks)
   ssh-keygen -t ed25519
   ssh-copy-id danc@10.77.77.3

   # Health check (uses bash /dev/tcp; netcat not required)
   /home/danc/scripts/dmarquees-healthcheck.sh --ssh danc@10.77.77.3

2) Copy scripts/services from repo to /home/danc/scripts: (TBD - redundant with make install-pi3?)
  
   mkdir -p /home/danc/scripts

   install -m 755 McAtariPi5/home/danc/scripts/dmarquees-netbridge.py /home/danc/scripts/dmarquees-netbridge.py
   install -m 755 McAtariPi5/home/danc/scripts/install-dmarquees-mount-service.sh /home/danc/scripts/install-dmarquees-mount-service.sh
   install -m 755 McAtariPi5/home/danc/scripts/install-dmarquees-daemon-service.sh /home/danc/scripts/install-dmarquees-daemon-service.sh
   install -m 755 McAtariPi5/home/danc/scripts/install-dmarquees-netbridge-service.sh /home/danc/scripts/install-dmarquees-netbridge-service.sh

   install -m 644 McAtariPi5/home/danc/scripts/dmarquees-mount.service /home/danc/scripts/dmarquees-mount.service
   install -m 644 McAtariPi5/home/danc/scripts/dmarquees-mount.env.example /home/danc/scripts/dmarquees-mount.env.example
   install -m 644 McAtariPi5/home/danc/scripts/dmarquees-daemon.service /home/danc/scripts/dmarquees-daemon.service
   install -m 644 McAtariPi5/home/danc/scripts/dmarquees-daemon.env.example /home/danc/scripts/dmarquees-daemon.env.example
   install -m 644 McAtariPi5/home/danc/scripts/dmarquees-netbridge.service /home/danc/scripts/dmarquees-netbridge.service
   install -m 644 McAtariPi5/home/danc/scripts/dmarquees-netbridge.env.example /home/danc/scripts/dmarquees-netbridge.env.example

3) Install/enable services:

   sudo /home/danc/scripts/install-dmarquees-mount-service.sh
   sudo /home/danc/scripts/install-dmarquees-daemon-service.sh
   sudo /home/danc/scripts/install-dmarquees-netbridge-service.sh

4) Enforce Pi3-safe defaults:
   sudo tee /etc/default/dmarquees-mount >/dev/null <<'EOF'
   DMARQUEES_USER=danc
   DMARQUEES_ZIP=/home/danc/MAME_0.256_EXTRAs/marquees.zip
   DMARQUEES_MNT=/home/danc/mnt/marquees
   EOF

   sudo tee /etc/default/dmarquees-daemon >/dev/null <<'EOF'
   DMARQUEES_USER=danc
   DMARQUEES_FRONTEND=NA
   DMARQUEES_DRM_DEVICE=/dev/dri/card0
   EOF

5) Restart + verify:
   sudo systemctl daemon-reload
   sudo systemctl restart dmarquees-mount.service dmarquees-daemon.service dmarquees-netbridge.service
   systemctl status --no-pager dmarquees-mount.service dmarquees-daemon.service dmarquees-netbridge.service
   ss -tulpen | grep 5533

6) Set hostname clearly (avoid Pi3/Pi5 prompt confusion):
   sudo hostnamectl set-hostname BkWmLt32-Pi3
   sudo sh -c "grep -q '^127\.0\.1\.1' /etc/hosts && sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tBkWmLt32-Pi3/' /etc/hosts || echo '127.0.1.1\tBkWmLt32-Pi3' >> /etc/hosts"
   exec bash -l

7) After any git pull/update on Pi3, redeploy runtime binaries + services with one command:
   cd /home/danc/IvarArcade
   sudo make install-pi3

   NOTE: service install scripts use enable --now, which does not restart an already-running unit.
   Always run explicit restarts after updates if testing immediately:
   sudo systemctl restart dmarquees-daemon.service dmarquees-netbridge.service

8) Confirm daemon version actually running (do not trust build output alone):
   sudo journalctl -u dmarquees-daemon.service -n 30 --no-pager | grep -i "starting"
   # Expect: dmarquees: v1.7.0 starting...

9) SWAPART troubleshooting quick checks:
   # A) Verify active netbridge script (service runs /usr/local/bin copy)
   grep -n SWAPART /usr/local/bin/dmarquees-netbridge.py

   # B) If marquee mount is empty/unmounted, remount manually once
   sudo fusermount -u /home/danc/mnt/marquees 2>/dev/null || true
   sudo fuse-zip -r -o allow_other /home/danc/MAME_0.256_EXTRAs/marquees.zip /home/danc/mnt/marquees
   ls -la /home/danc/mnt/marquees | head -40

   # C) Set daemon state before testing SWAPART from Pi5
   # (unknown commands are treated as ROM names and can fall back to default marquee)
   /home/danc/scripts/dmarquees-send.sh SA
   sleep 0.5
   /home/danc/scripts/dmarquees-send.sh dkong
   sleep 0.5
   /home/danc/scripts/dmarquees-send.sh SWAPART


===========================================
Pi3 quick reinstall checklist (copy/paste)
===========================================

Run on Pi3 after fresh OS install:

sudo apt update
sudo apt install -y git build-essential libdrm-dev libpng-dev libtinyxml2-dev fuse-zip
git clone https://github.com/dcaputi1/IvarArcade.git
cd /home/danc/IvarArcade
sudo make install-pi3

Set hostname + hosts entry (avoid Pi5/Pi3 prompt confusion):

sudo hostnamectl set-hostname BkWmLt32-Pi3
sudo sh -c "grep -q '^127\.0\.1\.1' /etc/hosts && sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tBkWmLt32-Pi3/' /etc/hosts || echo '127.0.1.1\tBkWmLt32-Pi3' >> /etc/hosts"

Verify services + netbridge port:

systemctl status --no-pager dmarquees-mount.service dmarquees-daemon.service dmarquees-netbridge.service
ss -tulpen | grep 5533

Verify daemon version from active service:

sudo journalctl -u dmarquees-daemon.service -n 30 --no-pager | grep -i "starting"

If Pi3 was updated via git pull later, redeploy with:

cd /home/danc/IvarArcade
sudo make install-pi3
sudo systemctl restart dmarquees-daemon.service dmarquees-netbridge.service

If SWAPART seems broken, first ensure marquee mount is populated:

ls -la /home/danc/mnt/marquees | head -40
sudo fusermount -u /home/danc/mnt/marquees 2>/dev/null || true
sudo fuse-zip -r -o allow_other /home/danc/MAME_0.256_EXTRAs/marquees.zip /home/danc/mnt/marquees

Pi5-side stateful SWAPART test sequence:

/home/danc/scripts/dmarquees-send.sh SA
sleep 0.5
/home/danc/scripts/dmarquees-send.sh dkong
sleep 0.5
/home/danc/scripts/dmarquees-send.sh SWAPART
