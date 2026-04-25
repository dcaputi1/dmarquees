#!/usr/bin/env python3
"""
xinmo-swapcheck.py — Detect whether XinMo P1/P2 joystick devices are swapped.

Detection method: button count via ioctl (no user input required).
  - js0 (sorted by path) with 15 buttons → correct mapping  → exit 0
  - js0 with 13 buttons                  → players swapped  → exit 1
  - fewer than 2 XinMo devices found     → error            → exit 2
  - button counts are neither 15/13 nor 13/15               → exit 2
"""
import array
import fcntl
import os
import sys

# === Version ===
VERSION = "6.0"

# === Constants ===
MAX_DEVICES      = 5
EXPECTED_P1_BTNS = 15  # js0 should have 15 buttons when mapping is correct
EXPECTED_P2_BTNS = 13  # js1 should have 13 buttons when mapping is correct


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


def main():
    print(f"xinmo-swapcheck v{VERSION}", file=sys.stderr)

    devices = find_xin_devices()

    for dev_path, name, btns in devices:
        print(f"  {dev_path}: '{name}' — {btns} buttons", file=sys.stderr)

    if len(devices) < 2:
        print("[ERROR] Fewer than 2 XinMo devices found.", file=sys.stderr)
        sys.exit(2)

    p1_path, p1_name, p1_btns = devices[0]
    p2_path, p2_name, p2_btns = devices[1]

    if p1_btns == EXPECTED_P1_BTNS and p2_btns == EXPECTED_P2_BTNS:
        print(f"[OK] Correct mapping: {p1_path} has {p1_btns} buttons (P1).", file=sys.stderr)
        sys.exit(0)
    elif p1_btns == EXPECTED_P2_BTNS and p2_btns == EXPECTED_P1_BTNS:
        print(f"[SWAP] {p1_path} has {p1_btns} buttons — P1 and P2 are swapped!", file=sys.stderr)
        sys.exit(1)
    else:
        print(f"[ERROR] Inconclusive button counts: {p1_path}={p1_btns}, {p2_path}={p2_btns}.", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
