dmarquees Pi5 Dev Handoff - 2026-03-15
=====================================

Purpose
-------
This handoff captures current implementation context and the next integration/testing steps for moving from this workspace to the Pi5 dev environment.

Current architecture status
---------------------------
- Pi5 can now send marquee commands using a selectable transport mode:
  - LOCAL (existing FIFO behavior)
  - TCP (send to remote Pi3)
  - UDP (send to remote Pi3)
- Pi5 transport mode is selectable from the autostart menu via key `T`.
- Pi5 transport settings persist in `/home/danc/.dmarquees_transport.conf`.
- Pi3 side has two systemd services available:
  - `dmarquees-daemon.service` (runs dmarquees)
  - `dmarquees-netbridge.service` (TCP/UDP -> local FIFO bridge)
- Pi5 has a one-command health check script to validate send path and optional remote service/journal status.

Files changed/added for this feature set
----------------------------------------
Pi5 launcher/menu integration:
- `McAtariPi5/opt/retropie/configs/all/autostart.sh`
- `McAtariPi5/opt/retropie/configs/all/runcommand-onlaunch.sh`
- `McAtariPi5/opt/retropie/configs/all/runcommand-onend.sh`
- `McAtariPi5/home/danc/scripts/swap_banner_art.sh`

Pi5 transport + verification scripts:
- `McAtariPi5/home/danc/scripts/dmarquees-send.sh`
- `McAtariPi5/home/danc/scripts/dmarquees-healthcheck.sh`

Pi3 bridge + service assets:
- `McAtariPi5/home/danc/scripts/dmarquees-netbridge.py`
- `McAtariPi5/home/danc/scripts/dmarquees-netbridge.service`
- `McAtariPi5/home/danc/scripts/dmarquees-netbridge.env.example`
- `McAtariPi5/home/danc/scripts/install-dmarquees-netbridge-service.sh`

Pi3 daemon service assets:
- `McAtariPi5/home/danc/scripts/dmarquees-daemon.service`
- `McAtariPi5/home/danc/scripts/dmarquees-daemon.env.example`
- `McAtariPi5/home/danc/scripts/install-dmarquees-daemon-service.sh`

Primary documentation:
- `docs/dmarquees-network.md`
- `docs/dmarquees-pi5-dev-handoff-2026-03-15.md` (this file)

Quick migration checklist (Pi5 dev environment)
------------------------------------------------
1. Sync/copy updated repository to Pi5 dev environment.
2. Ensure scripts are executable on Pi5:
   - `chmod +x /home/danc/scripts/dmarquees-send.sh`
   - `chmod +x /home/danc/scripts/dmarquees-healthcheck.sh`
3. Install netcat on Pi5 (required for TCP/UDP send):
   - `sudo apt-get install -y netcat-openbsd`
4. Reboot or restart flow that uses `autostart.sh`.
5. Use menu option `T` to select LOCAL/TCP/UDP and set Pi3 host/port.

Quick migration checklist (Pi3 runtime)
---------------------------------------
1. Sync/copy updated repository scripts to Pi3.
2. Ensure bridge and installers are executable:
   - `chmod +x /home/danc/scripts/dmarquees-netbridge.py`
   - `chmod +x /home/danc/scripts/install-dmarquees-daemon-service.sh`
   - `chmod +x /home/danc/scripts/install-dmarquees-netbridge-service.sh`
3. Install/enable daemon service:
   - `sudo /home/danc/scripts/install-dmarquees-daemon-service.sh`
4. Install/enable netbridge service:
   - `sudo /home/danc/scripts/install-dmarquees-netbridge-service.sh`
5. Verify:
   - `systemctl status dmarquees-daemon.service`
   - `systemctl status dmarquees-netbridge.service`

Integration test plan (recommended order)
-----------------------------------------
1. Baseline LOCAL mode test on Pi5:
   - Choose `T` -> LOCAL.
   - Launch frontend/game and confirm marquee updates.
2. TCP remote path test:
   - Set Pi5 mode to TCP with Pi3 IP/port.
   - Run on Pi5: `/home/danc/scripts/dmarquees-healthcheck.sh --ssh danc@<pi3-ip>`
   - Launch frontend/game and confirm remote marquee updates.
3. UDP remote path test:
   - Set Pi5 mode to UDP with Pi3 IP/port.
   - Run same healthcheck (note: UDP has no ACK guarantee).
   - Launch frontend/game and validate behavior under normal play.
4. Reboot persistence checks:
   - Reboot Pi5 and Pi3.
   - Confirm Pi3 services auto-start and Pi5 preserves transport selection.

Known behavior notes
--------------------
- In TCP/UDP mode, Pi5 intentionally skips starting local `dmarquees`.
- In TCP/UDP mode, Pi5 shutdown does not stop remote Pi3 daemon/services.
- `swap_banner_art.sh` now sends `REFRESH` through transport-aware sender script if available.
- Banner art mount operations are local to Pi5 and primarily relevant in LOCAL mode.

Debug commands for field testing
--------------------------------
Pi5:
- `cat /home/danc/.dmarquees_transport.conf`
- `/home/danc/scripts/dmarquees-healthcheck.sh`
- `/home/danc/scripts/dmarquees-healthcheck.sh --ssh danc@<pi3-ip>`

Pi3:
- `systemctl status dmarquees-daemon.service`
- `systemctl status dmarquees-netbridge.service`
- `journalctl -u dmarquees-daemon.service -f`
- `journalctl -u dmarquees-netbridge.service -f`

Next actions after integration test
-----------------------------------
- If TCP is stable and preferred, set `DMARQUEES_PROTOCOL=tcp` in `/etc/default/dmarquees-netbridge` and keep Pi5 in TCP mode.
- If UDP is preferred for latency, keep UDP mode but validate acceptable packet-loss behavior during long sessions.
- Optionally add autostart menu entry to run `dmarquees-healthcheck.sh` and save timestamped test logs.
- Optionally harden networking with firewall rules to limit accepted source IPs on Pi3.
