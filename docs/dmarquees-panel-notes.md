# dmarquees Panel Commands Handoff

Project: `IvarArcade`
Focus: `dmarquees` panel overlay commands (SVG template + CSV label substitution)

Last updated: 2026-03-08

Code changes were made in:
- `dmarquees/dmarquees.c`

## Current Status

- Build status: success (`make` at workspace root).
- Runtime test status in this session: intentionally skipped (desktop session blocks reliable DRM behavior).
- New command behavior implemented: panel commands now use tracked ROM and `0|1` toggle args.

## What Was Added

1. New FIFO commands:
- `DCPANEL <0|1>`
- `MCPANEL <0|1>`

2. Behavior:
- `DCPANEL` uses template: `/home/danc/IvarArcade/images/dcpanel-1-labels.svg`
- `MCPANEL` uses template: `/home/danc/IvarArcade/images/mcpanel-1-labels.svg`
- Reads per-game CSV lookup and substitutes SVG text by label id.
- Does not require shortname in command. Uses internally tracked current game shortname.
- `1` = show panel overlay for tracked game.
- `0` = return to normal game marquee (`CMD_ROM` display) for tracked game.
- If no game has been tracked yet, panel toggle is ignored with warning.

3. CSV naming:
- DC panel: `<shortname>-dcpanel.csv` OR `<shortname>-dc.panel.csv`
- MC panel: `<shortname>-mcpanel.csv`
- CSV format per line: `<label-id>,<label text>`
- Blank lines and `#` comments are ignored.
- XML escaping is applied to replacement text.

4. CSV search directories (in order):
- `/home/danc/mnt/marquees`
- `/home/danc/RetroPie/roms/mame/media/marquees`
- `/home/danc/IvarArcade/images`

5. Render pipeline:
- Template SVG loaded as text.
- Label substitutions applied.
- Writes temp SVG/PNG:
  - `/tmp/dmarquees_dcpanel.svg`
  - `/tmp/dmarquees_dcpanel.png`
  - `/tmp/dmarquees_mcpanel.svg`
  - `/tmp/dmarquees_mcpanel.png`
- Converts SVG to PNG by trying:
  - `rsvg-convert`
  - fallback: `convert` (ImageMagick)
- PNG is then loaded/blitted like regular marquee.

6. Command parsing:
- Main loop now parses first token + optional arg with `sscanf`.
- `DCPANEL`/`MCPANEL` require arg `0` or `1`, e.g. `DCPANEL 1`.
- If panel render fails, falls back to default marquee.

7. ROM tracking used by panel toggle:
- On successful ROM command (e.g. `sf2`), daemon stores tracked shortname.
- `DCPANEL 1` / `MCPANEL 1` render panel for that tracked shortname.
- `DCPANEL 0` / `MCPANEL 0` switch back to tracked ROM PNG display.

8. Notes:
- Build was not validated on Windows; compile/test on Pi.
- FIFO path in code: `/tmp/dmarquees_cmd`

## Raspberry Pi Checklist

1. Build:
- `cd /home/danc/IvarArcade/dmarquees && make clean && make`

2. Ensure SVG converter exists:
- `rsvg-convert --version`
- or `convert --version`

3. Test commands:
- Prime tracked game first:
  - `echo "sf2" > /tmp/dmarquees_cmd`
- Toggle DC panel on/off:
  - `echo "DCPANEL 1" > /tmp/dmarquees_cmd`
  - `echo "DCPANEL 0" > /tmp/dmarquees_cmd`
- Toggle MC panel on/off:
  - `echo "MCPANEL 1" > /tmp/dmarquees_cmd`
  - `echo "MCPANEL 0" > /tmp/dmarquees_cmd`

4. Expected behavior:
- `DCPANEL 1`/`MCPANEL 1` shows panel PNG generated from SVG template + CSV labels.
- `DCPANEL 0`/`MCPANEL 0` returns to current game marquee.
- If converter or CSV is missing, daemon logs warning/error and falls back.

## Suggested Offline Test Order

1. Start daemon in your offline environment (no desktop contention).
2. Send one known ROM shortname to prime tracking.
3. Run `DCPANEL 1`, then `DCPANEL 0`.
4. Run `MCPANEL 1`, then `MCPANEL 0`.
5. Repeat with a second ROM to confirm tracking updates correctly.