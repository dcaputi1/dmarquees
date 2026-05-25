# MAME `mapdevice` Duplicate Device ID Bug — Fix Guide

## Background

MAME supports a `<mapdevice>` directive in controller config files (e.g. `allctrlrs.cfg`) that
maps a USB device ID string to a stable JOYCODE slot. This is used in IvarArcade to lock 6
controllers to specific JOYCODE_1 through JOYCODE_7 slots regardless of USB enumeration order.

The problem: **two controllers that share the same USB device ID** (e.g. two identical Xinmo
encoders) cannot both be mapped — only the first `<mapdevice>` entry survives. The second is
silently dropped.

## Affected Controllers

```xml
<!-- Xinmo 1 & 2 — identical USB ID, both need mapping -->
<mapdevice device="0300d582c0160000e105000010010000" controller="JOYCODE_2" />
<mapdevice device="0300d582c0160000e105000010010000" controller="JOYCODE_3" />  ← dropped!

<!-- iCode HuJia 1 & 2 — identical USB ID, both need mapping -->
<mapdevice device="030083a08f0e00001330000011010000" controller="JOYCODE_6" />
<mapdevice device="030083a08f0e00001330000011010000" controller="JOYCODE_7" />  ← dropped!
```

## Root Cause

**File:** `src/emu/input.h`

```cpp
using devicemap_table = util::transparent_string_map<std::string, std::string>;
```

`transparent_string_map` is a `std::map`-like unique-key container. Duplicate keys are silently
ignored on insert.

**File:** `src/emu/ioport.cpp` — function `ioport_manager::load_config()`

```cpp
input_manager::devicemap_table devicemap;
for (util::xml::data_node const *mapdevice_node = parentnode->get_child("mapdevice");
     mapdevice_node != nullptr;
     mapdevice_node = mapdevice_node->get_next_sibling("mapdevice"))
{
    char const *const devicename   = mapdevice_node->get_attribute_string("device", nullptr);
    char const *const controllername = mapdevice_node->get_attribute_string("controller", nullptr);
    if (devicename && controllername)
        devicemap.emplace(devicename, controllername);  // ← BUG: second emplace with same key is a no-op
}
machine().input().map_device_to_controller(devicemap);
```

When two `<mapdevice>` nodes share the same `device` attribute, the second `emplace` call does
nothing (map rejects duplicate keys). Only `JOYCODE_2` and `JOYCODE_6` survive; `JOYCODE_3` and
`JOYCODE_7` are never applied.

**File:** `src/emu/input.cpp` — function `input_manager::map_device_to_controller()`

This function iterates the devicemap, and for each entry scans physical devices for the first
match. With the map-type fix in place, this function works correctly for duplicate-ID controllers:
the first entry remaps physical device A to slot N, the second entry finds physical device A still
in the scan but now at slot N and swaps it with device B at slot N+1, leaving both assigned.
No changes needed here.

## The Fix

Apply to **MAME source** on the build machine (Pi 5 or cross-compile host).

### Change 1 — `src/emu/input.h`

Replace the `devicemap_table` type alias so it allows duplicate keys:

```cpp
// BEFORE:
using devicemap_table = util::transparent_string_map<std::string, std::string>;

// AFTER:
using devicemap_table = std::vector<std::pair<std::string, std::string>>;
```

Add `#include <vector>` and `#include <utility>` to the includes at the top of `input.h` if not
already present (check — `<vector>` is likely already pulled in transitively, but be explicit).

### Change 2 — `src/emu/ioport.cpp`

In `ioport_manager::load_config()`, change `emplace` to `emplace_back`:

```cpp
// BEFORE:
devicemap.emplace(devicename, controllername);

// AFTER:
devicemap.emplace_back(devicename, controllername);
```

### No change needed — `src/emu/input.cpp`

`map_device_to_controller` iterates with:
```cpp
for (const auto &it : table) { ... it.first ... it.second ... }
```
This works identically for both maps and `vector<pair<>>`. No modification required.

## Quick Diff

```diff
--- a/src/emu/input.h
+++ b/src/emu/input.h
-    using devicemap_table = util::transparent_string_map<std::string, std::string>;
+    using devicemap_table = std::vector<std::pair<std::string, std::string>>;

--- a/src/emu/ioport.cpp
+++ b/src/emu/ioport.cpp
-            devicemap.emplace(devicename, controllername);
+            devicemap.emplace_back(devicename, controllername);
```

## How to Find the Exact Lines

```bash
# On the Pi 5, in the MAME source tree:
grep -n "devicemap_table" src/emu/input.h
grep -n "devicemap.emplace"  src/emu/ioport.cpp
```

## Expected Behavior After Fix

With a `vector`, all `<mapdevice>` entries are preserved in config-file order. When
`map_device_to_controller` processes two entries with the same device ID:

1. **Entry 1** (`JOYCODE_2`): scans physical devices, finds first Xinmo at slot X, remaps it to
   slot 1 (JOYCODE_2 = devindex 1).
2. **Entry 2** (`JOYCODE_3`): scans again, finds the same device now at slot 1, remaps it to
   slot 2 — which swaps it with whatever is at slot 2 (the second Xinmo). Both are now assigned.

Both Xinmo controllers end up in JOYCODE_2 and JOYCODE_3. Which physical unit lands in which
slot is determined by USB enumeration order (nondeterministic between identical devices), but
both slots are reliably filled on every boot.

## Notes

- This bug has existed in MAME for years and as of 2026 is still unpatched upstream.
- The fix is minimal and safe — `vector<pair>` iteration is semantically equivalent to map
  iteration in `map_device_to_controller` since that function never does key-based lookup.
- The `allctrlrs.cfg` file itself requires **no changes** — the XML is already correct.
