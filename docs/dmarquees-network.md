dmarquees Pi5 -> Pi3 network transport
=====================================

For current migration status and next integration steps, see:
- `docs/dmarquees-pi5-dev-handoff-2026-03-18.md`

Validated wired-link addressing (2026-03-19):
- Pi5 `eth0`: `10.77.77.5/24`
- Pi3 `eth0`: `10.77.77.3/24`
- Netbridge listen port: `5533`

Goal
----
Run dmarquees on a remote Pi3 and choose where commands are sent from the Pi5:
- LOCAL: existing FIFO on Pi5 (`/tmp/dmarquees_cmd`)
- TCP: send commands to Pi3 over Ethernet

What changed
------------
- New menu item in `autostart.sh`: `T  Marquee Transport Local/TCP`
- New sender script on Pi5: `/home/danc/scripts/dmarquees-send.sh`
- Pi5 runcommand scripts now send through the sender script.
- New Pi3 receiver script: `/home/danc/scripts/dmarquees-netbridge.py`
- Transport settings are persisted in: `/home/danc/.dmarquees_transport.conf`

Pi5 setup
---------
1. Make scripts executable:
   - `chmod +x /home/danc/scripts/dmarquees-send.sh`
2. Boot and open the Arcade Menu.
3. Choose `T Marquee Transport Local/TCP`.
4. Select LOCAL or TCP.
5. If TCP is selected, set Pi3 host/IP and port.
   - Current wired target: `10.77.77.3:5533`

Notes:
- `dmarquees-send.sh` uses bash `/dev/tcp`; no netcat dependency is required.
- In TCP mode, Pi5 still runs local splash-screen dmarquees while Pi3 handles remote marquee art.

Pi3 setup (remote dmarquees host)
---------------------------------
1. Run dmarquees on the Pi3 as usual (it still reads `/tmp/dmarquees_cmd`).
2. Copy and enable the receiver script:
   - `chmod +x /home/danc/scripts/dmarquees-netbridge.py`
3. Start receiver:
   - `python3 /home/danc/scripts/dmarquees-netbridge.py --protocol tcp --host 0.0.0.0 --port 5533`
4. Keep receiver running in background or as a systemd service.

Pi3 systemd service (recommended)
---------------------------------
Files included in this repo:
- `/home/danc/scripts/dmarquees-netbridge.py`
- `/home/danc/scripts/dmarquees-netbridge.service`
- `/home/danc/scripts/dmarquees-netbridge.env.example`
- `/home/danc/scripts/install-dmarquees-netbridge-service.sh`
- `/home/danc/scripts/dmarquees-daemon.service`
- `/home/danc/scripts/dmarquees-daemon.env.example`
- `/home/danc/scripts/install-dmarquees-daemon-service.sh`
- `/home/danc/scripts/dmarquees-mount.service`
- `/home/danc/scripts/dmarquees-mount.env.example`
- `/home/danc/scripts/install-dmarquees-mount-service.sh`

Install on Pi3:
1. `chmod +x /home/danc/scripts/dmarquees-netbridge.py`
2. `chmod +x /home/danc/scripts/install-dmarquees-netbridge-service.sh`
3. `chmod +x /home/danc/scripts/install-dmarquees-daemon-service.sh`
4. `chmod +x /home/danc/scripts/install-dmarquees-mount-service.sh`
5. `sudo /home/danc/scripts/install-dmarquees-mount-service.sh`
6. `sudo /home/danc/scripts/install-dmarquees-daemon-service.sh`
7. `sudo /home/danc/scripts/install-dmarquees-netbridge-service.sh`

Recommended order rationale:
- Start with `dmarquees-mount.service` so `/home/danc/mnt/marquees` is mounted before daemon startup.

The daemon installer will:
- install the service to `/etc/systemd/system/dmarquees-daemon.service`
- create `/etc/default/dmarquees-daemon` (if missing)
- enable and start `dmarquees-daemon.service`

The netbridge installer will:
- copy the bridge script to `/usr/local/bin/dmarquees-netbridge.py`
- install the service to `/etc/systemd/system/dmarquees-netbridge.service`
- create `/etc/default/dmarquees-netbridge` (if missing)
- enable and start `dmarquees-netbridge.service`

Switch daemon startup mode/user later:
1. Edit `/etc/default/dmarquees-daemon`
2. Set `DMARQUEES_USER` and `DMARQUEES_FRONTEND`
3. `sudo systemctl restart dmarquees-daemon.service`

Update netbridge protocol setting later:
1. Edit `/etc/default/dmarquees-netbridge`
2. Set `DMARQUEES_PROTOCOL=tcp`
3. `sudo systemctl restart dmarquees-netbridge.service`

Check service status/logs:
- `systemctl status dmarquees-mount.service`
- `journalctl -u dmarquees-mount.service -f`
- `systemctl status dmarquees-daemon.service`
- `journalctl -u dmarquees-daemon.service -f`
- `systemctl status dmarquees-netbridge.service`
- `journalctl -u dmarquees-netbridge.service -f`

One-command health check
------------------------
Script included on Pi5:
- `/home/danc/scripts/dmarquees-healthcheck.sh`

Usage:
1. `chmod +x /home/danc/scripts/dmarquees-healthcheck.sh`
2. Local/transport check + probe send:
   - `/home/danc/scripts/dmarquees-healthcheck.sh`
3. End-to-end check with remote Pi3 service and journal validation:
   - `/home/danc/scripts/dmarquees-healthcheck.sh --ssh danc@10.77.77.3`

Important:
- SSH checks are run in batch mode and require key-based auth.
- If needed, configure once on Pi5:
  - `ssh-keygen -t ed25519`
  - `ssh-copy-id danc@10.77.77.3`

The health check validates:
- active transport mode from `/home/danc/.dmarquees_transport.conf`
- sender script presence
- LOCAL mode FIFO/process checks, or TCP endpoint checks
- probe command send (default: `REFRESH`)
- optional remote service status and recent `dmarquees-netbridge` journal markers

Notes
-----
- In TCP mode, Pi5 keeps its local splash daemon active; commands are also forwarded to Pi3.
- In TCP mode, Pi5 shutdown will not stop remote Pi3 dmarquees.
- `Banner Art Swap` in TCP mode sends `SWAPART` to Pi3 (remote mount swap).
