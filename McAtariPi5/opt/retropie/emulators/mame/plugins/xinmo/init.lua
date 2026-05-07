-----------------------------------------------------------
-- Xin-Mo PxSwap Plugin
-- Detects P1/P2 controller swap via MAME's input driver
-- and corrects cfg files + soft-resets if needed.
-----------------------------------------------------------

local VERSION = "0.2.0"

local exports = {
    name        = "xinmo",
    version     = VERSION,
    description = "Xin-Mo PxSwap",
    license     = "MIT",
    author      = { name = "Dan Caputi" }
}

local xinmo = exports

-----------------------------------------------------------
-- Constants
-----------------------------------------------------------

local EXPECTED_P1_BTNS = 15   -- first XinMo device (JOYCODE_N_) should have 15 buttons
local EXPECTED_P2_BTNS = 13   -- second XinMo device should have 13 buttons

-- At plugin runtime cfg_ra/cfg_sa has already been renamed to cfg/ by the launch
-- wrapper, so we only need to swap the one active directory.
-- Pass '1' (hw-swapped) so xinmo-swap.py reads default.cfg itself and applies
-- XOR logic — same contract as the menu button and autostart.sh.
local SWAP_SCRIPT = "python3 /home/danc/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg 1"

-- Written by this plugin when it performs a swap; cleared by xinmo-swap.py (menu path).
-- Allows xinmo-swapcheck.py to distinguish "plugin swap" from "menu swap".
local PLUGIN_SWAP_FLAG  = (os.getenv("HOME") or "/home/danc") .. "/.xinmo_plugin_swapped"

-- Persistent stats file tracking MAME-level swap detection history.
local MAME_STATS_FILE = (os.getenv("HOME") or "/home/danc") .. "/IvarArcade/json/xinmo_mame_stats.json"

-----------------------------------------------------------
-- Stats Tracking
-----------------------------------------------------------

local function update_mame_stats(swap_needed)
    local checks = 0
    local swapped = 0
    local f = io.open(MAME_STATS_FILE, "r")
    if f then
        local content = f:read("*a")
        f:close()
        checks  = tonumber(content:match('"checks"%s*:%s*(%d+)'))      or 0
        swapped = tonumber(content:match('"swap_needed"%s*:%s*(%d+)')) or 0
    end
    checks = checks + 1
    if swap_needed then swapped = swapped + 1 end
    local out = io.open(MAME_STATS_FILE, "w")
    if out then
        out:write(string.format('{"checks":%d,"swap_needed":%d}\n', checks, swapped))
        out:close()
    end
end

-----------------------------------------------------------
-- Plugin State (survives soft_reset within a session)
-----------------------------------------------------------

local pxswap_done    = false   -- true once we've made a decision this session
local pxswap_applied = false   -- true if we swapped; used to show post-reset message
local reset_notifier = nil     -- held to prevent garbage collection

-----------------------------------------------------------
-- Input Detection
-----------------------------------------------------------

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
        print("[PxSwap] ERROR: joystick device class not available")
        return nil
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

-- Returns true  = hw is swapped  (xinmo-swap.py will XOR against cfg and act if needed)
--         false = hw is normal   (xinmo-swap.py will XOR against cfg and no-op if already normal)
--         nil   = inconclusive (fewer than 2 devices or unexpected button counts)
local function check_swap_needed()
    local devs = find_xinmo_devices()

    if not devs or #devs < 2 then
        print("[PxSwap] Cannot determine swap state: fewer than 2 XinMo devices found")
        return nil
    end

    for _, d in ipairs(devs) do
        print(string.format("[PxSwap] %s -> '%s' -- %d buttons",
              d.joycode_prefix, d.name, d.buttons))
    end

    if devs[1].buttons == EXPECTED_P1_BTNS and devs[2].buttons == EXPECTED_P2_BTNS then
        print("[PxSwap] HW order: Normal (P1 first)")
        return false
    elseif devs[1].buttons == EXPECTED_P2_BTNS and devs[2].buttons == EXPECTED_P1_BTNS then
        print("[PxSwap] HW order: SWAPPED (P2 enumerated first)")
        return true
    else
        print(string.format("[PxSwap] Inconclusive button counts: %d / %d",
              devs[1].buttons, devs[2].buttons))
        return nil
    end
end


-----------------------------------------------------------
-- Plugin Entry Point
-----------------------------------------------------------

function xinmo.startplugin()

    reset_notifier = emu.add_machine_reset_notifier(function()

        -- Post-reset: show confirmation that the fix took effect
        if pxswap_done then
            if pxswap_applied then
                manager.machine:popmessage("XinMo p1-P2 fixed")
                pxswap_applied = false
            end
            return
        end

        -- First start: detect MAME's input order vs cfg state
        local needs_swap = check_swap_needed()
        pxswap_done = true

        if needs_swap ~= nil then
            update_mame_stats(needs_swap)
        end

        if needs_swap == nil then
            return
        end

        if needs_swap then
            manager.machine:popmessage("XinMo Swap: restart...")
            os.execute(SWAP_SCRIPT)
            -- Write flag so xinmo-swapcheck.py can report "plugin swap" vs "menu swap"
            local flag = io.open(PLUGIN_SWAP_FLAG, "w")
            if flag then flag:write("1\n") flag:close() end
            pxswap_applied = true
            manager.machine:soft_reset()
        end

    end)

end

return exports
