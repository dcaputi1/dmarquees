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

	local function trim(s)
		return (s:gsub("^%s+", ""):gsub("%s+$", ""))
	end

	local function filter_ignored_joystick_from_seq(seq)
		if seq == nil then
			return nil
		end

		local ok_tokens, tokens = pcall(function()
			return input:seq_to_tokens(seq)
		end)
		if (not ok_tokens) or tokens == nil or tokens == "" then
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
			return emu.input_seq()
		end

		local filtered_tokens = table.concat(kept_terms, " OR ")
		local ok_seq, filtered_seq = pcall(function()
			return input:seq_from_tokens(filtered_tokens)
		end)
		if ok_seq and filtered_seq ~= nil then
			return filtered_seq
		end

		return seq
	end

	local function process_frame()
		if input ~= nil then
			if input:seq_pressed(button_left) then
				-- You can observe the current facing at address 0xA0BD.
				-- Originally I tried tracking that address and then triggering
				-- the Reverse input when the player was facing the wrong way.
				-- I don't understand why, but enabling the Reverse input would
				-- not reliably change the ship's direction, so I had to revert
				-- to oomek's solution of writing directly to memory.
				-- (10yard - The facing address for Stargate is 0x9C92)
				memory:write_u8(facing_address, FACING_LEFT)
				thrust:set_value(1)
			elseif input:seq_pressed(button_right) then
				memory:write_u8(facing_address, FACING_RIGHT)
				thrust:set_value(1)
			else
				thrust:set_value(0)
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
		if frame_subscription ~= nil then
			frame_subscription:unsubscribe()
		end
		--reset_subscription:unsubscribe()
		--stop_subscription:unsubscribe()
	end

	local function init_plugin()
		if emu.romname() == "defender" or emu.romname() == "stargate" then
			if emu.romname() == "stargate" then
				facing_address = 0x9C92
			else
				facing_address = 0xA0BB
			end
			if emu.app_version() >= "0.254" then
				input = manager.machine.input
				ioport = manager.machine.ioport
				memory = manager.machine.devices[':maincpu'].spaces['program']
				thrust = ioport.ports[':IN0'].fields['Thrust']
				button_left = ioport:type_seq(IPT_JOYSTICK_LEFT, nil, nil)
				button_right = ioport:type_seq(IPT_JOYSTICK_RIGHT, nil, nil)
				button_left = filter_ignored_joystick_from_seq(button_left)
				button_right = filter_ignored_joystick_from_seq(button_right)
				frame_subscription = emu.add_machine_frame_notifier(process_frame)
			else
				print("ERROR: The 'defenderlr' plugin requires MAME version 0.254 or greater.")			
			end
		else
			cleanup()
		end
	end
	reset_subscription = emu.add_machine_reset_notifier(init_plugin)
	stop_subscription = emu.add_machine_stop_notifier(cleanup)
end

return exports
