-----------------------------------------------------------
-- Xin-Mo Swap Plugin
-- Detects P1/P2 controller swap via MAME's input driver
-- and corrects cfg files + soft-resets if needed.
-----------------------------------------------------------

local VERSION = "0.3.0"

local exports = {
    name        = "xinmo",
    version     = VERSION,
    description = "Xin-Mo Swap",
    license     = "MIT",
    author      = { name = "Dan Caputi" }
}

local xinmo = exports

-----------------------------------------------------------
-- Constants
-----------------------------------------------------------

local EXPECTED_P1_BTNS = 15   -- first XinMo device (JOYCODE_N_) should have 15 buttons
local EXPECTED_P2_BTNS = 13   -- second XinMo device should have 13 buttons

local HOME      = os.getenv("HOME") or "/home/danc"
local MAME_BASE = "/opt/retropie/emulators/mame"
local REPO_CFG  = HOME .. "/IvarArcade/McAtariPi5/opt/retropie/emulators/mame"

local SWAP_SCRIPT = "python3 /home/danc/scripts/xinmo-swap.py"

-- Persistent stats file tracking MAME-level swap detection history.
local MAME_STATS_FILE = HOME .. "/IvarArcade/json/xinmo_mame_stats.json"

-----------------------------------------------------------
-- Stats Tracking
-----------------------------------------------------------

local function update_mame_stats(swap_needed)
    local checks = 0
    local swapped = 0
    local last_swap = "null"
    local f = io.open(MAME_STATS_FILE, "r")
    if f then
        local content = f:read("*a")
        f:close()
        checks    = tonumber(content:match('"checks"%s*:%s*(%d+)')) or 0
        swapped   = tonumber(content:match('"swaps"%s*:%s*(%d+)'))  or 0
        local ls  = content:match('"last_swap"%s*:%s*"([^"]+)"')
        if ls then last_swap = '"' .. ls .. '"' end
    end
    checks = checks + 1
    if swap_needed then
        swapped = swapped + 1
        last_swap = '"' .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. '"'
    end
    local out = io.open(MAME_STATS_FILE, "w")
    if out then
        out:write(string.format('{"checks":%d,"swaps":%d,"last_swap":%s}\n', checks, swapped, last_swap))
        out:close()
    end
end

-----------------------------------------------------------
-- Plugin State (survives soft_reset within a session)
-----------------------------------------------------------

local swap_done      = false   -- true once we've made a decision this session
local swap_applied   = false   -- true if we swapped; used to show post-reset message and restore cfg
local reset_notifier = nil     -- held to prevent garbage collection
local stop_notifier  = nil     -- held to prevent garbage collection

-----------------------------------------------------------
-- Input Detection
-----------------------------------------------------------

-- Logs all joystick devices with their JOYCODE index, name, button count,
-- and a player/role label where determinable.
local function log_all_joystick_devices()
    local input = manager.machine.input
    local joyclass = nil
    for _, cls in pairs(input.device_classes) do
        if cls.name == "joystick" then joyclass = cls; break end
    end
    if not joyclass then
        print("[LuaSwap] log_all_joystick_devices: joystick class not available")
        return
    end

    -- Collect and sort by devindex for deterministic output
    local all = {}
    for _, device in pairs(joyclass.devices) do
        local btn_count = 0
        for _, item in pairs(device.items) do
            if tostring(item.token):match("^BUTTON%d") then
                btn_count = btn_count + 1
            end
        end
        table.insert(all, { devindex = device.devindex, name = device.name, buttons = btn_count })
    end
    table.sort(all, function(a, b) return a.devindex < b.devindex end)

    -- Per-family first-seen counters for labelling
    local xinmo_seen  = 0
    local huijia_seen = 0

    print("[LuaSwap] --- Joystick device enumeration ---")
    for _, d in ipairs(all) do
        local joycode = "JOYCODE_" .. (d.devindex + 1) .. "_"
        local lname   = d.name:lower()
        local label   = ""

        if lname:find("xin") then
            xinmo_seen = xinmo_seen + 1
            if d.buttons == EXPECTED_P1_BTNS then
                label = "XinMo P1"
            elseif d.buttons == EXPECTED_P2_BTNS then
                label = "XinMo P2"
            else
                label = "XinMo? (unexpected btn count)"
            end
        elseif lname:find("huijia") or lname:find("hui") then
            huijia_seen = huijia_seen + 1
            label = huijia_seen == 1 and "HuiJia P1" or "HuiJia P" .. huijia_seen
        end

        print(string.format("[LuaSwap]  %s  id=%-3d  btns=%-3d  '%s'%s",
            joycode, d.devindex, d.buttons, d.name,
            label ~= "" and ("  [" .. label .. "]") or ""))
    end
    print("[LuaSwap] --- end enumeration ---")
