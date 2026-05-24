-----------------------------------------------------------
-- USB Mapper Plugin (usbmap)
-- Reads the desired JOYCODE ordering from allctrlrs.cfg and
-- remaps all game cfg files to match the actual USB device
-- enumeration order at runtime.
--
-- For XinMo controllers (two devices, same GUID) the
-- correct player is identified by button count.
-- For all other duplicate-GUID devices the first-enumerated
-- unit is treated as P1.
-----------------------------------------------------------

local VERSION = "1.0.0"

local exports = {
    name        = "usbmap",
    version     = VERSION,
    description = "USB Mapper",
    license     = "MIT",
    author      = { name = "Dan Caputi" }
}

local usbmap = exports

-----------------------------------------------------------
-- Constants
-----------------------------------------------------------

-- Button counts that identify each XinMo player slot.
-- These must match the hardware; P1 = 15 buttons, P2 = 13.
local XINMO_P1_BTNS = 15
local XINMO_P2_BTNS = 13

local HOME      = os.getenv("HOME") or "/home/danc"
local MAME_BASE = "/opt/retropie/emulators/mame"
local REPO_CFG  = HOME .. "/IvarArcade/McAtariPi5/opt/retropie/emulators/mame"

local ALLCTRLRS = MAME_BASE .. "/ctrlr/allctrlrs.cfg"
local CFG_DIR   = MAME_BASE .. "/cfg"

-----------------------------------------------------------
-- Plugin State  (survives soft_reset within a session)
-----------------------------------------------------------

local remap_done     = false
local remap_applied  = false
local reset_notifier = nil
local stop_notifier  = nil

-----------------------------------------------------------
-- allctrlrs.cfg parsing
-----------------------------------------------------------

