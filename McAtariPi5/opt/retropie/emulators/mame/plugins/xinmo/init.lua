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

local CFG_ACTIVE         = "/opt/retropie/emulators/mame/cfg/default.cfg"
local CFG_P2_NORMAL     = "JOYCODE_3_"   -- P2_BUTTON1 text when cfg is NOT swapped
local CFG_P2_SWAPPED    = "JOYCODE_2_"   -- P2_BUTTON1 text when cfg IS swapped

-- At plugin runtime cfg_ra/cfg_sa has already been renamed to cfg/ by the launch
-- wrapper, so we only need to swap the one active directory.
local SWAP_SCRIPT = "python3 /home/danc/scripts/xinmo-swap.py /opt/retropie/emulators/mame/cfg toggle"

-- Written by this plugin when it performs a swap; cleared by xinmo-swap.py (menu path).
-- Allows xinmo-swapcheck.py to distinguish "plugin swap" from "menu swap".
local PLUGIN_SWAP_FLAG  = (os.getenv("HOME") or "/home/danc") .. "/.xinmo_plugin_swapped"

-----------------------------------------------------------
-- Plugin State (survives soft_reset within a session)
-----------------------------------------------------------

local pxswap_done    = false   -- true once we've made a decision this session
local pxswap_applied = false   -- true if we swapped; used to show post-reset message
local start_notifier = nil     -- held to prevent garbage collection

-----------------------------------------------------------
-- Cfg State Detection
-----------------------------------------------------------

-- Returns true  = cfg has been swapped  (P2_BUTTON1 uses JOYCODE_2_)
--         false = cfg is normal          (P2_BUTTON1 uses JOYCODE_3_)
--         nil   = file missing or P2_BUTTON1 not found
local function read_cfg_swapped()
    local f = io.open(CFG_ACTIVE, "r")
    if not f then
        print("[PxSwap] WARN: " .. CFG_ACTIVE .. " not found -- cfg state unknown")
        return nil
    end
    local content = f:read("*a")
    f:close()

    -- Find the P2_BUTTON1 port block and check which JOYCODE it contains
    local p2_block = content:match('<port[^>]+type="P2_BUTTON1"[^>]*>(.-)</port>')
    if not p2_block then
        print("[PxSwap] WARN: P2_BUTTON1 entry not found in default.cfg")
        return nil
    end

    if p2_block:find(CFG_P2_SWAPPED, 1, true) then
        return true
    elseif p2_block:find(CFG_P2_NORMAL, 1, true) then
        return false
    end

    print("[PxSwap] WARN: Could not determine cfg state from P2_BUTTON1 block")
    return nil
end

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

-- Returns true  = swap needed   (hw and cfg are mismatched)
--         false = all correct   (hw normal+cfg normal, OR hw swapped+cfg compensates)
--         nil   = inconclusive
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

    local hw_swapped
    if devs[1].buttons == EXPECTED_P1_BTNS and devs[2].buttons == EXPECTED_P2_BTNS then
        hw_swapped = false
        print("[PxSwap] HW order: Normal (P1 first)")
    elseif devs[1].buttons == EXPECTED_P2_BTNS and devs[2].buttons == EXPECTED_P1_BTNS then
        hw_swapped = true
        print("[PxSwap] HW order: SWAPPED (P2 enumerated first)")
    else
        print(string.format("[PxSwap] Inconclusive button counts: %d / %d",
              devs[1].buttons, devs[2].buttons))
        return nil
    end

    local cfg_swapped = read_cfg_swapped()
    if cfg_swapped == nil then
        -- Can't read cfg: fall back to hardware-only decision
        print("[PxSwap] WARN: Falling back to hardware-only check")
        return hw_swapped
    end

    print(string.format("[PxSwap] CFG state: %s", cfg_swapped and "Swapped" or "Normal"))

    -- Mismatch means players are getting wrong inputs
    if hw_swapped ~= cfg_swapped then
        return true
    end
    return false
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

        -- First start: detect MAME's input order vs cfg state
        local needs_swap = check_swap_needed()
        pxswap_done = true

        if needs_swap == nil then
            manager.machine:popmessage(
                "[PxSwap] WARNING: Could not determine XinMo controller order!")
            return
        end

        if needs_swap then
            manager.machine:popmessage(
                "*** XinMo PxSwap: Swap DETECTED -- fixing cfg and restarting... ***")
            os.execute(SWAP_SCRIPT)
            -- Write flag so xinmo-swapcheck.py can report "plugin swap" vs "menu swap"
            local flag = io.open(PLUGIN_SWAP_FLAG, "w")
            if flag then flag:write("1\n") flag:close() end
            pxswap_applied = true
            manager.machine:soft_reset()
        else
            manager.machine:popmessage("[PxSwap] XinMo order OK")
        end

    end)

end

return exports
