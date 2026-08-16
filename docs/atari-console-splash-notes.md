# Atari console splash mapping notes

Date: 2026-08-15

## Background
The custom RetroPie hook at `McAtariPi5/opt/retropie/configs/all/runcommand-onlaunch.sh` was always sending the ROM short name to the dmarquees FIFO. That meant the secondary Pi5 monitor displayed a game-specific marquee or fallback art instead of a console-specific splash.

The relevant RetroPie launch contract is:
- `runcommand-onlaunch.sh` is invoked by RetroPie after the emulator launch is prepared.
- In `runcommand.sh`, the user script is called with:
  - `$1` = SYSTEM
  - `$2` = EMULATOR
  - `$3` = ROM
  - `$4` = full command line

The system/emulator distinction matters:
- `SYSTEM` identifies the console family, such as `atari2600`, `atari5200`, `atari7800`, or `atari800`.
- `EMULATOR` identifies the core used, such as `lr-stella2014`, `lr-prosystem`, or `lr-atari800`.

## Fix applied
The launch script now prefers a system-level splash image for known Atari console systems and resolves the proper console art name before writing to the dmarquees command FIFO.

Mappings:
- `atari2600` -> `atari2600.png`
- `atari5200` -> `atari5200.png`
- `atari7800` -> `atari7800.png`
- `atari800` -> `atari800.png`

Fallback emulator mapping:
- `lr-stella2014` -> `atari2600`
- `lr-prosystem` -> `atari7800`
- `lr-atari800` -> `atari800` (or `atari5200` if the system is `atari5200`)

## Files involved
- `McAtariPi5/opt/retropie/configs/all/runcommand-onlaunch.sh`
- `McAtariPi5/home/danc/scripts/dmarquees-send.sh`
- `dmarquees/dmarquees.c`
- `/home/danc/mnt/marquees/`

## Required PNG names
Place the following files in `/home/danc/mnt/marquees/`:
- `atari2600.png`
- `atari5200.png`
- `atari7800.png`
- `atari800.png`

These are the images that should be shown on the secondary Pi5 monitor for Atari console launches.

## Verification
The updated script passed a Bash syntax check:
- `bash -n McAtariPi5/opt/retropie/configs/all/runcommand-onlaunch.sh`
- Result: `bash syntax OK`
