-- license:BSD-3-Clause
-- copyright-holders:Aaron Paden
-- Original idea by Radek Dutkiewicz AKA oomek
-- http://forum.arcadecontrols.com/index.php?topic=163525.0

local exports = {}
exports.name = 'defenderlr'
exports.version = '4'
exports.description = 'Configure left-right controls for Defender (and Stargate)'
exports.license = 'The BSD 3-Clause License'
exports.author = { name = 'Aaron Paden' }

-- Ignore this physical joystick number (JOYCODE_<n>_*) for plugin L/R logic.
local IGNORED_JOYSTICK_NUMBER = 2
local IGNORED_JOYCODE_PREFIX = "JOYCODE_" .. tostring(IGNORED_JOYSTICK_NUMBER) .. "_"

local reset_subscription = nil
local stop_subscription = nil
local frame_subscription = nil

-- Set to false when diagnostics are no longer needed.
local DIAG_ENABLED = true

local function diag(fmt, ...)
	if not DIAG_ENABLED then
		return
	end
	if select('#', ...) > 0 then
		print(string.format("[defenderlr] " .. fmt, ...))
	else
		print("[defenderlr] " .. tostring(fmt))
	end
end

local defenderlr = exports
function defenderlr.startplugin()
	-- These two values can be found in the ioport_type enum
	-- found in mame at src/emu/ioport.h. They aren't yet exported
	-- into the lua API AFAIK, so you have to reference that file and
	-- count up from 0. Of course, you should delete the empty lines and
	-- comments and let your text editor count for you.
	local IPT_JOYSTICK_LEFT = 53
	local IPT_JOYSTICK_RIGHT = 54

	-- You can use MAME's built-in debugger to look for values that change
	-- after pressing an input. There's also an interactive lua console.
	-- But it's easier if someone has already done the work of reverse-engineering
	-- the game for you. A 10-second search can save you hours. In the case of Defender,
	-- there is dissassembled source on github already with helpful labels to grep through.
	local FACING_LEFT  = 0xFD
	local FACING_RIGHT = 0x03
	local facing_address = nil
	local button_left = nil
	local button_right = nil
	local input = nil
	local ioport = nil
	local memory = nil
	local thrust = nil
	local last_left_pressed = false
	local last_right_pressed = false
	local last_thrust_value = -1
	local frame_counter = 0

	local function trim(s)
		return (s:gsub("^%s+", ""):gsub("%s+$", ""))
	end

	local function parse_version(v)
		if type(v) ~= "string" then
			return nil, nil
		end
		local major, minor = string.match(v, "^(%d+)%.(%d+)")
		if major == nil or minor == nil then
			return nil, nil
		end
		return tonumber(major), tonumber(minor)
	end

	local function version_gte(lhs, rhs)
		local lhs_major, lhs_minor = parse_version(lhs)
		local rhs_major, rhs_minor = parse_version(rhs)
		if lhs_major == nil or rhs_major == nil then
			return nil
		end
		if lhs_major ~= rhs_major then
			return lhs_major > rhs_major
		end
		return lhs_minor >= rhs_minor
	end

	local function seq_to_tokens_safe(seq)
		if input == nil or seq == nil then
			return "<nil>"
		end
		local ok, tokens = pcall(function()
			return input:seq_to_tokens(seq)
		end)
		if ok and tokens ~= nil and tokens ~= "" then
			return tokens
		end
		if ok then
			return "<empty>"
		end
		return "<seq_to_tokens error>"
	end

	local function filter_ignored_joystick_from_seq(seq)
		if seq == nil then
			return nil
		end

		local ok_tokens, tokens = pcall(function()
			return input:seq_to_tokens(seq)
		end)
		if (not ok_tokens) or tokens == nil or tokens == "" then
			diag("filter_ignored_joystick_from_seq: unable to tokenize sequence; keeping original")
			return seq
		end

		local kept_terms = {}
		local start_pos = 1
		while true do
			local sep_start, sep_end = string.find(tokens, " OR ", start_pos, true)
			local term = nil
			if sep_start ~= nil then
				term = string.sub(tokens, start_pos, sep_start - 1)
				start_pos = sep_end + 1
			else
				term = string.sub(tokens, start_pos)
			end

			term = trim(term)
			if term ~= "" and not string.find(term, IGNORED_JOYCODE_PREFIX, 1, true) then
				table.insert(kept_terms, term)
			end

			if sep_start == nil then
				break
			end
		end

		if #kept_terms == 0 then
			diag("filter_ignored_joystick_from_seq: all terms filtered (ignored joystick only)")
			return emu.input_seq()
		end

		local filtered_tokens = table.concat(kept_terms, " OR ")
		local ok_seq, filtered_seq = pcall(function()
			return input:seq_from_tokens(filtered_tokens)
		end)
		if ok_seq and filtered_seq ~= nil then
			diag("filter_ignored_joystick_from_seq: '%s' => '%s'", tokens, filtered_tokens)
			return filtered_seq
		end

		diag("filter_ignored_joystick_from_seq: failed to rebuild sequence from '%s'; keeping original", filtered_tokens)

		return seq
	end

	local function process_frame()
		if input ~= nil then
			frame_counter = frame_counter + 1
			local left_pressed = input:seq_pressed(button_left)
			local right_pressed = input:seq_pressed(button_right)

			if left_pressed ~= last_left_pressed or right_pressed ~= last_right_pressed then
				local facing_value = nil
				local ok_read, read_result = pcall(function()
					return memory:read_u8(facing_address)
				end)
				if ok_read then
					facing_value = read_result
				else
					facing_value = -1
				end
				diag("input change frame=%d left=%s right=%s facing_before=0x%02X", frame_counter, tostring(left_pressed), tostring(right_pressed), facing_value)
				last_left_pressed = left_pressed
				last_right_pressed = right_pressed
			end

			if left_pressed then
				-- You can observe the current facing at address 0xA0BD.
				-- Originally I tried tracking that address and then triggering
				-- the Reverse input when the player was facing the wrong way.
				-- I don't understand why, but enabling the Reverse input would
				-- not reliably change the ship's direction, so I had to revert
				-- to oomek's solution of writing directly to memory.
				-- (10yard - The facing address for Stargate is 0x9C92)
				memory:write_u8(facing_address, FACING_LEFT)
				thrust:set_value(1)
				if last_thrust_value ~= 1 then
					diag("action frame=%d LEFT -> write facing=0x%02X thrust=1", frame_counter, FACING_LEFT)
					last_thrust_value = 1
				end
			elseif right_pressed then
				memory:write_u8(facing_address, FACING_RIGHT)
				thrust:set_value(1)
				if last_thrust_value ~= 1 then
					diag("action frame=%d RIGHT -> write facing=0x%02X thrust=1", frame_counter, FACING_RIGHT)
					last_thrust_value = 1
				end
			else
				thrust:set_value(0)
				if last_thrust_value ~= 0 then
					diag("action frame=%d idle -> thrust=0", frame_counter)
					last_thrust_value = 0
				end
			end

			if (frame_counter % 600) == 0 then
				local ok_read, facing_value = pcall(function()
					return memory:read_u8(facing_address)
				end)
				if ok_read then
					diag("heartbeat frame=%d facing=0x%02X left=%s right=%s", frame_counter, facing_value, tostring(left_pressed), tostring(right_pressed))
				else
					diag("heartbeat frame=%d facing read failed", frame_counter)
				end
			end
		end
	end
	
	local function cleanup()
		input = nil
		ioport = nil
		memory = nil
		thrust = nil
		button_left = nil
		button_right = nil
		last_left_pressed = false
		last_right_pressed = false
		last_thrust_value = -1
		frame_counter = 0
		if frame_subscription ~= nil then
			frame_subscription:unsubscribe()
			frame_subscription = nil
		end
		diag("cleanup complete")
		--reset_subscription:unsubscribe()
		--stop_subscription:unsubscribe()
	end

	local function init_plugin()
		local romname = emu.romname()
		local app_version = emu.app_version()
		diag("init_plugin rom=%s app_version=%s", tostring(romname), tostring(app_version))

		if romname == "defender" or romname == "stargate" then
			if romname == "stargate" then
				facing_address = 0x9C92
			else
				facing_address = 0xA0BB
			end
			local string_gate = (app_version >= "0.254")
			local numeric_gate = version_gte(app_version, "0.254")
			diag("version gate app=%s target=0.254 string_compare=%s numeric_compare=%s", tostring(app_version), tostring(string_gate), tostring(numeric_gate))
			if numeric_gate ~= nil and numeric_gate ~= string_gate then
				diag("WARNING: version compare mismatch (string vs numeric); plugin currently uses string gate for compatibility")
			end

			if string_gate then
				input = manager.machine.input
				ioport = manager.machine.ioport
				memory = manager.machine.devices[':maincpu'].spaces['program']
				thrust = ioport.ports[':IN0'].fields['Thrust']
				button_left = ioport:type_seq(IPT_JOYSTICK_LEFT, nil, nil)
				button_right = ioport:type_seq(IPT_JOYSTICK_RIGHT, nil, nil)
				diag("raw left seq=%s", seq_to_tokens_safe(button_left))
				diag("raw right seq=%s", seq_to_tokens_safe(button_right))
				button_left = filter_ignored_joystick_from_seq(button_left)
				button_right = filter_ignored_joystick_from_seq(button_right)
				diag("filtered left seq=%s", seq_to_tokens_safe(button_left))
				diag("filtered right seq=%s", seq_to_tokens_safe(button_right))
				diag("using facing_address=0x%04X", facing_address)
				frame_subscription = emu.add_machine_frame_notifier(process_frame)
				diag("frame notifier subscribed")
			else
				print("ERROR: The 'defenderlr' plugin requires MAME version 0.254 or greater.")			
			end
		else
			diag("rom '%s' not supported; cleaning up", tostring(romname))
			cleanup()
		end
	end
	reset_subscription = emu.add_machine_reset_notifier(init_plugin)
	stop_subscription = emu.add_machine_stop_notifier(cleanup)
end

return exports
