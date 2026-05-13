#!/usr/bin/env python3
"""
xinmo-swapcheck.py — Detect XinMo P1/P2 state and report one of five outcomes:

  exit 0 — OK           : hardware normal, cfg normal              → green
  exit 1 — Swap needed  : hw/cfg mismatch, players getting wrong inputs → red
  exit 2 — Error        : fewer than 2 XinMo devices or inconclusive counts
  exit 3 — Swapped OK   : hardware swapped AND cfg compensates (menu swap) → yellow
  exit 4 — Plugin swap  : hardware swapped AND cfg compensates (plugin auto-swap) → yellow

Hardware detection: button count via JSIOCGBUTTONS ioctl (no user input).
Cfg detection: .xinmo_swapped flag file inside each cfg dir (written by xinmo-swap.py).
"""
import array
import datetime
import fcntl
import json
import os
import sys

# === Version ===
VERSION = "6.2"

# === Constants ===
MAX_DEVICES      = 5
EXPECTED_P1_BTNS = 15  # js0 should have 15 buttons when mapping is correct
EXPECTED_P2_BTNS = 13  # js1 should have 13 buttons when mapping is correct

# All cfg directories are checked. They must agree on swap state.
# cfg_ra and cfg_sa are expected to always exist; cfg is optional (absent in normal state).
CFG_REQUIRED_DIRS = [
    "/opt/retropie/emulators/mame/cfg_ra",
    "/opt/retropie/emulators/mame/cfg_sa",
]
CFG_OPTIONAL_DIRS = [
    "/opt/retropie/emulators/mame/cfg",
]

# Flag file written by xinmo-swap.py inside each cfg dir to record swap state.
# MAME ignores non-*.cfg files, so this survives MAME regenerating default.cfg.
SWAP_STATE_FLAG = ".xinmo_swapped"

# Written by the MAME PxSwap plugin when it auto-swaps; removed by xinmo-swap.py (menu path).
PLUGIN_SWAP_FLAG = os.environ.get("HOME", "/home/danc") + "/.xinmo_plugin_swapped"

# Persistent stats file tracking OS-level swap detection history.
OS_STATS_FILE = os.path.join(os.environ.get("HOME", "/home/danc"), "IvarArcade", "json", "xinmo_os_stats.json")


def update_os_stats(hw_swapped):
    """Increment persistent counters for total checks and hw-swapped occurrences."""
    try:
        with open(OS_STATS_FILE, "r") as f:
            stats = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        stats = {"checks": 0, "swaps": 0, "last_swap": None}
    stats["checks"] = stats.get("checks", 0) + 1
    if hw_swapped:
        stats["swaps"] = stats.get("swaps", 0) + 1
        stats["last_swap"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        os.makedirs(os.path.dirname(OS_STATS_FILE), exist_ok=True)
        with open(OS_STATS_FILE, "w") as f:
            json.dump(stats, f)
    except Exception as e:
        print(f"[WARN] Could not update OS stats: {e}", file=sys.stderr)


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
    Return True if cfg_dir contains the .xinmo_swapped flag file, False if not,
    None if the directory does not exist.
    The flag is written/removed exclusively by xinmo-swap.py so MAME regenerating
    default.cfg cannot corrupt the recorded state.
    """
    if not os.path.isdir(cfg_dir):
        print(f"[WARN] {cfg_dir} not found — cfg state unknown.", file=sys.stderr)
        return None
    return os.path.exists(os.path.join(cfg_dir, SWAP_STATE_FLAG))


def main():
    print(f"xinmo-swapcheck v{VERSION}", file=sys.stderr)

    # --- Hardware state ---
    devices = find_xin_devices()

    for dev_path, name, btns in devices:
        print(f"  {dev_path}: '{name}' - {btns} buttons", file=sys.stderr)

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

    update_os_stats(hw_swapped)

    # --- Cfg state ---
    cfg_states = {}
    for cfg_dir in CFG_REQUIRED_DIRS:
        if not os.path.isdir(cfg_dir):
            print(f"[WARN] Cfg directory not found: {cfg_dir}", file=sys.stderr)
            continue
        state = check_cfg_swapped(cfg_dir)
        cfg_states[cfg_dir] = state
    for cfg_dir in CFG_OPTIONAL_DIRS:
        if not os.path.isdir(cfg_dir):
            continue
        state = check_cfg_swapped(cfg_dir)
        cfg_states[cfg_dir] = state

    known_states = [s for s in cfg_states.values() if s is not None]

    if not known_states:
        print("[WARN] Cfg state unknown in all directories; falling back to hardware-only check.", file=sys.stderr)
        sys.exit(1 if hw_swapped else 0)

    if len(set(known_states)) > 1:
        print("[ERROR] Cfg directories disagree on swap state - manual inspection required.", file=sys.stderr)
        sys.exit(2)

    cfg_swapped = known_states[0]
    print(f"[CFG] {'Swapped' if cfg_swapped else 'Normal'}", file=sys.stderr)

    # --- Combined decision ---
    #
    #  hw_normal  + cfg_normal  → OK             (exit 0, green)
    #  hw_swapped + cfg_swapped → Swapped OK     (exit 3, yellow) — compensated by menu
    #  hw_swapped + cfg_swapped → Plugin swap    (exit 4, yellow) — compensated by plugin
    #  hw_swapped + cfg_normal  → Swap! needed   (exit 1, red)    — signals wrong
    #  hw_normal  + cfg_swapped → Swap! needed   (exit 1, red)    — cfg wrongly swapped
    #
    if not hw_swapped and not cfg_swapped:
        print("[OK] Hardware normal, cfg normal.", file=sys.stderr)
        sys.exit(0)
    elif hw_swapped and cfg_swapped:
        plugin_swapped = os.path.exists(PLUGIN_SWAP_FLAG)
        if plugin_swapped:
            print("[PLUGIN SWAP] Hardware swapped, cfg compensates — auto-corrected by plugin.", file=sys.stderr)
            sys.exit(4)
        else:
            print("[SWAPPED OK] Hardware swapped, cfg compensates — playing correctly.", file=sys.stderr)
            sys.exit(3)
    else:
        print("[SWAP!] Mismatch — hardware and cfg states differ, swap needed.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
