#!/usr/bin/env python3
import sys
import hid

def main():
    if len(sys.argv) != 2:
        print("Usage: set_leds.py <hex_value_0x00_to_0xFF>")
        sys.exit(1)

    try:
        led_mask = int(sys.argv[1], 16)
    except ValueError:
        print("Invalid hex value. Use format like 0x07 or 0x1F.")
        sys.exit(1)

    if not 0x00 <= led_mask <= 0xFF:
        print("Value must be between 0x00 and 0xFF.")
        sys.exit(1)

    try:
        dev = hid.device()
        dev.open(0xD209, 0x1500)  # Vendor ID and Product ID of PacDrive

        report = [0, 0xDD, 0, 0, led_mask]  # Output report (5 bytes)
        dev.write(report)
        dev.close()

#       print(f"LED mask 0x{led_mask:02X} sent successfully.")  C/O: this is redundant w/ init.lua

    except Exception as e:
        print(f"Failed to send LED mask: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
