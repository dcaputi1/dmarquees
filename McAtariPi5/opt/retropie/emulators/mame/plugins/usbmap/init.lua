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

local VERSION = "1.3.1"

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
local XINMO_STATS_DIR = HOME ~= "" and (HOME .. "/IvarArcade/json") or nil
local XINMO_STATS_FILE = HOME ~= "" and (HOME .. "/IvarArcade/json/xinmo_mame_stats.json") or nil

-----------------------------------------------------------
-- Plugin State  (survives soft_reset within a session)
-----------------------------------------------------------

local remap_computed      = false  -- have we computed remap for this game session?
local cached_remap        = {}     -- cached remap table, reused on game-initiated resets
local cached_xinmo_remap  = {}     -- current XinMo remap table, reused on game-initiated resets
local cached_xinmo_devices = {}    -- live XinMo devices for this game session
local xinmo_desired_prefixes = {}  -- desired JOYCODE slots for the two XinMo halves
local xinmo_player1_joycode = nil  -- live JOYCODE currently assigned to XinMo player 1
local js_test_active      = false  -- waiting for an A button press on any joystick
local js_test_result      = nil    -- label of last detected device ("J3"), or nil
local js_test_snapshot    = {}     -- (unused, kept for compat)
local js_test_devices     = {}     -- device list captured at arm time
local js_code_poller      = nil    -- switch_code_poller active during a joycode test
local cached_ioport_tokens = nil   -- original ioport token strings before usbmap rewrites
local remap_applied       = false  -- was any remap needed? (for popmessage / reset state)
local pending_frame_remap = false  -- in-memory remap scheduled for first frame
local pending_xinmo_remap_joycode = nil  -- deferred XinMo swap applied on next emulation frame
local xinmo_verify_countdown = 0         -- frames remaining before post-swap verify
local xinmo_verify_expected  = {}        -- {desired_prefix -> actual_prefix} expected after swap
local reset_notifier = nil
local stop_notifier  = nil
local frame_notifier = nil
local apply_remap_to_ioports
local enumerate_devices

-----------------------------------------------------------
-- XinMo stats persistence
-----------------------------------------------------------

local function _ensure_xinmo_stats_dir()
    if not XINMO_STATS_DIR then
        return false
    end

    local escaped_dir = XINMO_STATS_DIR:gsub('"', '\\"')
    local ok = os.execute(string.format('mkdir -p "%s" >/dev/null 2>&1', escaped_dir))
    if ok == true or ok == 0 then
        return true
    end

    print("[UsbMap] WARNING: Cannot create XinMo stats dir " .. XINMO_STATS_DIR)
    return false
end

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
    if not _ensure_xinmo_stats_dir() then
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

local function _has_entries(remap)
    for _ in pairs(remap) do
        return true
    end
    return false
end

