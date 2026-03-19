# TCP Remote Marquee Pi3→Pi5 Setup - Session 2026-03-16

## 2026-03-19 Follow-up (Current State)
- This session note is historical; current wired link addressing is `10.77.77.x`.
- Active transport target is Pi3 `10.77.77.3:5533` from Pi5.
- Netbridge and daemon are both active; end-to-end healthcheck now passes.
- Healthcheck no longer requires netcat for TCP probing.

## Objective
Enable Pi5 to send marquee display commands to Pi3 over wired TCP link (port 5533).

## Current Status: INCOMPLETE
- Components copied to Pi3 (MAME_0.256_EXTRAs folder: ~40GB)
- TCP transport config created: `~/.dmarquees_transport.conf`
- Script updated to use bash `/dev/tcp` instead of netcat (no dependency)
- `make install` completed on Pi5
- **BLOCKER (resolved 2026-03-19)**: netbridge service startup and wired addressing mismatch

## What's Done
1. ✅ Mounted ExtremeSSD on Pi3 light OS
2. ✅ Copied MAME_0.256_EXTRAs from SSD to `/home/danc/` (40GB)
3. ✅ Updated dmarquees-send.sh to use `/dev/tcp` (no netcat required)
4. ✅ TCP config on Pi5 (current): `10.77.77.3:5533`

## Current Blocker
**Test command sent from Pi5:**
```bash
DMARQUEES_TRANSPORT_CFG=~/.dmarquees_transport.conf DMARQUEES_CMD_FIFO="/tmp/dmarquees_cmd" ~/scripts/dmarquees-send.sh "dkong"
```

**Result**: Pi3 display still shows default RetroArch marquee (not dkong).

**Investigation needed on Pi3:**
- Does `pgrep -x dmarquees` show running process?
- Does `netstat -tuln | grep 5533` or `ss -tuln | grep 5533` show listening socket?
- Does `~/marquees/bin/dmarquees` binary exist?
- Manual start: `~/marquees/bin/dmarquees -u danc -f NA` → watch for errors
- Check log file: `~/marquees/dmarquees.log` (file not created, daemon never started)

## Key Files Modified
- [McAtariPi5/home/danc/scripts/dmarquees-send.sh](../../McAtariPi5/home/danc/scripts/dmarquees-send.sh) - TCP section now uses `/dev/tcp` instead of `nc`

## Next Steps (for tomorrow)
1. **SSH to Pi3** and debug why daemon won't start
2. Check if binary exists: `ls -la ~/marquees/bin/dmarquees`
3. Try manual startup to see error messages
4. Verify TCP socket is listening after daemon starts
5. Resend test command once daemon is running
6. Once working: implement into autostart.sh flow

## Network Config Reference
- **Pi3 IP**: 10.77.77.3 (wired `eth0`)
- **Pi3 Port**: 5533 (dmarquees remote listener)
- **Pi5 IP**: 10.77.77.5 (wired `eth0`, source of commands)
- **Transport Config Location**: `~/.dmarquees_transport.conf`
- **Config Mode**: TCP (vs LOCAL/UDP)

## Files in Project
- Main script: `/home/danc/IvarArcade/McAtariPi5/home/danc/scripts/dmarquees-send.sh`
- Sender function in autostart: [McAtariPi5/opt/retropie/configs/all/autostart.sh](../../McAtariPi5/opt/retropie/configs/all/autostart.sh) lines ~118-127
- Transport config functions: lines ~40-100

## Test Game
- ROM: `dkong.zip`
- Expected behavior: marquee image switches to Donkey Kong when command sent
