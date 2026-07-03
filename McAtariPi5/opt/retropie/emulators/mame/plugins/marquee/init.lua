-----------------------------------------------------------
-- Marquee Plugin - Sends FIFO commands to dmarquees daemon
-----------------------------------------------------------

local VERSION = "1.3.4"

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
local PANEL_FILE   = "/home/danc/.panel"

local PANEL_OFF = "OFF"
local PANEL_DC = "DC"
local PANEL_MC = "MC"
local PANEL_MK = "MK"
local PANEL_CYCLE = { PANEL_OFF, PANEL_DC, PANEL_MC, PANEL_MK }

-----------------------------------------------------------
-- Internal State
-----------------------------------------------------------

local reset_subscriber
local stop_subscriber
local panel_mode = PANEL_OFF

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

local function shell_quote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function send_marquee_command(text)
    -- Send to Pi3 via sender script (for marquee display)
    local sender = io.open(SENDER_SCRIPT, "r")
    if sender then
        sender:close()
        local status = os.execute(string.format("%s %s >/dev/null 2>&1", SENDER_SCRIPT, shell_quote(text)))
        if status == true or status == 0 then
            print(string.format("Marquee plugin: Sent to Pi3 via sender: '%s'", text))
        else
            print(string.format("Marquee plugin: Sender failed for '%s'", text))
        end
    end

    -- Always also write to local FIFO so Pi5 dmarquees can show panel art
    local fifo = io.open(MARQUEE_FIFO, "w")
    if fifo then
        fifo:write(text .. "\n")
        fifo:close()
        print(string.format("Marquee plugin: Sent to local FIFO: '%s'", text))
    else
        print(string.format("Marquee plugin: Failed to write to local FIFO %s for '%s'", MARQUEE_FIFO, text))
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

    send_marquee_command(gamename)
    return true
end

local function cleanup_notifiers()
    if reset_subscriber then emu.remove_notifier(reset_subscriber) end
    if stop_subscriber then emu.remove_notifier(stop_subscriber) end
    reset_subscriber, stop_subscriber = nil, nil
end

local function panel_mode_label(mode)
    if mode == PANEL_DC then
        return "DC Panel 1"
    elseif mode == PANEL_MC then
        return "MC Atari"
    elseif mode == PANEL_MK then
        return "MK Wheel"
    end
    return "OFF"
end

local function panel_mode_file_code(mode)
    if mode == PANEL_DC then
        return "DC"
    elseif mode == PANEL_MC then
        return "MC"
    elseif mode == PANEL_MK then
        return "MK"
    end
    return "NA"
end

local function persist_panel_mode(mode)
    local file = io.open(PANEL_FILE, "w")
    if not file then
        print(string.format("Marquee plugin: Failed to persist panel mode to %s", PANEL_FILE))
        return false
    end

    file:write(panel_mode_file_code(mode) .. "\n")
    file:close()
    return true
end

local function next_panel_mode(mode)
    for i = 1, #PANEL_CYCLE do
        if PANEL_CYCLE[i] == mode then
            return PANEL_CYCLE[(i % #PANEL_CYCLE) + 1]
        end
    end
    return PANEL_OFF
end

local function apply_panel_mode(mode)
    -- Always clear panel flags first so only one panel type can be active.
    send_marquee_command("DCPANEL 0")
    send_marquee_command("MCPANEL 0")
    send_marquee_command("MKWHEEL 0")

    if mode == PANEL_DC then
        sync_rom_for_panel()
        send_marquee_command("DCPANEL 1")
    elseif mode == PANEL_MC then
        sync_rom_for_panel()
        send_marquee_command("MCPANEL 1")
    elseif mode == PANEL_MK then
        sync_rom_for_panel()
        send_marquee_command("MKWHEEL 1")
    else
        mode = PANEL_OFF
    end

    panel_mode = mode
    persist_panel_mode(panel_mode)
    print("Marquee plugin: Panel mode set to " .. panel_mode_label(panel_mode))
end

-----------------------------------------------------------
-- Event Callbacks
-----------------------------------------------------------

local function on_game_start()
    local gamename = current_romname()
    if not gamename then return end

    apply_panel_mode(PANEL_OFF)
    print("Marquee plugin: " .. gamename .. " started")
    send_marquee_command(gamename)
end

local function on_game_stop()
    apply_panel_mode(PANEL_OFF)
    print("Marquee plugin: Game stopped, reset marquee")
    send_marquee_command("CLEAR")
end

local function menu_populate()
    return {
        { "Control Panel / Marquee", "SWAP", "" },
        { "Spare Monitor Panel", panel_mode_label(panel_mode), "" }
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
        apply_panel_mode(next_panel_mode(panel_mode))
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
