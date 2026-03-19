dmarquees Pi5 Dev Handoff - 2026-03-18
=====================================

Previous handoff: `docs/dmarquees-pi5-dev-handoff-2026-03-15.md`

2026-03-19 follow-up addendum
-----------------------------
- The Pi3 daemon/netbridge blocker is resolved.
- Root cause: stale `ExecStart` env expansion in netbridge service plus mismatched wired subnet.
- Current validated wired addressing:
  - Pi5 `eth0`: `10.77.77.5`
  - Pi3 `eth0`: `10.77.77.3`
- Healthcheck now passes against `danc@10.77.77.3`.
- `dmarquees-healthcheck.sh` TCP probe no longer depends on `nc`.

Session summary
---------------
- Analyzed all marquee functions for Pi5 -> Pi3 dual-machine compatibility.
- Identified two broken features: art zip swap (B menu) and DCPANEL/MCPANEL.
- Implemented SWAPART TCP command so Pi5 can tell Pi3 to toggle its own FUSE mount.

What was changed this session
------------------------------
- `McAtariPi5/home/danc/scripts/dmarquees-netbridge.py`
  - Added `subprocess` and `time` imports.
  - Added `swap_art()`: unmounts current zip, mounts the other, writes state file,
    sends REFRESH to local FIFO.
  - Added `handle_command()`: intercepts SWAPART, forwards everything else to FIFO.
  - Added CLI args: `--marquees-zip`, `--cpanel-zip`, `--marquees-mnt`,
    `--mount-state-file` (all readable from env file via `os.environ`).
  - UDP and TCP serve loops now call `handle_command()` instead of
    `write_fifo_nonblocking()` directly.

- `McAtariPi5/opt/retropie/configs/all/autostart.sh` — `swap_banner_art()`
  - Now calls `load_dmarquees_transport_cfg` at the top.
  - In TCP mode: sends `SWAPART` via `send_dmarquees_cmd`, skips all local FUSE ops.
  - LOCAL mode: unchanged existing behavior.

- `McAtariPi5/home/danc/scripts/swap_banner_art.sh`
  - Loads transport config at startup.
  - In TCP mode: sends `SWAPART` through `dmarquees-send.sh` and exits.
  - LOCAL mode: falls through to existing FUSE swap code.

- `McAtariPi5/home/danc/scripts/dmarquees-netbridge.env.example`
  - Added four new vars: `DMARQUEES_MARQUEES_ZIP`, `DMARQUEES_CPANEL_ZIP`,
    `DMARQUEES_MARQUEES_MNT`, `DMARQUEES_MOUNT_STATE`.

Current feature status (TCP/remote mode)
-----------------------------------------
| Feature                         | Status                                    |
|---------------------------------|-------------------------------------------|
| Game marquee art (launch/end)   | OK once Pi3 daemon blocker resolved       |
| Frontend marquees (RA/SA/NA)    | OK once Pi3 daemon blocker resolved       |
| Art zip swap (B menu / SWAPART) | FIXED this session - needs Pi3 redeploy   |
| DCPANEL / MCPANEL button maps   | Still broken - see below                  |

IMMEDIATE BLOCKER on Pi3 (open since 2026-03-16)
-------------------------------------------------
The dmarquees daemon on Pi3 is not starting.  Nothing works until this is resolved.

Pi3 is headless. All commands below are run via SSH from Pi5:
```bash
ssh danc@10.77.77.3
```

Debug on Pi3 (via SSH):
```bash
ls -la ~/marquees/bin/dmarquees          # does binary exist?
~/marquees/bin/dmarquees -u danc -f NA  # manual start - watch for errors
cat ~/marquees/dmarquees.log             # check log if it exists
pgrep -x dmarquees                       # confirm running after manual start
ss -tuln | grep 5533                     # confirm netbridge is listening
```

If the binary is missing, the dmarquees project needs to be built on Pi3 (via SSH):
```bash
cd /home/danc/IvarArcade/dmarquees && make clean && make
```

Pi3 redeploy steps (via SSH from Pi5, after git pull / sync on Pi3)
--------------------------------------------------------------------
```bash
# Redeploy netbridge (picks up SWAPART support)
sudo /home/danc/scripts/install-dmarquees-netbridge-service.sh

# Verify new env vars are in /etc/default/dmarquees-netbridge
# Defaults match standard Pi3 paths; only edit if paths differ:
#   DMARQUEES_MARQUEES_ZIP=/home/danc/MAME_0.256_EXTRAs/marquees.zip
#   DMARQUEES_CPANEL_ZIP=/home/danc/MAME_0.256_EXTRAs/cpanel.zip
#   DMARQUEES_MARQUEES_MNT=/home/danc/mnt/marquees
#   DMARQUEES_MOUNT_STATE=/tmp/dmarquees_mount_state

# After daemon blocker is resolved, also install/restart daemon service:
sudo /home/danc/scripts/install-dmarquees-daemon-service.sh
```

Remaining broken feature: DCPANEL / MCPANEL
--------------------------------------------
The daemon renders panel overlays from files on its own local filesystem.
These must exist on Pi3:
- SVG templates: `/home/danc/IvarArcade/images/dcpanel-1-labels.svg`
              and `/home/danc/IvarArcade/images/mcpanel-1-labels.svg`
- Per-game CSV label files (`.dcp` / `.mcp`) searched in:
  1. `/home/danc/mnt/marquees`
  2. `/home/danc/RetroPie/roms/mame/media/marquees`
  3. `/home/danc/IvarArcade/images`

Fix: ensure `IvarArcade/images/` and `IvarArcade/labels/` are present on Pi3
(synced from the repo or copied manually). The TCP send of the command itself
works fine; only the assets are missing.

Test sequence once daemon is running
-------------------------------------
1. From Pi5, use menu T -> confirm TCP mode set to 10.77.77.3:5533
2. Run health check: `/home/danc/scripts/dmarquees-healthcheck.sh --ssh danc@10.77.77.3`
3. Launch a game -> confirm marquee updates on Pi3 display
4. Exit game -> confirm RA/frontend marquee returns
5. Press B (art swap) -> confirm cpanel zip swaps on Pi3 display
6. Press B again -> confirm marquees zip restored
7. (If assets present) In-game: send DCPANEL 1 / DCPANEL 0 manually to test
