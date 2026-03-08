# dmarquees Panel Commands Handoff

Project: `IvarArcade`
Focus: `dmarquees` panel overlay commands (SVG template + CSV label substitution)

Code changes were made in:
- `dmarquees/dmarquees.c`
- `dmarquees/helpers.c`
- `dmarquees/helpers.h`

## What Was Added

1. New FIFO commands:
- `DCPANEL <shortname>`
- `MCPANEL <shortname>`

2. Behavior:
- `DCPANEL` uses template: `/home/danc/IvarArcade/images/dcpanel-1-labels.svg`
- `MCPANEL` uses template: `/home/danc/IvarArcade/images/mcpanel-1-labels.svg`
- Reads per-game CSV lookup and substitutes SVG text by label id.

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
- `DCPANEL`/`MCPANEL` require arg (shortname), e.g. `DCPANEL sf2`.
- If panel render fails, falls back to default marquee.

7. Notes:
- Build was not validated on Windows; compile/test on Pi.
- FIFO path in code: `/tmp/dmarquees_cmd`

## Raspberry Pi Checklist

1. Build:
- `cd /home/danc/IvarArcade/dmarquees && make clean && make`

2. Ensure SVG converter exists:
- `rsvg-convert --version`
- or `convert --version`

3. Test commands:
- `echo "DCPANEL sf2" > /tmp/dmarquees_cmd`
- `echo "MCPANEL sf2" > /tmp/dmarquees_cmd`
