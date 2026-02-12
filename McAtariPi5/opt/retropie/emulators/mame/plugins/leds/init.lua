local VERSION = "1.3.2"

local exports = {
    name = "leds",
    version = VERSION,
    description = "LED control plugin",
    license = "MIT",
    author = { name = "DanC ChatGPT" }
}

local leds = exports

-----------------------------------------------------------
-- Constants
-----------------------------------------------------------

local SCRIPT_PATH = "/home/danc/scripts/"
local SCRIPT_FILE = "set_leds.py"

-----------------------------------------------------------
-- Internal State
-----------------------------------------------------------

local last_mask = -1
local reset_subscriber
local stop_subscriber
local frame_subscriber
local machine_ok = true
local attract_on = true    -- coin1 flashes in attract mode

local coins1 = nil
local start1 = nil
local start2 = nil
local player_buttons = {}  -- Table to hold player button references
local credits = 0

local last_coins1 = 0
local last_start1 = 0
local last_start2 = 0

-- Attract mode and LED flashing
local ATTRACT_MODE_TIMEOUT = 60.0  -- Return to attract mode after 1 minute of inactivity
local COIN_FLASH_INTERVAL = 0.5    -- Flash coin LED every 0.5 seconds
local last_button_press_time = 0

-----------------------------------------------------------
-- Helper Functions
-----------------------------------------------------------

local function set_led_mask(mask)
    if mask == last_mask then return end
    last_mask = mask

    local cmd = string.format("python3 %s%s %02x &", SCRIPT_PATH, SCRIPT_FILE, mask)
    local result = os.execute(cmd)
--  if result then
--      print(string.format("LED mask 0x%02x sent successfully.", mask))
--  else
--      print(string.format("Failed to send LED mask 0x%02x.", mask))
--  end
end

local function match_field_name(name, substr1, substr2)
    local lname = name:lower()
    return lname:find(substr1) and lname:find(substr2)
end

local function initialize_ports()
    local ioports = manager.machine.ioport.ports

    for tag, port in pairs(ioports) do
        for field_name, field in pairs(port.fields) do
            if not coins1 and match_field_name(field_name, "coin", "1") then
                print("coin 1 found")
                coins1 = { port = port, field = field }
            elseif not start1 and match_field_name(field_name, "start", "1") then
                print("start 1 found")
                start1 = { port = port, field = field }
            elseif not start2 and match_field_name(field_name, "start", "2") then
                print("start 2 found")
                start2 = { port = port, field = field }
            end
            -- Collect player button fields (P1_BUTTON1, P1_BUTTON2, etc.)
            if field_name:lower():find("p1_button") or field_name:lower():find("button") then
                table.insert(player_buttons, { port = port, field = field, name = field_name })
            end
        end
    end

    if not (coins1 and start1 and start2) then
        print("LEDS Plugin: Failed to find all required input ports.")
        print("LEDS Plugin: Available input ports:")
        local ioports = manager.machine.ioport.ports
        for tag, port in pairs(ioports) do
            for field_name, field in pairs(port.fields) do
                print("  - " .. field_name)
            end
        end
    end

    if coins1 then last_coins1 = coins1.port:read() end
    if start1 then last_start1 = start1.port:read() end
    if start2 then last_start2 = start2.port:read() end
end

local function is_pressed(current, field)
    return ((current & field.mask) ~ field.defvalue) ~= 0
end

local function cleanup_notifiers()
    if reset_subscriber then emu.remove_notifier(reset_subscriber) end
    if stop_subscriber then emu.remove_notifier(stop_subscriber) end
    if frame_subscriber then emu.remove_notifier(frame_subscriber) end

    reset_subscriber = nil
    stop_subscriber = nil
    frame_subscriber = nil
end

-----------------------------------------------------------
-- Event Callbacks
-----------------------------------------------------------

local function on_frame()

    if not machine_ok then return end

    local c1_now, s1_now, s2_now
    local c1_down, s1_down, s2_down
    local c1_edge, s1_edge, s2_edge

    if coins1 then
        c1_now = coins1.port:read()
        c1_down = is_pressed(c1_now, coins1.field)
        c1_edge = c1_down and c1_now ~= last_coins1
        if c1_edge then
            credits = credits + 1
            print("LEDS Plugin: Coin inserted. Credits: " .. credits)
        end 
    end

    if start1 then
        s1_now = start1.port:read()
        s1_down = is_pressed(s1_now, start1.field)
        s1_edge = s1_down and s1_now ~= last_start1
    end

    if start2 then
        s2_now = start2.port:read()
        s2_down = is_pressed(s2_now, start2.field)
        s2_edge = s2_down and s2_now ~= last_start2
    end

    local current_time = os.clock()
        
    -- Track player button activity for attract mode
    local any_player_button_pressed = false
    for _, button_ref in ipairs(player_buttons) do
        local button_now = button_ref.port:read()
        if is_pressed(button_now, button_ref.field) then
            any_player_button_pressed = true
            break
        end
    end
    
    -- Update last button press time only when player buttons are active
    if any_player_button_pressed then
        last_button_press_time = current_time
        attract_on = false
    end
    
    -- Return to attract mode after player inactivity timeout
    if (current_time - last_button_press_time) > ATTRACT_MODE_TIMEOUT then
        attract_on = true
    end

    -- Start 1 now
    if s1_edge and credits >= 1 then
        credits = credits - 1
        attract_on = false
        print("LEDS Plugin: 1 Player start. Credits: " .. credits)
    end

    -- Start 2 now
    if s2_edge and credits >= 2 then
        credits = credits - 2
        print("LEDS Plugin: 2 Player start. Credits: " .. credits)
        attract_on = false
    end

    last_coins1 = c1_now
    last_start1 = s1_now
    last_start2 = s2_now

    -- Update LED mask based on credits
    local mask_now = 0  -- Default to all LEDs off

    if attract_on then
        -- Flash coin LED every 0.5 seconds in attract mode
        local flash_phase = (current_time % COIN_FLASH_INTERVAL) < (COIN_FLASH_INTERVAL / 2)
        if flash_phase then
            mask_now = 1      -- + Coin
        end
    end

    -- Update Player Start LEDs based on credits
    if credits >= 2 then
        mask_now = mask_now + 6     -- + P1 + P2
    elseif credits == 1 then
        mask_now = mask_now + 2     -- + P1
    end

    set_led_mask(mask_now)
end

local function on_game_start()
    machine_ok = false
    coins1 = nil
    start1 = nil
    start2 = nil
    player_buttons = {}
    last_coins1 = 0
    last_start1 = 0
    last_start2 = 0
    credits = 0
    last_button_press_time = 0
    
    local gamename = emu.romname()
    if gamename == "___empty" then return end

    print("LEDS Plugin: " .. gamename .. " started")

    initialize_ports()

    machine_ok = true
    attract_on = true
end

local function on_game_stop()
    print("LEDS Plugin: Game stopped, turning off all LEDs")
    set_led_mask(0x00)
    machine_ok = false
end

-----------------------------------------------------------
-- Plugin Entry Point
-----------------------------------------------------------

function leds.startplugin()
    print("LEDS Plugin: Initialized (v" .. VERSION .. ")")
    set_led_mask(0x00)

    cleanup_notifiers()
    reset_subscriber = emu.add_machine_reset_notifier(on_game_start)
    stop_subscriber = emu.add_machine_stop_notifier(on_game_stop)
    frame_subscriber = emu.add_machine_frame_notifier(on_frame)
end

return exports
