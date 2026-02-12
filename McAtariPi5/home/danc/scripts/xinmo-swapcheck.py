#!/usr/bin/env python3
import os
import struct
import time
import fcntl
import array
import select
import sys

# === Version ===
VERSION = "5.6"

# === Constants ===
JS_EVENT_BUTTON = 0x01
JS_EVENT_AXIS = 0x02
JS_EVENT_INIT = 0x80

MAX_DEVICES = 5
TIMEOUT_SECONDS = 5  # Reduced from 30 to 5
EXPECTED_P1_BUTTONS = 15  # Player 1 should have 15 buttons

# === Functions ===
def get_joystick_info(dev_path):
    """Fetch joystick name and button count for a given device path."""
    try:
        with open(dev_path, "rb") as js:
            # Device name
            name_path = f"/sys/class/input/{os.path.basename(dev_path)}/device/name"
            if os.path.exists(name_path):
                with open(name_path, "r") as f:
                    name = f.read().strip()
            else:
                name = "UNKNOWN"

            # Button count via ioctl
            buf = array.array('B', [0])
            fcntl.ioctl(js, 0x80016a12, buf)  # JSIOCGBUTTONS
            num_buttons = buf[0]

            return name, num_buttons
    except Exception as e:
        print(f"[ERROR] Failed to read {dev_path}: {e}")
        return None, 0

def find_xin_devices():
    """Scan /dev/input for devices containing 'xin' in their name."""
    print("\nScanning joystick devices...\n")
    devices = []
    for i in range(MAX_DEVICES):
        dev_path = f"/dev/input/js{i}"
        if not os.path.exists(dev_path):
            continue

        name, num_buttons = get_joystick_info(dev_path)
        print(f"  /dev/input/js{i} (index {i}): '{name}' - {num_buttons} buttons")

        if "xin" in name.lower():
            devices.append((dev_path, name, num_buttons))

    if len(devices) < 2:
        print("\nWARNING: Fewer than two devices with 'xin' in the name were found.")
        print("If your stick reports a different name, share the 'Discovered devices' output above.")

    return devices

def poll_for_button_press(xin_devices):
    """Wait for a press of button #1 (A button) from either Xin-Mo device."""
    print(f"\nConfirm button 1 (A) on Atari Fight Stick Player 1 (left stick) timout {TIMEOUT_SECONDS} seconds...")

    start_time = time.time()
    fds = [open(d[0], "rb", buffering=0) for d in xin_devices]
    fd_map = {fds[i].fileno(): xin_devices[i] for i in range(len(fds))}

    try:
        while True:
            # Check for timeout
            elapsed = time.time() - start_time
            if elapsed > TIMEOUT_SECONDS:
                print("\nTimeout reached. No button press detected.")
                return None

            # Use select to wait for events
            rlist, _, _ = select.select(fds, [], [], 0.5)
            if not rlist:
                continue  # No events yet, keep looping

            for fd in rlist:
                data = fd.read(8)
                if not data:
                    continue

                time_stamp, value, event_type, number = struct.unpack("IhBB", data)

                # Ignore initialization events
                if event_type & JS_EVENT_INIT:
                    continue

                dev_path, dev_name, btn_count = fd_map[fd.fileno()]

                # Debug print (commented out)
                # print(f"DEBUG EVENT: Device={dev_path} | time={time_stamp} | value={value} | type={event_type} | number={number}")

                # Detect button press
                if event_type & JS_EVENT_BUTTON:
                    if value == 1 and number == 1:
                        print(f"\nDetected button 1 (A) press on {dev_name} ({dev_path})")
                        return (dev_path, dev_name, btn_count)
    finally:
        for fd in fds:
            fd.close()

def check_fallback_button_count(xin_devices):
    """
    Fallback check: if the first Xin-Mo has 15 buttons and the second has 13, it's probably correct.
    If reversed (13 then 15), warn and return swapped status.
    """
    first_dev = xin_devices[0]
    second_dev = xin_devices[1]

    print("\nNo button press detected - falling back to button count analysis...")

    if first_dev[2] == 15 and second_dev[2] == 13:
        print("Button count check suggests correct mapping (15 then 13).")
        return 0  # OK
    elif first_dev[2] == 13 and second_dev[2] == 15:
        print("\n[WARNING] Button count check suggests Player 1 and Player 2 are swapped!")
        return 1  # SWAPPED
    else:
        print("\n[WARNING] Button counts are unusual and inconclusive!")
        return 2  # ERROR

def main():
    print(f"Xin-Mo Joystick Identification Script v{VERSION}\n")

    # Step 1: Scan for devices
    xin_devices = find_xin_devices()

    if len(xin_devices) < 2:
        print("\n[ERROR] Less than two Xin-Mo devices found. Cannot continue.")
        sys.exit(2)  # Exit with error code 2

    # Step 2: Sort devices by path for stable ordering
    xin_devices.sort(key=lambda d: d[0])

    print("\nXin-Mo devices being watched:")
    for dev in xin_devices:
        print(f"  - {dev[0]} ({dev[1]}) with {dev[2]} buttons")

    # Step 3: Wait for Player 1 button press
    print("\nPress the A button (button 1) on PLAYER 1 now to confirm...")
    result = poll_for_button_press(xin_devices)

    if result:
        # If a button press was detected, use it directly
        dev_path, dev_name, btn_count = result

        if btn_count != EXPECTED_P1_BUTTONS:
            print(f"\n[WARNING] The device you identified as Player 1 has {btn_count} buttons (expected {EXPECTED_P1_BUTTONS}).")
            print("This strongly suggests the Player 1 and Player 2 controls are reversed!")
            sys.exit(1)  # Exit code 1 indicates swap detected
        else:
            print(f"\nPlayer 1 correctly identified on {dev_name} ({dev_path}).")
            sys.exit(0)  # Exit code 0 indicates correct mapping
    else:
        # Fallback to button count logic if timeout occurred
        status = check_fallback_button_count(xin_devices)
        sys.exit(status)

if __name__ == "__main__":
    main()