end

-- Returns sorted list of XinMo devices as MAME enumerates them.
-- Each entry: { devindex, joycode_prefix, name, buttons }
local function find_xinmo_devices()
    local input = manager.machine.input

    local joyclass = nil
    for _, cls in pairs(input.device_classes) do
        if cls.name == "joystick" then
            joyclass = cls
            break
        end
    end

    if not joyclass then
        print("[LuaSwap] ERROR: joystick device class not available")
        return nil, nil
    end

    local found = {}
    for _, device in pairs(joyclass.devices) do
        if device.name:lower():find("xin") then
            local btn_count = 0
            for _, item in pairs(device.items) do
                if tostring(item.token):match("^BUTTON%d") then
                    btn_count = btn_count + 1
                end
            end
            table.insert(found, {
                devindex       = device.devindex,
                joycode_prefix = "JOYCODE_" .. (device.devindex + 1) .. "_",
                name           = device.name,
                buttons        = btn_count,
            })
        end
    end

    -- Sort by MAME's enumeration order so [1] = first JOYCODE, [2] = second
    table.sort(found, function(a, b) return a.devindex < b.devindex end)
    return found
end

-- Returns true  = hw is swapped  (swap cfg to compensate)
--         false = hw is normal   (no action needed)
--         nil   = inconclusive (fewer than 2 devices or unexpected button counts)
local function check_swap_needed()
    log_all_joystick_devices()
    local devs = find_xinmo_devices()

    if not devs or #devs < 2 then
        print("[LuaSwap] Cannot determine swap state: fewer than 2 XinMo devices found")
        return nil, nil
    end

    for _, d in ipairs(devs) do
        print(string.format("[LuaSwap] %s -> '%s' -- %d buttons",
              d.joycode_prefix, d.name, d.buttons))
    end

    if devs[1].buttons == EXPECTED_P1_BTNS and devs[2].buttons == EXPECTED_P2_BTNS then
        print("[LuaSwap] HW order: Normal (P1 first)")
        return false, devs
    elseif devs[1].buttons == EXPECTED_P2_BTNS and devs[2].buttons == EXPECTED_P1_BTNS then
        print("[LuaSwap] HW order: SWAPPED (P2 enumerated first)")
        return true, devs
    else
        print(string.format("[LuaSwap] Inconclusive button counts: %d / %d",
              devs[1].buttons, devs[2].buttons))
        return nil, nil
    end
end


-----------------------------------------------------------
-- Game Stop: restore cfg from repo only if a swap was applied
-----------------------------------------------------------

local function on_game_stop()
    if not swap_applied then
        print("[LuaSwap] No swap was applied; skipping cfg restore")
        return
    end
    print("[LuaSwap] Restoring cfg from repo on game stop (swap was applied)")
    os.execute(string.format("cp -f '%s/cfg'/*.cfg '%s/cfg/' 2>/dev/null",
        REPO_CFG, MAME_BASE))
end

-----------------------------------------------------------
-- Plugin Entry Point
-----------------------------------------------------------

function xinmo.startplugin()

    reset_notifier = emu.add_machine_reset_notifier(function()

        -- Post-reset: show confirmation that the fix took effect
        if swap_done then
            if swap_applied then
                manager.machine:popmessage("XinMo p1-P2 fixed")
            end
            return
        end

        -- First start: detect MAME's input order vs cfg state
        local needs_swap, xinmo_devs = check_swap_needed()
        swap_done = true

        if needs_swap ~= nil then
            update_mame_stats(needs_swap)
        end

        if needs_swap == nil then
            return
        end

        if needs_swap then
            manager.machine:popmessage("XinMo Swap: restart...")
            -- Pass actual joycode prefixes so the script can remap correctly
            -- regardless of which JOYCODE slots the hardware landed on
            local cmd = string.format("%s '%s' '%s'",
                SWAP_SCRIPT,
                xinmo_devs[1].joycode_prefix,
                xinmo_devs[2].joycode_prefix)
            os.execute(cmd)
            swap_applied = true
            manager.machine:soft_reset()
        end

    end)

    stop_notifier = emu.add_machine_stop_notifier(on_game_stop)
end

return exports
