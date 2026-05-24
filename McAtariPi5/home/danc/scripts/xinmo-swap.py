#!/usr/bin/env python3
import glob
import sys

# Canonical joycode prefixes used in the repo cfg files (normal HW order)
CANONICAL_P1 = "JOYCODE_2_"
CANONICAL_P2 = "JOYCODE_3_"

CFG_DIR = "/opt/retropie/emulators/mame/cfg"

# The Lua plugin passes the actual joycode prefixes when the HW is SWAPPED:
#   argv[1] = first-enumerated (lower-index) xinmo  = physical P2 when swapped
#   argv[2] = second-enumerated (higher-index) xinmo = physical P1 when swapped
if len(sys.argv) >= 3:
    ACTUAL_P2 = sys.argv[1]   # e.g. "JOYCODE_2_"
    ACTUAL_P1 = sys.argv[2]   # e.g. "JOYCODE_7_"
else:
    # Fallback: simple swap for the classic 2-device JOYCODE_2/JOYCODE_3 setup
    ACTUAL_P2 = CANONICAL_P1
    ACTUAL_P1 = CANONICAL_P2


def swap_file(path):
    with open(path, "r", encoding="utf-8") as f:
        original = f.read()
    # Three-phase remap to avoid token collisions:
    # canonical P1 code -> actual P1 hw location
    # canonical P2 code -> actual P2 hw location
    content = original.replace(CANONICAL_P1, "_TEMPXIN1_")
    content = content.replace(CANONICAL_P2, ACTUAL_P2)
    content = content.replace("_TEMPXIN1_", ACTUAL_P1)
    if content == original:
        print(f"[XinSwap] No change: {path}")
        return
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"[XinSwap] Remapped:  {path}")


print(f"[XinSwap] {CANONICAL_P1} -> {ACTUAL_P1}  |  {CANONICAL_P2} -> {ACTUAL_P2}")
for cfg_file in glob.glob(f"{CFG_DIR}/*.cfg"):
    swap_file(cfg_file)
