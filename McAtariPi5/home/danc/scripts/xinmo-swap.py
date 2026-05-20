#!/usr/bin/env python3
import glob

XIN1_CODE = "JOYCODE_2_"
XIN2_CODE = "JOYCODE_3_"
CFG_DIR   = "/opt/retropie/emulators/mame/cfg"


def swap_file(path):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    content = content.replace(XIN1_CODE, "TEMPXIN1_")
    content = content.replace(XIN2_CODE, XIN1_CODE)
    content = content.replace("TEMPXIN1_", XIN2_CODE)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"Swapped: {path}")


for cfg_file in glob.glob(f"{CFG_DIR}/*.cfg"):
    swap_file(cfg_file)
