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

If the exact original right-hand side has changed upstream, the fix is still the same: rewrite the
`using devicemap_table = ...;` alias to the `std::vector<std::pair<std::string, std::string>>`
form above.

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
+#include <utility>
+#include <vector>
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

---

## Building a Patched MAME via RetroPie-Setup

This section documents how to integrate the fix into a RetroPie-Setup "Install From Source"
build using the patched MAME scriptmodule from the sibling `RetroPie-Setup` repo.

### Modified Scriptmodule

**Authoritative project file (deploy this to the Pi 5):**
```
../RetroPie-Setup/scriptmodules/emulators/mame.sh
```
In this workspace, that file is the single source of truth. It maps to the on-device path
`~/RetroPie-Setup/scriptmodules/emulators/mame.sh`.

**What the script does differently from upstream:**

| Function | Change |
|----------|--------|
| Module scope | `__keep_sources=1` — prevents RetroPie-Setup from deleting the build directory after install |
| Module scope | `IVAR_MAME_PROFILE=full|arcade` — selects full MAME (`mame`, upstream `arcade.flt`) or stripped-down MAME (`mamearcade`, custom `arcade.flt`) |
| `sources_mame()` | After `gitPullOrClone`, applies both `sed` patches; prints pass/fail per file; pauses for your verification before the multi-hour build starts |
| `depends_mame()` | On desktop/X11 builds, installs Qt 6 build dependencies including `qmake6` explicitly (needed on current Debian 13 / trixie packages) |
| `build_mame()` | Always passes `REGENIE=1` and forces `ARCHOPTS_CXX=-std=c++20` in the wrapper so current MAME releases build cleanly on newer GCC toolchains |
| `install_mame()` | After copying build artifacts to `/opt/retropie/emulators/mame/`, also copies the two patched files to `/home/danc/mame-src-patched/src/emu/` for permanent reference; sets `__keep_sources=1` again immediately before the framework cleanup check |

### Deploy to Pi 5

```bash
# From your workstation, in the IvarArcade project root:
scp ../RetroPie-Setup/scriptmodules/emulators/mame.sh \
    danc@<pi5-ip>:~/RetroPie-Setup/scriptmodules/emulators/mame.sh
```

Or over SSH directly on the Pi 5, update the file in place inside the checked-out `RetroPie-Setup` repo:
```bash
# On the Pi 5:
cd ~/RetroPie-Setup
git pull
```

If the Pi does not have the `RetroPie-Setup` repo checked out, copy the file from the workstation
path `../RetroPie-Setup/scriptmodules/emulators/mame.sh` instead of expecting a second tracked
copy under `IvarArcade`.

### Run the Build

Build the full MAME target right now:

```bash
sudo env IVAR_MAME_PROFILE=full ~/RetroPie-Setup/retropie_setup.sh
# Navigate: Manage packages → Manage experimental packages → mame → Install from source
```

Later, switch back to the stripped-down arcade-only build from the same checkout:

```bash
sudo env IVAR_MAME_PROFILE=arcade ~/RetroPie-Setup/retropie_setup.sh
# Navigate: Manage packages → Manage experimental packages → mame → Install from source
```

If `IVAR_MAME_PROFILE` is unset, the script defaults to `arcade`.

The setup script runs four steps in order: **sources → build → install → configure**.

For Debian 13 / trixie on Pi 5, let RetroPie-Setup install dependencies first so the build gets
`qmake6`, and keep the patched script in place so the wrapper reasserts C++20 even if local
toolchain overrides or stale generated files would otherwise drop it.

### What You See During the Sources Step

After `git clone` (or pull) completes, the modified script applies the patches and pauses:

```
IvarArcade: building MAME profile 'full'
   [OK] using upstream arcade.flt and full MAME target

IvarArcade: applying mapdevice duplicate-ID fix...
  [OK] src/emu/input.h: devicemap_table -> std::vector<std::pair<std::string, std::string>>
  [OK] src/emu/ioport.cpp: devicemap.emplace() -> emplace_back()

Source tree: /home/danc/RetroPie-Setup/tmp/build/mame

Verify the applied changes:
  grep -n 'devicemap_table' /home/danc/RetroPie-Setup/tmp/build/mame/src/emu/input.h
  grep -n 'emplace_back'    /home/danc/RetroPie-Setup/tmp/build/mame/src/emu/ioport.cpp

Press Enter to start the build, or Ctrl+C to abort and fix manually...
```

Run the `grep` commands in a second terminal to confirm, then press **Enter**. The build takes
roughly 3–6 hours on a Pi 5.

If a pattern is not found (e.g. the MAME version changed the surrounding code), the script
prints `[!!]` for that file and still pauses. In that case:
1. Press **Ctrl+C** to abort.
2. Navigate to the source: `cd ~/RetroPie-Setup/tmp/build/mame`
3. Apply the fix manually per the **Quick Diff** section above.
4. Back in `retropie_setup.sh`: select `mame` → **Build** (skips the sources step).

### Source Locations After a Successful Build

Because `__keep_sources=1` is set, the full MAME source tree is preserved at:
```
~/RetroPie-Setup/tmp/build/mame/
```

The two patched files are also explicitly copied to:
```
/home/danc/mame-src-patched/src/emu/input.h
/home/danc/mame-src-patched/src/emu/ioport.cpp
```

### Restoring the Upstream Script

After the build, restore the stock scriptmodule so future `retropie_setup.sh` updates work
normally:

```bash
cd ~/RetroPie-Setup
git checkout scriptmodules/emulators/mame.sh
```

The patched MAME binary in `/opt/retropie/emulators/mame/` and the saved source files in
`/home/danc/mame-src-patched/` are unaffected by this reset.

### Re-applying After a MAME Version Bump

If MAME changes the surrounding code and the `sed` patterns no longer match:

1. Re-run `retropie_setup.sh` with either `IVAR_MAME_PROFILE=full` or `IVAR_MAME_PROFILE=arcade`
   and keep the modified scriptmodule in place.
2. At the pause prompt, press **Ctrl+C**.
3. Find the new location of the relevant lines:
   ```bash
   cd ~/RetroPie-Setup/tmp/build/mame
   grep -n "devicemap_table" src/emu/input.h
   grep -n "devicemap.emplace" src/emu/ioport.cpp
   ```
4. Apply the changes manually using the logic from the **Quick Diff** section above.
5. Return to `retropie_setup.sh` → `mame` → **Build** to continue.