local function _copy_array(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        table.insert(out, value)
    end
    return out
end

local function _prefix_to_joycode_num(prefix)
    return tonumber((prefix or ""):match("^JOYCODE_(%d+)_$"))
end

local function _count_entries(remap)
    local count = 0
    for _ in pairs(remap or {}) do
        count = count + 1
    end
    return count
end

local function _merge_remaps(primary, secondary)
    local merged = {}
    for desired, actual in pairs(primary or {}) do
        merged[desired] = actual
    end
    for desired, actual in pairs(secondary or {}) do
        merged[desired] = actual
    end
    return merged
end

local function _ioport_token_key(port_tag, field_name, seqtype)
    return table.concat({ tostring(port_tag), tostring(field_name), tostring(seqtype) }, "\31")
end

local function _capture_ioport_baseline_if_needed()
    if cached_ioport_tokens ~= nil then
        return
    end

    local input  = manager.machine.input
    local ioport = manager.machine.ioport
    cached_ioport_tokens = {}

    for port_tag, port in pairs(ioport.ports) do
        for field_name, field in pairs(port.fields) do
            for seqtype = 0, 2 do
                local ok_seq, seq = pcall(function() return field:input_seq(seqtype) end)
                if ok_seq and seq then
                    local ok_tokens, tokens = pcall(function()
                        return input:seq_to_tokens(seq)
                    end)
                    if ok_tokens and tokens ~= nil then
                        cached_ioport_tokens[_ioport_token_key(port_tag, field_name, seqtype)] = tokens
                    end
                end
            end
        end
    end
end

local function _other_xinmo_joycode(player1_joycode)
    for _, dev in ipairs(cached_xinmo_devices) do
        if dev.joycode_num ~= player1_joycode then
            return dev.joycode_num
        end
    end
    return nil
end

local function _build_xinmo_remap(player1_joycode)
    if not player1_joycode or #xinmo_desired_prefixes < 2 or #cached_xinmo_devices < 2 then
        return {}
    end

    local player2_joycode = _other_xinmo_joycode(player1_joycode)
    if not player2_joycode then
        return {}
    end

    local remap = {}
    local desired_p1 = xinmo_desired_prefixes[1]
    local desired_p2 = xinmo_desired_prefixes[2]
    local actual_p1 = string.format("JOYCODE_%d_", player1_joycode)
    local actual_p2 = string.format("JOYCODE_%d_", player2_joycode)

    if actual_p1 ~= desired_p1 then
        remap[desired_p1] = actual_p1
    end
    if actual_p2 ~= desired_p2 then
        remap[desired_p2] = actual_p2
    end

    return remap
end

-- switch_code_poller instance active while a joycode test is running.
-- Returns the first host switch code activated after arm time, which lets
-- us identify the device even when item.current has already gone back to 0.
local js_code_poller = nil

local function _arm_js_test()
    local live_devices = enumerate_devices()
    if not live_devices or #live_devices == 0 then
        manager.machine:popmessage("UsbMap: No joysticks found")
        return false
    end
    js_test_devices  = live_devices
    js_test_snapshot = {}
    js_test_active   = true

    -- Also start a switch_code_poller as a second detection path.
    -- After reset() any newly-activated switch (including BUTTON1) will be
    -- returned by the next poll() call; code_to_token() then gives the full
    -- "JOYCODE_N_BUTTON1" token so we can identify the device.
    js_code_poller = nil
    local ok, p = pcall(function() return manager.machine.input:switch_code_poller() end)
    if ok and p then
        pcall(function() p:reset() end)
        js_code_poller = p
        print("[UsbMap] Button A joycode test armed; waiting for any button (item.current + code_poller)")
    else
        print("[UsbMap] Button A joycode test armed; waiting for any button (item.current only)")
    end
    return true
end

local function _poll_js_test_hit()
    if not js_test_active then return false end

    -- Strategy: read item.current directly on each cached button item.
    -- This is the same raw hardware state the MAME "Input Devices" tab window
    -- displays.  item.current is a live signed integer (0 = neutral) that does
    -- not go through code_from_token / code_value, so it works even when the
    -- menu intercepts BUTTON1 as UI_Select before the frame notifier fires.
    for _, dev in ipairs(js_test_devices) do
        for _, btn_item in ipairs(dev.button_items) do
            local ok, val = pcall(function() return btn_item.item.current end)
            if ok and val and val ~= 0 then
                js_test_active   = false
                js_test_snapshot = {}
                js_test_devices  = {}
                js_code_poller   = nil
                local label = string.format("J%d", dev.joycode_num)
                js_test_result   = label
                print(string.format("[UsbMap] Button A joycode test: %s detected on %s (item.current=%d)",
                    btn_item.token, label, val))
                return true
            end
        end
    end

    -- Fallback: drain the switch_code_poller.  This catches a very brief tap
    -- that has already gone back to 0 by the time item.current is read.
    -- code_to_token() returns the full "JOYCODE_N_ITEM" string; match the N
    -- back to one of our known devices.
    if js_code_poller then
        local ok_poll, code = pcall(function() return js_code_poller:poll() end)
        if ok_poll and code then
            local ok_tok, token = pcall(function()
                return manager.machine.input:code_to_token(code)
            end)
            if ok_tok and token and token ~= "" then
                local jnum = tonumber(token:match("^JOYCODE_(%d+)_"))
                if jnum then
                    for _, dev in ipairs(js_test_devices) do
                        if dev.joycode_num == jnum then
                            js_test_active   = false
                            js_test_snapshot = {}
                            js_test_devices  = {}
                            js_code_poller   = nil
                            local label = string.format("J%d", jnum)
                            js_test_result   = label
                            print(string.format(
                                "[UsbMap] Button A joycode test: detected on %s via code_poller (token=%s)",
                                label, token))
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

local function _apply_xinmo_player1_assignment(player1_joycode)
    if not player1_joycode then
        manager.machine:popmessage("UsbMap: XinMo assignment unavailable")
        return false
    end

    local remap = _build_xinmo_remap(player1_joycode)
    local count = 0
    xinmo_player1_joycode = player1_joycode
    cached_xinmo_remap = remap

    local effective_remap = _merge_remaps(cached_remap, cached_xinmo_remap)
    if _has_entries(effective_remap) then
        print(string.format("[UsbMap] Applying XinMo Player 1 assignment to J%d", player1_joycode))
        count = apply_remap_to_ioports(effective_remap, true)
    else
        print(string.format("[UsbMap] XinMo Player 1 already matches J%d", player1_joycode))
    end

    if count > 0 or not _has_entries(remap) then
        -- Schedule a 2-frame deferred verify to check whether set_input_seq persists
        if _has_entries(cached_xinmo_remap) then
            xinmo_verify_countdown = 2
            xinmo_verify_expected  = cached_xinmo_remap  -- {desired -> actual}
        end
        manager.machine:popmessage(string.format("UsbMap: XinMo P1 = J%d", player1_joycode))
        return true
    end

    manager.machine:popmessage("UsbMap: XinMo assignment failed")
    return false
end

local function _cycle_xinmo_player1_assignment()
    if #cached_xinmo_devices < 2 then
        manager.machine:popmessage("UsbMap: XinMo assignment unavailable")
        return false
    end

    local next_joycode = cached_xinmo_devices[1].joycode_num
    if xinmo_player1_joycode == next_joycode and cached_xinmo_devices[2] then
        next_joycode = cached_xinmo_devices[2].joycode_num
    end

    -- Update display immediately so the menu reflects the change now.
    -- The actual ioport remap is deferred to the next emulation frame because
    -- MAME pauses emulation while the plugin menu is open; set_input_seq
    -- changes made while paused are discarded when emulation resumes.
    xinmo_player1_joycode       = next_joycode
    pending_xinmo_remap_joycode = next_joycode
    print(string.format("[UsbMap] XinMo swap queued: P1=J%d (will apply on next emulation frame)", next_joycode))
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
--   { devindex, joycode_num, id, name, buttons, button_items }
enumerate_devices = function()
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
        local button_items = {}
        for _, item in pairs(device.items) do
            if tostring(item.token):match("^BUTTON%d") then
                btn_count = btn_count + 1
                table.insert(button_items, {
                    token = tostring(item.token),
                    item = item,
                })
            end
        end
        table.insert(all, {
            devindex    = device.devindex,
            joycode_num = device.devindex + 1,
            id          = tostring(device.id),
            name        = device.name,
            buttons     = btn_count,
            button_items = button_items,
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

    local remap = {}
    local xinmo_info = {
        desired_prefixes = {},
        devices = {},
        default_player1_joycode = nil,
    }

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
                if #xinmo_info.devices == 0 then
                    xinmo_info.devices = _copy_array(candidates)
                    table.sort(xinmo_info.devices, function(a, b)
                        return a.joycode_num < b.joycode_num
                    end)
                    for _, dev in ipairs(xinmo_info.devices) do
                        if dev.buttons == XINMO_P1_BTNS then
                            xinmo_info.default_player1_joycode = dev.joycode_num
                            break
                        end
                    end
                end
                table.insert(xinmo_info.desired_prefixes, desired_prefix)

                local want_btns = (slot == 1) and XINMO_P1_BTNS or XINMO_P2_BTNS
                for _, dev in ipairs(candidates) do
                    if dev.buttons == want_btns then
                        matched = dev
                        break
                    end
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

    if not xinmo_info.default_player1_joycode and xinmo_info.devices[1] then
        xinmo_info.default_player1_joycode = xinmo_info.devices[1].joycode_num
    end

    return remap, xinmo_info
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
apply_remap_to_ioports = function(remap, use_baseline)
    local input  = manager.machine.input
    local ioport = manager.machine.ioport
    local count  = 0
    local scanned = 0

    if use_baseline then
        _capture_ioport_baseline_if_needed()
    end

    local tmp_tokens = {}
    local i = 1
    for desired, _ in pairs(remap) do
        tmp_tokens[desired] = string.format("__USBMAPTMP%d__", i)
        i = i + 1
    end

    for port_tag, port in pairs(ioport.ports) do
        for field_name, field in pairs(port.fields) do
            -- 0 = standard, 1 = increment, 2 = decrement
            for seqtype = 0, 2 do
                local ok, seq = pcall(function() return field:input_seq(seqtype) end)
                if ok and seq then
                    local ok2, tok_str = pcall(function()
                        return input:seq_to_tokens(seq)
                    end)
                    if ok2 and tok_str and tok_str ~= "" then
                        scanned = scanned + 1
                        local source_tokens = tok_str
                        if use_baseline and cached_ioport_tokens then
                            source_tokens = cached_ioport_tokens[_ioport_token_key(port_tag, field_name, seqtype)] or tok_str
                        end

                        local modified = source_tokens
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

    print(string.format("[UsbMap] In-memory remap: updated %d field sequence(s) (scanned %d fields)", count, scanned))
    return count
end

local function menu_populate()
    -- Poll while the menu is open: the frame notifier is paused during menu display
    -- so we must poll here to detect button presses for the joycode test.
    _poll_js_test_hit()

    local p1_j   = xinmo_player1_joycode and ("J" .. xinmo_player1_joycode) or "??"
    local p2_num = xinmo_player1_joycode and _other_xinmo_joycode(xinmo_player1_joycode) or nil
    local p2_j   = p2_num and ("J" .. p2_num) or "??"
    local xinmo_state = "P1:" .. p1_j .. " / P2:" .. p2_j

    local js_label
    if js_test_active then
        js_label = "Button A Joycode Test:  waiting..."
    elseif js_test_result then
        js_label = string.format("Button A Joycode Test: %s A Button HIT", js_test_result)
    else
        js_label = "Button A Joycode Test"
    end

    return {
        { js_label, "", "" },
        { "XinMo Swap", xinmo_state, "" }
    }
end

local function menu_callback(index, event)
    if index == 1 then
        if event == "select" then
            if js_test_active then
                -- BUTTON1 is mapped to UI_Select, so pressing A triggers this callback
                -- instead of (or before) the frame-poller.  Read item.current right now
                -- while the button is still held.  If it was a brief tap and already
                -- released, the code_poller fallback will catch it next poll.
                if not _poll_js_test_hit() then
                    -- Neither path detected it yet — leave test armed so the next
                    -- menu_populate redraw or frame-notifier poll can still catch it.
                end
                return true
            end
            if js_test_result then
                -- Clear last result and allow re-arm
                js_test_result = nil
                return true
            end
            return _arm_js_test()
        end

        return false
    end

    if index == 2 then
        if event == "select" then
            return _cycle_xinmo_player1_assignment()
        end

        return false
    end

    return false
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
    cached_xinmo_remap  = {}
    cached_xinmo_devices = {}
    xinmo_desired_prefixes = {}
    xinmo_player1_joycode = nil
    js_test_active      = false
    js_test_result      = nil
    js_test_snapshot    = {}
    js_test_devices     = {}
    js_code_poller      = nil
    cached_ioport_tokens = nil
    remap_applied       = false
    pending_frame_remap = false
    pending_xinmo_remap_joycode = nil
    xinmo_verify_countdown = 0
    xinmo_verify_expected  = {}
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
                local full_remap, xinmo_info = build_remap(desired_assignments, live_devices)
                local xinmo_prefixes = {}
                for _, desired_prefix in ipairs(xinmo_info.desired_prefixes) do
                    xinmo_prefixes[desired_prefix] = true
                end
                cached_remap = {}
                for desired, actual in pairs(full_remap) do
                    if not xinmo_prefixes[desired] then
                        cached_remap[desired] = actual
                    end
                end
                cached_xinmo_devices = _copy_array(xinmo_info.devices)
                xinmo_desired_prefixes = _copy_array(xinmo_info.desired_prefixes)
                xinmo_player1_joycode = xinmo_info.default_player1_joycode
                cached_xinmo_remap = {}
                log_all_joystick_devices(live_devices, full_remap)

                local n = _count_entries(cached_remap)

                if n == 0 then
                    print("[UsbMap] All non-XinMo devices already in correct order - no remap needed")
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

    if remap_computed and (_has_entries(cached_remap) or _has_entries(cached_xinmo_remap)) then
        pending_frame_remap = true
    end

    on_game_start()
end

-----------------------------------------------------------
-- Plugin Entry Point
-----------------------------------------------------------

local function on_first_frame()
    if pending_frame_remap then
        pending_frame_remap = false
        local effective_remap = _merge_remaps(cached_remap, cached_xinmo_remap)
        local n = _count_entries(effective_remap)
        if n > 0 then
            print(string.format("[UsbMap] Applying %d remap(s) to ioport fields (first frame)...", n))
            apply_remap_to_ioports(effective_remap, true)
        end
    end

    if pending_xinmo_remap_joycode then
        local target = pending_xinmo_remap_joycode
        pending_xinmo_remap_joycode = nil
        _apply_xinmo_player1_assignment(target)
    end

    if xinmo_verify_countdown > 0 then
        xinmo_verify_countdown = xinmo_verify_countdown - 1
        if xinmo_verify_countdown == 0 then
            -- Check whether the sequences we wrote 2 frames ago are still in place
            local inp    = manager.machine.input
            local ioport = manager.machine.ioport
            local still_swapped = 0
            local reverted      = 0
            for desired, actual in pairs(xinmo_verify_expected) do
                for _, port in pairs(ioport.ports) do
                    for _, field in pairs(port.fields) do
                        local ok, seq = pcall(function() return field:input_seq(0) end)
                        if ok and seq then
                            local ok2, tok = pcall(function() return inp:seq_to_tokens(seq) end)
                            if ok2 and tok and tok ~= "" then
                                if tok:find(actual, 1, true) then
                                    still_swapped = still_swapped + 1
                                elseif tok:find(desired, 1, true) then
                                    reverted = reverted + 1
                                end
                            end
                        end
                    end
                end
            end
            xinmo_verify_expected = {}
            print(string.format("[UsbMap] SWAP VERIFY (+2 frames): %d field(s) show swapped tokens, %d reverted to original",
                still_swapped, reverted))
            if reverted > 0 and still_swapped == 0 then
                print("[UsbMap] SWAP VERIFY: *** set_input_seq DID NOT PERSIST -- in-memory swap cannot work here ***")
            elseif still_swapped > 0 then
                print("[UsbMap] SWAP VERIFY: swap tokens ARE persisting (if game input unchanged, issue is elsewhere)")
            else
                print("[UsbMap] SWAP VERIFY: no matching XinMo tokens found in any ioport field")
            end
        end
    end

    _poll_js_test_hit()
end

function usbmap.startplugin()
    print(string.format("[UsbMap] v%s loaded", VERSION))
    reset_notifier = emu.add_machine_reset_notifier(on_machine_reset)
    stop_notifier  = emu.add_machine_stop_notifier(on_game_stop)
    frame_notifier = emu.add_machine_frame_notifier(on_first_frame)
	emu.register_menu(menu_callback, menu_populate, "USB Map")
end

return exports