-- Returns an ordered list of the desired JOYCODE assignments
-- as specified in allctrlrs.cfg:
--   { { guid = "...", joycode_num = N }, ... }
-- Entries appear in document order, so duplicate GUIDs are
-- listed in the order MAME would assign them (first, second…).
local function parse_allctrlrs()
    local f = io.open(ALLCTRLRS, "r")
    if not f then
        print("[UsbMap] ERROR: Cannot open " .. ALLCTRLRS)
        return nil
    end
    local content = f:read("*a")
    f:close()

    local assignments = {}
    -- Match both attribute orderings just in case
    for guid, joynum in content:gmatch(
            '<mapdevice%s+device="([^"]+)"%s+controller="JOYCODE_(%d+)"') do
        table.insert(assignments, { guid = guid, joycode_num = tonumber(joynum) })
    end

    if #assignments == 0 then
        print("[UsbMap] ERROR: No <mapdevice> entries found in " .. ALLCTRLRS)
        return nil
    end

    print(string.format("[UsbMap] Parsed %d desired assignments from allctrlrs.cfg", #assignments))
    return assignments
end

-----------------------------------------------------------
-- Device enumeration
-----------------------------------------------------------

-- Returns a list of all live joystick devices sorted by
-- current devindex (= JOYCODE slot - 1):
--   { devindex, joycode_num, id, name, buttons }
local function enumerate_devices()
    local input = manager.machine.input
    local joyclass = nil
    for _, cls in pairs(input.device_classes) do
        if cls.name == "joystick" then joyclass = cls; break end
    end
    if not joyclass then
        print("[UsbMap] ERROR: joystick device class not available")
        return nil
    end

    local all = {}
    for _, device in pairs(joyclass.devices) do
        local btn_count = 0
        for _, item in pairs(device.items) do
            if tostring(item.token):match("^BUTTON%d") then
                btn_count = btn_count + 1
            end
        end
        table.insert(all, {
            devindex    = device.devindex,
            joycode_num = device.devindex + 1,
            id          = tostring(device.id),
            name        = device.name,
            buttons     = btn_count,
        })
    end
    table.sort(all, function(a, b) return a.devindex < b.devindex end)
    return all
end

-----------------------------------------------------------
-- Build the remap table
-----------------------------------------------------------

-- Compares the desired assignments (from allctrlrs.cfg) against
-- the live device order and returns a map:
--   { [desired_prefix] = actual_prefix }
-- Only entries that differ are included.
--
-- "desired_prefix" is what canonical cfg files already contain
-- (e.g. "JOYCODE_2_" meaning XinMo P1).
-- "actual_prefix"  is where that device physically landed this
-- boot (e.g. "JOYCODE_7_").
-- Applying this map to cfg files makes MAME address the correct
-- hardware regardless of USB enumeration order.
local function build_remap(desired_assignments, live_devices)
    -- Index live devices by GUID; each value is a list sorted by devindex
    local by_id = {}
    for _, dev in ipairs(live_devices) do
        if not by_id[dev.id] then by_id[dev.id] = {} end
        table.insert(by_id[dev.id], dev)
    end

    -- Track how many times each GUID has been matched so far
    local id_slot = {}

    local remap = {}   -- desired_prefix -> actual_prefix

    for _, entry in ipairs(desired_assignments) do
        local desired_prefix = string.format("JOYCODE_%d_", entry.joycode_num)
        local candidates     = by_id[entry.guid]

        if not candidates or #candidates == 0 then
            print("[UsbMap] WARNING: No live device found for GUID " .. entry.guid
                  .. " (desired " .. desired_prefix .. ")")
        else
            if not id_slot[entry.guid] then id_slot[entry.guid] = 0 end
            id_slot[entry.guid] = id_slot[entry.guid] + 1
            local slot = id_slot[entry.guid]

            local matched = nil

            if candidates[1].name:lower():find("xin") then
                -- XinMo: identify by button count; slot 1 = P1, slot 2 = P2
                local want_btns = (slot == 1) and XINMO_P1_BTNS or XINMO_P2_BTNS
                for _, dev in ipairs(candidates) do
                    if dev.buttons == want_btns then
                        matched = dev
                        break
                    end
                end
                if not matched then
                    print(string.format(
                        "[UsbMap] WARNING: No XinMo device with %d buttons for slot %d",
                        want_btns, slot))
                end
            else
                -- All others: first unmatched device in encounter order
                if slot <= #candidates then
                    matched = candidates[slot]
                else
                    print(string.format(
                        "[UsbMap] WARNING: Only %d device(s) with GUID %s (need slot %d)",
                        #candidates, entry.guid, slot))
                end
            end

            if matched then
                local actual_prefix = string.format("JOYCODE_%d_", matched.joycode_num)
                if actual_prefix ~= desired_prefix then
                    remap[desired_prefix] = actual_prefix
                    print(string.format(
                        "[UsbMap] Remap needed: cfg %s -> actual %s  '%s' btns=%d",
                        desired_prefix, actual_prefix, matched.name, matched.buttons))
                else
                    print(string.format(
                        "[UsbMap] OK: %s  '%s' btns=%d",
                        desired_prefix, matched.name, matched.buttons))
                end
            end
        end
    end

    return remap
end

-----------------------------------------------------------
-- Device enumeration log
-----------------------------------------------------------

local function log_all_joystick_devices(live_devices, remap)
    -- Build reverse map actual->desired for annotation
    local actual_to_desired = {}
    for desired, actual in pairs(remap) do
        actual_to_desired[actual] = desired
    end

    local xinmo_seen  = 0
    local huijia_seen = 0

    print("[UsbMap] --- Joystick device enumeration ---")
    for _, d in ipairs(live_devices) do
        local actual_prefix = string.format("JOYCODE_%d_", d.joycode_num)
        local lname         = d.name:lower()
        local label         = ""

        if lname:find("xin") then
            xinmo_seen = xinmo_seen + 1
            if d.buttons == XINMO_P1_BTNS then
                label = "XinMo P1"
            elseif d.buttons == XINMO_P2_BTNS then
                label = "XinMo P2"
            else
                label = "XinMo? (unexpected btn count)"
            end
        elseif lname:find("huijia") or lname:find("hui") then
            huijia_seen = huijia_seen + 1
            label = huijia_seen == 1 and "HuiJia P1" or "HuiJia P" .. huijia_seen
        end

        local remap_note = ""
        local desired = actual_to_desired[actual_prefix]
        if desired then
            remap_note = string.format("  (cfg had %s)", desired)
        end

        print(string.format("[UsbMap]  %-12s id=%-3d  btns=%-3d  '%s'%s%s",
            actual_prefix, d.devindex, d.buttons, d.name,
            label ~= "" and ("  [" .. label .. "]") or "",
            remap_note))
    end
    print("[UsbMap] --- end enumeration ---")
end

-----------------------------------------------------------
-- Apply remap to all cfg files
-----------------------------------------------------------

-- Uses a two-phase temp-token replacement to avoid chain
-- collisions when remapping overlapping JOYCODE numbers
-- (e.g. JOYCODE_2_->JOYCODE_7_ and JOYCODE_3_->JOYCODE_2_).
local function apply_remap_to_cfg(remap)
    -- Assign a unique temp token to each desired prefix
    local tokens = {}
    local i = 1
    for desired, _ in pairs(remap) do
        tokens[desired] = string.format("_USBMAP_TMP%d_", i)
        i = i + 1
    end

    local handle = io.popen("ls '" .. CFG_DIR .. "'/*.cfg 2>/dev/null")
    if not handle then
        print("[UsbMap] ERROR: Cannot list cfg files in " .. CFG_DIR)
        return
    end

    for path in handle:lines() do
        local f = io.open(path, "r")
        if not f then
            print("[UsbMap] ERROR: Cannot read " .. path)
        else
            local content = f:read("*a")
            f:close()

            local modified = content

            -- Phase 1: desired prefixes -> temp tokens
            for desired, tmp in pairs(tokens) do
                modified = modified:gsub(desired, tmp)
            end
            -- Phase 2: temp tokens -> actual prefixes
            for desired, tmp in pairs(tokens) do
                modified = modified:gsub(tmp, remap[desired])
            end

            if modified == content then
                print("[UsbMap] No change: " .. path)
            else
                local out = io.open(path, "w")
                if out then
                    out:write(modified)
                    out:close()
                    print("[UsbMap] Remapped:  " .. path)
                else
                    print("[UsbMap] ERROR: Cannot write " .. path)
                end
            end
        end
    end
    handle:close()
end

-----------------------------------------------------------
-- Game Stop: restore canonical cfg from repo
-----------------------------------------------------------

local function on_game_stop()
    if not remap_applied then
        print("[UsbMap] No remap was applied; skipping cfg restore")
        return
    end
    print("[UsbMap] Restoring cfg from repo on game stop")
    os.execute(string.format("cp -f '%s/cfg'/*.cfg '%s/cfg/' 2>/dev/null",
        REPO_CFG, MAME_BASE))
end

-----------------------------------------------------------
-- Game Start: perform remap when an actual game is launched
-----------------------------------------------------------

local function on_game_start()

    -- After soft_reset: already done for this session
    if remap_done then
        if remap_applied then
            manager.machine:popmessage("UsbMap: applied")
        end
        return
    end

    -- Parse desired ordering from allctrlrs.cfg
    local desired_assignments = parse_allctrlrs()
    remap_done = true

    if not desired_assignments then return end

    -- Enumerate live devices
    local live_devices = enumerate_devices()
    if not live_devices or #live_devices == 0 then
        print("[UsbMap] No joystick devices found")
        return
    end

    -- Build the cfg remap table (desired -> actual)
    local remap = build_remap(desired_assignments, live_devices)

    -- Log the current device layout with remap annotations
    log_all_joystick_devices(live_devices, remap)

    -- Count changes needed
    local n = 0
    for _ in pairs(remap) do n = n + 1 end

    if n == 0 then
        print("[UsbMap] All devices already in correct order - no cfg changes needed")
        return
    end

    -- Apply remap and soft-reset so MAME picks up the patched cfg files
    print(string.format("[UsbMap] Applying %d remap(s) to cfg files...", n))
    apply_remap_to_cfg(remap)
    remap_applied = true
    manager.machine:popmessage("UsbMap: remapped")
    manager.machine:soft_reset()
end

-----------------------------------------------------------
-- Machine Reset Handler
-----------------------------------------------------------

local function on_machine_reset()
    -- Skip the MAME UI / empty system; only run for real game ROMs
    if emu.romname() == "___empty" then return end
    on_game_start()
end

-----------------------------------------------------------
-- Plugin Entry Point
-----------------------------------------------------------

function usbmap.startplugin()
    reset_notifier = emu.add_machine_reset_notifier(on_machine_reset)
    stop_notifier  = emu.add_machine_stop_notifier(on_game_stop)
end

return exports
