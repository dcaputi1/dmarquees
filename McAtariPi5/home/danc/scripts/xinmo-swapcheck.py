#!/usr/bin/env python3
"""
xinmo-swapcheck.py — Detect XinMo P1/P2 state and report one of four outcomes:

  exit 0 — OK           : hardware normal, cfg normal              → green
  exit 1 — Swap needed  : hw/cfg mismatch, players getting wrong inputs → red
  exit 2 — Error        : fewer than 2 XinMo devices or inconclusive counts
  exit 3 — Swapped OK   : hardware swapped AND cfg compensates correctly → yellow

Hardware detection: button count via JSIOCGBUTTONS ioctl (no user input).
Cfg detection: P2_BUTTON1 entry in default.cfg (cfg_ra).
"""
import array
import fcntl
import os
import sys
import xml.etree.ElementTree as ET

# === Version ===
VERSION = "6.1"

# === Constants ===
MAX_DEVICES      = 5
EXPECTED_P1_BTNS = 15  # js0 should have 15 buttons when mapping is correct
EXPECTED_P2_BTNS = 13  # js1 should have 13 buttons when mapping is correct

# MAME cfg directory used to determine whether the cfg has been swapped already.
# cfg_ra and cfg_sa are always swapped together, so checking one is sufficient.
CFG_RA_DIR = "/opt/retropie/emulators/mame/cfg_ra"

# In a normal (unswapped) cfg, P2_BUTTON1 is mapped to joystick index 3 (JOYCODE_3_).
# After a swap it is mapped to joystick index 2 (JOYCODE_2_).
CFG_P2_NORMAL_CODE  = "JOYCODE_3_"   # P2_BUTTON1 text in default.cfg when cfg is NOT swapped
CFG_P2_SWAPPED_CODE = "JOYCODE_2_"   # P2_BUTTON1 text in default.cfg when cfg IS swapped


def get_joystick_info(dev_path):
    """Return (name, button_count) for the joystick at dev_path, or (None, 0) on error."""
    try:
        name_path = f"/sys/class/input/{os.path.basename(dev_path)}/device/name"
        name = open(name_path).read().strip() if os.path.exists(name_path) else "UNKNOWN"
        with open(dev_path, "rb") as js:
            buf = array.array('B', [0])
            fcntl.ioctl(js, 0x80016a12, buf)  # JSIOCGBUTTONS
        return name, buf[0]
    except Exception as e:
        print(f"[ERROR] Failed to read {dev_path}: {e}", file=sys.stderr)
        return None, 0


def find_xin_devices():
    """Scan /dev/input/js0..js{MAX_DEVICES-1} and return XinMo devices sorted by path."""
    devices = []
    for i in range(MAX_DEVICES):
        dev_path = f"/dev/input/js{i}"
        if not os.path.exists(dev_path):
            continue
        name, num_buttons = get_joystick_info(dev_path)
        if name and "xin" in name.lower():
            devices.append((dev_path, name, num_buttons))
    devices.sort(key=lambda d: d[0])
    return devices


def check_cfg_swapped(cfg_dir):
    """
    Read default.cfg in cfg_dir and return:
      False  — cfg is in normal state  (P2_BUTTON1 uses JOYCODE_3_)
      True   — cfg has been swapped    (P2_BUTTON1 uses JOYCODE_2_)
      None   — file missing, parse error, or P2_BUTTON1 entry not found
    """
    default_cfg = os.path.join(cfg_dir, "default.cfg")
    try:
        tree = ET.parse(default_cfg)
        root = tree.getroot()
        for port in root.findall(".//port[@type='P2_BUTTON1']"):
            for newseq in port.findall("newseq[@type='standard']"):
                text = newseq.text or ""
                if CFG_P2_SWAPPED_CODE in text:
                    return True
                if CFG_P2_NORMAL_CODE in text:
                    return False
        print(f"[WARN] P2_BUTTON1 entry not found in {default_cfg}", file=sys.stderr)
        return None
    except FileNotFoundError:
        print(f"[WARN] {default_cfg} not found — cfg state unknown.", file=sys.stderr)
        return None
    except ET.ParseError as e:
        print(f"[WARN] Failed to parse {default_cfg}: {e}", file=sys.stderr)
        return None


def main():
    print(f"xinmo-swapcheck v{VERSION}", file=sys.stderr)

    # --- Hardware state ---
    devices = find_xin_devices()

    for dev_path, name, btns in devices:
        print(f"  {dev_path}: '{name}' — {btns} buttons", file=sys.stderr)

    if len(devices) < 2:
        print("[ERROR] Fewer than 2 XinMo devices found.", file=sys.stderr)
        sys.exit(2)

    p1_path, p1_name, p1_btns = devices[0]
    p2_path, p2_name, p2_btns = devices[1]

    if p1_btns == EXPECTED_P1_BTNS and p2_btns == EXPECTED_P2_BTNS:
        hw_swapped = False
        print(f"[HW] Normal: {p1_path} has {p1_btns} buttons (P1).", file=sys.stderr)
    elif p1_btns == EXPECTED_P2_BTNS and p2_btns == EXPECTED_P1_BTNS:
        hw_swapped = True
        print(f"[HW] Swapped: {p1_path} has {p1_btns} buttons (physical P2 first).", file=sys.stderr)
    else:
        print(f"[ERROR] Inconclusive button counts: {p1_path}={p1_btns}, {p2_path}={p2_btns}.", file=sys.stderr)
        sys.exit(2)

    # --- Cfg state ---
    cfg_swapped = check_cfg_swapped(CFG_RA_DIR)
    if cfg_swapped is None:
        # Can't read cfg — fall back to hardware-only result
        print("[WARN] Cfg state unknown; falling back to hardware-only check.", file=sys.stderr)
        sys.exit(1 if hw_swapped else 0)

    print(f"[CFG] {'Swapped' if cfg_swapped else 'Normal'}", file=sys.stderr)

    # --- Combined decision ---
    #
    #  hw_normal  + cfg_normal  → OK           (exit 0, green)
    #  hw_swapped + cfg_swapped → Swapped OK   (exit 3, yellow) — compensated
    #  hw_swapped + cfg_normal  → Swap! needed (exit 1, red)    — signals wrong
    #  hw_normal  + cfg_swapped → Swap! needed (exit 1, red)    — cfg wrongly swapped
    #
    if not hw_swapped and not cfg_swapped:
        print("[OK] Hardware normal, cfg normal.", file=sys.stderr)
        sys.exit(0)
    elif hw_swapped and cfg_swapped:
        print("[SWAPPED OK] Hardware swapped, cfg compensates — playing correctly.", file=sys.stderr)
        sys.exit(3)
    else:
        print("[SWAP!] Mismatch — hardware and cfg states differ, swap needed.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
