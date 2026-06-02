-----------------------------------------------------------
-- USB Mapper Plugin (usbmap)
-- Reads the desired JOYCODE ordering from allctrlrs.cfg and
-- remaps live ioport fields in memory to match the actual USB
-- device enumeration order at runtime.
--
-- For XinMo controllers (two devices, same GUID) the
-- correct player is identified by button count.
-- For all other duplicate-GUID devices the first-enumerated
-- unit is treated as P1.
-----------------------------------------------------------

local VERSION = "1.1.0"

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

local MAME_BASE = "/opt/retropie/emulators/mame"

local ALLCTRLRS = MAME_BASE .. "/ctrlr/allctrlrs.cfg"
local HOME = os.getenv("HOME") or ""
local XINMO_STATS_FILE = HOME ~= "" and (HOME .. "/IvarArcade/json/xinmo_mame_stats.json") or nil

-----------------------------------------------------------
-- Plugin State  (survives soft_reset within a session)
-----------------------------------------------------------

local remap_computed      = false  -- have we computed remap for this game session?
local cached_remap        = {}     -- cached remap table, reused on game-initiated resets
local remap_applied       = false  -- was any remap needed? (for popmessage / reset state)
local pending_frame_remap = false  -- in-memory remap scheduled for first frame
local xinmo_swap_fixed    = false  -- did this session correct XinMo ordering?
local reset_notifier = nil
local stop_notifier  = nil
local frame_notifier = nil

-----------------------------------------------------------
-- XinMo stats persistence
-----------------------------------------------------------

local function _read_xinmo_stats()
    local stats = { swaps = 0, last_swap = nil }
    if not XINMO_STATS_FILE then
        return stats
    end

    local f = io.open(XINMO_STATS_FILE, "r")
    if not f then
        return stats
    end

    local content = f:read("*a") or ""
    f:close()

    local swaps = tonumber(content:match('"swaps"%s*:%s*(%d+)'))
    local last_swap = content:match('"last_swap"%s*:%s*"([^"]+)"')
    if swaps then
        stats.swaps = swaps
    end
    if last_swap and last_swap ~= "" then
        stats.last_swap = last_swap
    end
    return stats
end

local function _write_xinmo_stats(stats)
    if not XINMO_STATS_FILE then
        return false
    end

    local f = io.open(XINMO_STATS_FILE, "w")
    if not f then
        print("[UsbMap] WARNING: Cannot write XinMo stats file " .. XINMO_STATS_FILE)
        return false
    end

    local last_swap_json = stats.last_swap and string.format('"%s"', stats.last_swap) or "null"
    f:write(string.format('{"swaps": %d, "last_swap": %s}\n', stats.swaps or 0, last_swap_json))
    f:close()
    return true
end

local function _record_xinmo_swap_if_needed(remap, live_devices)
    if not XINMO_STATS_FILE then
        return false
    end

    local remapped_actual = {}
    for _, actual in pairs(remap) do
        remapped_actual[actual] = true
    end

    local xinmo_swap = false
    for _, dev in ipairs(live_devices) do
        local actual_prefix = string.format("JOYCODE_%d_", dev.joycode_num)
        if remapped_actual[actual_prefix] and dev.name:lower():find("xin") then
            xinmo_swap = true
            break
        end
    end

    if not xinmo_swap then
        return false
    end

    local stats = _read_xinmo_stats()
    stats.swaps = (tonumber(stats.swaps) or 0) + 1
    stats.last_swap = os.date("!%Y-%m-%dT%H:%M:%SZ")
    if _write_xinmo_stats(stats) then
        print(string.format("[UsbMap] XinMo stats updated: swaps=%d last_swap=%s", stats.swaps, stats.last_swap))
    end
    return true
end

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
-- Apply remap to live ioport fields in memory
-----------------------------------------------------------

