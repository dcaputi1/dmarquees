-- license:BSD-3-Clause
-- copyright-holders:Aaron Paden
-- Original idea by Radek Dutkiewicz AKA oomek
-- http://forum.arcadecontrols.com/index.php?topic=163525.0
--
-- 6/28/2026 D.Caputi: dynamically resolve ioport tokens (don't hardcode enum ordinals) to support MAME 0.254 and later.

local exports = {}
exports.name = 'defenderlr'
exports.version = '8'
exports.description = 'Defender/Stargate left-right thrust control'
exports.license = 'The BSD 3-Clause License'
exports.author = { name = 'Aaron Paden' }

local reset_subscription = nil
local stop_subscription = nil
local frame_subscription = nil

local defenderlr = exports

function defenderlr.startplugin()

	print("DefenderLR Plugin: Starting v" .. exports.version)

	-- ioport_type enum ordinals can change between MAME versions...
	-- Resolve types dynamically from ioport token strings:
	local IPT_JOYSTICK_LEFT = "P1_JOYSTICK_LEFT"
	local IPT_JOYSTICK_RIGHT = "P1_JOYSTICK_RIGHT"

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

	local function resolve_input_type_from_token(token)
		if ioport == nil then
			return nil
		end

		local ok_direct, input_type, player = pcall(function()
			return ioport:token_to_input_type(token)
		end)
		if ok_direct and input_type ~= nil then
			local enum_value = tonumber(input_type)
			if ioport.types ~= nil then
				for _, entry in pairs(ioport.types) do
					if tonumber(entry.type) == enum_value and tonumber(entry.player) == tonumber(player) then
						return entry
					end
				end
				return enum_value
			end
			return enum_value
		end

		if ioport.types == nil then
			return nil
		end

		for _, entry in pairs(ioport.types) do
			if entry.token == token then
				return entry
			end
		end

		return nil
	end

	local function get_type_seq_safe(input_type)
		if ioport == nil then
			return nil
		end
		if input_type == nil then
			return nil
		end

		local ok, seq_or_err = pcall(function()
			return ioport:type_seq(input_type, nil, nil)
		end)
		if ok then
			return seq_or_err
		end

		ok, seq_or_err = pcall(function()
			return ioport:type_seq(input_type, 0, nil)
		end)
		if ok then
			return seq_or_err
		end

		return nil
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
			frame_subscription = nil
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
				button_left = get_type_seq_safe(resolve_input_type_from_token(IPT_JOYSTICK_LEFT))
				button_right = get_type_seq_safe(resolve_input_type_from_token(IPT_JOYSTICK_RIGHT))
				if button_left == nil then
					button_left = emu.input_seq()
				end
				if button_right == nil then
					button_right = emu.input_seq()
				end
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
