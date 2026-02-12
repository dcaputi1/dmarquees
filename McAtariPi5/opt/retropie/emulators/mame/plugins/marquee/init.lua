-----------------------------------------------------------
-- Marquee Plugin - Sends FIFO commands to dmarquees daemon
-----------------------------------------------------------

local VERSION = "1.3.2"

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
local SWAP_SCRIPT  = "/home/danc/scripts/swap_banner_art.sh"

-----------------------------------------------------------
-- Internal State
-----------------------------------------------------------

local reset_subscriber
local stop_subscriber

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

local function send_marquee_command(text)
    local f = io.open(MARQUEE_FIFO, "w")
    if f then
        f:write(text .. "\n")
        f:close()
        print(string.format("Marquee plugin: Sent marquee command: '%s'", text))
    else
        print(string.format("Marquee plugin: Failed to open FIFO %s", MARQUEE_FIFO))
    end
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
    local gamename = emu.romname()
    if gamename == "___empty" then return end

    print("Marquee plugin: " .. gamename .. " started")
    send_marquee_command(gamename)  -- show corresponding marquee
end

local function on_game_stop()
    print("Marquee plugin: Game stopped, reset marquee")
    send_marquee_command("CLEAR")
end

local function menu_populate()
    return {{ "Control Panel / Marquee", "SWAP", "" }}
end

local function menu_callback(index, event)
    if index == 1 and event == "select" then
        os.execute(SWAP_SCRIPT)
        print("Marquee plugin: SWAP index " .. tostring(index) .. " event " .. tostring(event)  )
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