-- Directly modifies the input sequences of all ioport fields to replace
-- any JOYCODE tokens that appear in the remap table.  Uses the same
-- two-phase temp-token strategy as the cfg-file patcher to avoid chain
-- collisions.  Wrapped in pcall throughout so that API differences
-- between MAME versions degrade gracefully.
local function apply_remap_to_ioports(remap)
    local input  = manager.machine.input
    local ioport = manager.machine.ioport
    local count  = 0

    local tmp_tokens = {}
    local i = 1
    for desired, _ in pairs(remap) do
        tmp_tokens[desired] = string.format("__USBMAPTMP%d__", i)
        i = i + 1
    end

    for _, port in pairs(ioport.ports) do
        for _, field in pairs(port.fields) do
            -- 0 = standard, 1 = increment, 2 = decrement
            for seqtype = 0, 2 do
                local ok, seq = pcall(function() return field:input_seq(seqtype) end)
                if ok and seq then
                    local ok2, tok_str = pcall(function()
                        return input:seq_to_tokens(seq)
                    end)
                    if ok2 and tok_str and tok_str ~= "" then
                        local modified = tok_str
                        for desired, tmp in pairs(tmp_tokens) do
                            modified = modified:gsub(desired, tmp)
                        end
                        for desired, tmp in pairs(tmp_tokens) do
                            modified = modified:gsub(tmp, remap[desired])
                        end
                        if modified ~= tok_str then
                            local ok3, new_seq = pcall(function()
                                return input:seq_from_tokens(modified)
                            end)
                            if ok3 and new_seq then
                                local ok4 = pcall(function()
                                    field:set_input_seq(seqtype, new_seq)
                                end)
                                if ok4 then
                                    -- Readback to verify the change persisted
                                    local ok5, chk_seq = pcall(function() return field:input_seq(seqtype) end)
                                    local chk_str = ""
                                    if ok5 and chk_seq then
                                        local ok6, s = pcall(function() return input:seq_to_tokens(chk_seq) end)
                                        if ok6 and s then chk_str = s end
                                    end
                                    local fname = ""
                                    pcall(function() fname = tostring(field.name) end)
                                    if chk_str == modified then
                                        print(string.format("[UsbMap]   patched '%s' st=%d: %s -> %s",
                                            fname, seqtype, tok_str, modified))
                                        count = count + 1
                                    else
                                        print(string.format("[UsbMap]   PATCH LOST '%s' st=%d: wrote=%s got=%s",
                                            fname, seqtype, modified, chk_str))
                                    end
                                else
                                    print("[UsbMap] WARNING: set_input_seq failed (seqtype=" .. seqtype .. ")")
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    print(string.format("[UsbMap] In-memory remap: updated %d field sequence(s)", count))
    return count
end

-----------------------------------------------------------
-- Game Stop: clear session state only
-----------------------------------------------------------

local function on_game_stop()
    if remap_applied then
        print("[UsbMap] Game stop: clearing in-memory remap state")
    end
    -- Reset all session state for the next game
    remap_computed      = false
    cached_remap        = {}
    remap_applied       = false
    pending_frame_remap = false
    xinmo_swap_fixed    = false
end

-----------------------------------------------------------
-- Game Start: perform remap when an actual game is launched
-----------------------------------------------------------

local function on_game_start()
    print(string.format("[UsbMap] on_game_start entered  remap_computed=%s  remap_applied=%s",
        tostring(remap_computed), tostring(remap_applied)))

    -- First time for this game session: compute the desired live remap.
    -- The control fix is applied only to in-memory ioport fields below;
    -- canonical cfg files remain unchanged on disk.
    if not remap_computed then
        remap_computed = true

        local desired_assignments = parse_allctrlrs()
        if desired_assignments then
            local live_devices = enumerate_devices()
            if not live_devices or #live_devices == 0 then
                print("[UsbMap] No joystick devices found")
            else
                cached_remap = build_remap(desired_assignments, live_devices)
                log_all_joystick_devices(live_devices, cached_remap)
                xinmo_swap_fixed = _record_xinmo_swap_if_needed(cached_remap, live_devices)

                local n = 0
                for _ in pairs(cached_remap) do n = n + 1 end

                if n == 0 then
                    print("[UsbMap] All devices already in correct order - no remap needed")
                else
                    remap_applied = true
                    -- Schedule in-memory ioport remap for the first emulation frame.
                    -- MAME caches cfg values before firing the reset notifier and applies
                    -- them to ioport fields after this callback returns, so patching here
                    -- would be overwritten. Deferring to the first frame ensures the
                    -- canonical cfg values are in place when we remap them in memory.
                    pending_frame_remap = true
                end
            end
        end
    end
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

local function on_first_frame()
    if not pending_frame_remap then return end
    pending_frame_remap = false
    local n = 0
    for _ in pairs(cached_remap) do n = n + 1 end
    if n > 0 then
        print(string.format("[UsbMap] Applying %d remap(s) to ioport fields (first frame)...", n))
        apply_remap_to_ioports(cached_remap)
        if xinmo_swap_fixed then
            manager.machine:popmessage("UsbMap: XinMo swap")
        end
    end
end

function usbmap.startplugin()
    print(string.format("[UsbMap] v%s loaded", VERSION))
    reset_notifier = emu.add_machine_reset_notifier(on_machine_reset)
    stop_notifier  = emu.add_machine_stop_notifier(on_game_stop)
    frame_notifier = emu.add_machine_frame_notifier(on_first_frame)
end

return exports
