-----------------------------------------------------------
-- Marquee Plugin - Sends FIFO commands to dmarquees daemon
-----------------------------------------------------------

local VERSION = "1.3.3"

local exports = {
    name = "marquee",
    version = VERSION,
    description = "Marquee display plugin",
    license = "MIT",
    author = { name = "DanC ChatGPT" }
}

local marquee = exports
local input = nil

-----------------------------------------------------------
-- Constants
-----------------------------------------------------------

local MARQUEE_FIFO = "/tmp/dmarquees_cmd"
local SENDER_SCRIPT = "/home/danc/scripts/dmarquees-send.sh"
local SWAP_SCRIPT  = "/home/danc/scripts/swap_banner_art.sh"

-----------------------------------------------------------
-- Internal State
-----------------------------------------------------------

local reset_subscriber
local stop_subscriber
local dc_panel_visible = false
local mc_panel_visible = false

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

local function shell_quote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function send_marquee_command(text)
    local sender = io.open(SENDER_SCRIPT, "r")
    if sender then
        sender:close()
        local status = os.execute(string.format("%s %s >/dev/null 2>&1", SENDER_SCRIPT, shell_quote(text)))
        if status == true or status == 0 then
            print(string.format("Marquee plugin: Routed marquee command via sender: '%s'", text))
            return
        end
        print(string.format("Marquee plugin: Sender failed, falling back to FIFO for '%s'", text))
    end

    local fifo = io.open(MARQUEE_FIFO, "w")
    if fifo then
        fifo:write(text .. "\n")
        fifo:close()
        print(string.format("Marquee plugin: Sent marquee command to FIFO: '%s'", text))
    else
        print(string.format("Marquee plugin: Failed to route command '%s' via sender or FIFO %s", text, MARQUEE_FIFO))
    end
end

local function current_romname()
    local gamename = emu.romname()
    if gamename and gamename ~= "" and gamename ~= "___empty" then
        return gamename
    end
    return nil
end

local function sync_rom_for_panel()
    local gamename = current_romname()
    if not gamename then
        print("Marquee plugin: No active ROM to sync for panel")
        return false
    end

    -- Use RC: prefix so the daemon accepts this sync in all frontend modes
    -- (plain romname is ignored by the daemon when in RA mode).
    send_marquee_command("RC:" .. gamename)
    return true
end

local function cleanup_notifiers()
    if reset_subscriber then emu.remove_notifier(reset_subscriber) end
    if stop_subscriber then emu.remove_notifier(stop_subscriber) end
    reset_subscriber, stop_subscriber = nil, nil
end

-----------------------------------------------------------
-- Event Callbacks
-----------------------------------------------------------

local function on_game_start()
    local gamename = current_romname()
    if not gamename then return end

    dc_panel_visible = false
    mc_panel_visible = false
    print("Marquee plugin: " .. gamename .. " started")
    send_marquee_command("RC:" .. gamename)  -- RC: prefix accepted in all daemon frontend modes
end

local function on_game_stop()
    dc_panel_visible = false
    mc_panel_visible = false
    print("Marquee plugin: Game stopped, reset marquee")
    send_marquee_command("CLEAR")
end

local function menu_populate()
    return {
        { "Control Panel / Marquee", "SWAP", "" },
        { "DC Panel 1", dc_panel_visible and "hide" or "show", "" },
        { "MC Atari Panel", mc_panel_visible and "hide" or "show", "" }
    }
end

local function menu_callback(index, event)
    if event ~= "select" then
        return false
    end

    if index == 1 then
        os.execute(SWAP_SCRIPT)
        print("Marquee plugin: SWAP index " .. tostring(index) .. " event " .. tostring(event))
        return false
    elseif index == 2 then
        dc_panel_visible = not dc_panel_visible
        if dc_panel_visible then
            if mc_panel_visible then
                mc_panel_visible = false
                send_marquee_command("MCPANEL 0")
            end
            sync_rom_for_panel()
            send_marquee_command("DCPANEL 1")
        else
            send_marquee_command("DCPANEL 0")
        end
        print("Marquee plugin: DC panel " .. (dc_panel_visible and "shown" or "hidden"))
        return true
    elseif index == 3 then
        mc_panel_visible = not mc_panel_visible
        if mc_panel_visible then
            if dc_panel_visible then
                dc_panel_visible = false
                send_marquee_command("DCPANEL 0")
            end
            sync_rom_for_panel()
            send_marquee_command("MCPANEL 1")
        else
            send_marquee_command("MCPANEL 0")
        end
        print("Marquee plugin: MC panel " .. (mc_panel_visible and "shown" or "hidden"))
        return true
    end

    return false
end

-----------------------------------------------------------
-- Plugin Entry Point
-----------------------------------------------------------

function marquee.startplugin()
    print("Marquee Plugin: Initialized (v" .. VERSION .. ")")

    cleanup_notifiers()
    reset_subscriber = emu.add_machine_reset_notifier(on_game_start)
    stop_subscriber = emu.add_machine_stop_notifier(on_game_stop)
	emu.register_menu(menu_callback, menu_populate, "Marquee")

end

return exports
