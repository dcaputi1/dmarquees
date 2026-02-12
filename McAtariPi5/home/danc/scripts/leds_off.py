#!/usr/bin/env python3
import hid

dev = hid.device()
dev.open(0xD209, 0x1500)

# Bitmask 0000 0000 0000 0000 = ALL OFF
report = [0x00, 0xDD, 0x00, 0x00, 0x00]
dev.write(report)
dev.close()
