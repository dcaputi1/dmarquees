# dmarquees

Linux daemon to display retro arcade game marquee images on a secondary monitor.

## Overview

`dmarquees` is a lightweight DRM-based marquee daemon designed for Raspberry Pi / RetroPie systems. It runs as a long-lived daemon that owns `/dev/dri/card1` and displays PNG marquee images on a dedicated display.

## Features

- Runs as a background daemon (typically started at boot)
- DRM-based display management for efficient rendering
- Listens on a named FIFO for commands
- Supports nearest-neighbor scaling to preserve pixel art
- Persistent framebuffer with efficient updates

## Commands

The daemon listens on `/tmp/dmarquee_cmd` for the following commands:

- `<shortname>` - Load and display `/home/danc/mnt/marquees/<shortname>.png`
- `CLEAR` - Clear the screen (black)
- `EXIT` - Exit the daemon
- `RA` - Set frontend mode to RetroArch
- `SA` - Set frontend mode to StandAlone
- `RESET` - Reset the CRTC (re-acquire display)
- `REFRESH` - Reload the current image from disk

## Dependencies

```bash
sudo apt install build-essential libdrm-dev libpng-dev pkg-config
```

## Building

From the parent IvarArcade directory:
```bash
make dmarquees
```

Or from this directory:
```bash
make
```

## Installation

The executable will be installed to `$HOME/marquees/bin/dmarquees` by default.

## Usage

Run as root (recommended from system startup):
```bash
sudo ./dmarquees [-f SA|RA|NA] [-u username] [-d /dev/dri/cardX] &
```

Send commands via the FIFO:
```bash
echo "sf" > /tmp/dmarquee_cmd  # Display Street Fighter marquee
echo "CLEAR" > /tmp/dmarquee_cmd
```
