#!/usr/bin/env python3
import os
import sys
import glob

# Soft-coded joystick code positions
XIN1_CODE = "JOYCODE_2_"
XIN2_CODE = "JOYCODE_3_"

# Flag file written by the MAME PxSwap plugin when it auto-swaps.
# Removed here whenever the user takes manual control via this script.
PLUGIN_SWAP_FLAG = os.environ.get("HOME", "/home/danc") + "/.xinmo_plugin_swapped"

# Flag file written inside each cfg dir to track swap state.
# Named with a leading dot so MAME ignores it (only reads *.cfg).
SWAP_STATE_FLAG = ".xinmo_swapped"


def is_dir_swapped(cfg_directory):
    """Return True if cfg_directory contains the swap-state flag file."""
    return os.path.exists(os.path.join(cfg_directory, SWAP_STATE_FLAG))


def set_dir_swapped(cfg_directory, swapped):
    """Write or remove the swap-state flag file in cfg_directory."""
    flag = os.path.join(cfg_directory, SWAP_STATE_FLAG)
    if swapped:
        try:
            with open(flag, "w") as f:
                f.write("1\n")
        except Exception as e:
            print(f"ERROR: could not write {flag}: {e}")
    else:
        try:
            os.remove(flag)
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f"ERROR: could not remove {flag}: {e}")


def swap_joysticks_in_file(file_path):
    """
    Swap all XIN1_CODE with XIN2_CODE in a single file safely,
    returning the number of swaps made.
    """
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Count how many total XIN1_CODE and XIN2_CODE occurrences exist
        count_1 = content.count(XIN1_CODE)
        count_2 = content.count(XIN2_CODE)
        total_swaps = count_1 + count_2

        if total_swaps == 0:
            print(f"Swapped 0 joystick codes in: {file_path}")
            return 0

        # Use a temporary placeholder to avoid conflict during replacement
        content = content.replace(XIN1_CODE, "TEMPXIN1_")
        content = content.replace(XIN2_CODE, XIN1_CODE)
        content = content.replace("TEMPXIN1_", XIN2_CODE)

        with open(file_path, "w", encoding="utf-8") as f:
            f.write(content)

        print(f"Swapped {total_swaps} joystick codes in: {file_path}")
        return total_swaps

    except Exception as e:
        print(f"ERROR processing {file_path}: {e}")
        return 0


def process_directory(directory):
    """
    Swap joysticks for all *.cfg files in the given directory.
    Returns the total count of swaps made across all files.
    """
    cfg_files = glob.glob(os.path.join(directory, "*.cfg"))
    if not cfg_files:
        print("No .cfg files found in directory.")
        return 0

    total_swaps = 0
    for cfg_file in cfg_files:
        total_swaps += swap_joysticks_in_file(cfg_file)

    return total_swaps


def main():
    if len(sys.argv) != 3:
        print("Usage: swap_joysticks.py <cfg_directory> <swapped_flag>")
        print("  <cfg_directory> - Path to directory containing cfg files (including default.cfg)")
        print("  <swapped_flag>  - '0' normal, '1' swapped (XOR logic), or 'toggle' (always swap)")
        sys.exit(1)

    cfg_directory = sys.argv[1]
    swapped_flag = sys.argv[2]

    # User is taking manual control — clear any plugin-swap flag so xinmo-swapcheck
    # reports "menu swap" rather than "plugin swap" after this operation.
    try:
        os.remove(PLUGIN_SWAP_FLAG)
    except FileNotFoundError:
        pass

    # 'toggle' mode: unconditionally swap all cfg files regardless of current state.
    # Not used by normal callers but kept for manual/debug use.
    if swapped_flag == "toggle":
        print("Performing unconditional joystick toggle on all .cfg files...")
        total_swaps = process_directory(cfg_directory)
        new_state = not is_dir_swapped(cfg_directory)
        set_dir_swapped(cfg_directory, new_state)
        print(f"\nTotal joystick codes swapped across all files: {total_swaps}")
        return

    config_swapped = is_dir_swapped(cfg_directory)
    hardware_swapped = (swapped_flag == "1")

    print(f"Cfg dir '{cfg_directory}' state: {'swapped' if config_swapped else 'normal'}")
    print(f"Detected swapped_flag = {swapped_flag}")

    # Swap if hardware swapped XOR config swapped
    need_swap = hardware_swapped ^ config_swapped

    if not need_swap:
        print("No swap needed. Configuration matches hardware state.")
        sys.exit(0)

    print("Performing joystick swap on all .cfg files...")
    total_swaps = process_directory(cfg_directory)
    set_dir_swapped(cfg_directory, hardware_swapped)

    print(f"\nTotal joystick codes swapped across all files: {total_swaps}")


if __name__ == "__main__":
    main()
