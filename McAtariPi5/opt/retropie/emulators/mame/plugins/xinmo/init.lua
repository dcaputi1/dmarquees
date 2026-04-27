-----------------------------------------------------------
-- Xin-Mo PxSwap Plugin
-- Detects P1/P2 controller swap via MAME's input driver
-- and corrects cfg files + soft-resets if needed.
-----------------------------------------------------------

local VERSION = "0.1.0"

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

local SWAP_SCRIPT_RA = "python3 /home/danc/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg_ra toggle"
local SWAP_SCRIPT_SA = "python3 /home/danc/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg_sa toggle"

-----------------------------------------------------------
-- Plugin State (survives soft_reset within a session)
-----------------------------------------------------------

local pxswap_done    = false   -- true once we've made a decision this session
local pxswap_applied = false   -- true if we swapped; used to show post-reset message
local start_notifier = nil     -- held to prevent garbage collection

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

-- Returns true  = swap needed
--         false = order is correct
--         nil   = inconclusive
local function mame_sees_swap_needed()
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
        print("[PxSwap] MAME order: Normal (P1 first)")
        return false
    elseif devs[1].buttons == EXPECTED_P2_BTNS and devs[2].buttons == EXPECTED_P1_BTNS then
        print("[PxSwap] MAME order: SWAPPED (P2 enumerated first)")
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

    start_notifier = emu.add_machine_start_notifier(function()

        -- Post-reset: show confirmation that the fix took effect
        if pxswap_done then
            if pxswap_applied then
                manager.machine:popmessage(
                    "*** XinMo PxSwap: Controllers corrected! P1=P1, P2=P2 ***")
                pxswap_applied = false
            end
            return
        end

        -- First start: detect MAME's input order
        local needs_swap = mame_sees_swap_needed()
        pxswap_done = true

        if needs_swap == nil then
            manager.machine:popmessage(
                "[PxSwap] WARNING: Could not determine XinMo controller order!")
            return
        end

        if needs_swap then
            manager.machine:popmessage(
                "*** XinMo PxSwap: Swap DETECTED -- fixing cfg and restarting... ***")
            os.execute(SWAP_SCRIPT_RA)
            os.execute(SWAP_SCRIPT_SA)
            pxswap_applied = true
            manager.machine:soft_reset()
        else
            manager.machine:popmessage("[PxSwap] XinMo order OK")
        end

    end)

end

return exports
