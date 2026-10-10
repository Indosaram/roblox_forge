--!strict
-- Mode: selects the survival-coop instance implementation from the pack config.
--
-- `mode` absent or "wave" is the legacy camp-defense loop, served by the
-- untouched Adapter: same config keys, same save shape, same two actions. A
-- config that never mentions `mode` reaches Adapter with a byte-identical
-- table, so no existing pack changes behaviour.
--
-- `mode = "crafting"` selects CraftingAdapter, which declares its own
-- action/save/content versions and refuses every unimplemented feature by name.
--
-- This module routes. It implements no survival rules of its own.

local Shared = require("../../../core/domain/genre/Contract")
local Capability = require("../../../core/domain/survival/Capability")
local Adapter = require("./Adapter")
local CraftingAdapter = require("./CraftingAdapter")

local M = {}

--- Strips the mode selector before delegating to the legacy wave adapter,
--- which owns a closed config key set and must keep rejecting unknown keys.
local function waveConfig(data: Shared.ConfigData): Shared.ConfigData
	local copy = table.clone(data)
	copy.mode = nil
	return copy
end

function M.validateConfig(data: Shared.ConfigData): { string }
	if type(data) ~= "table" then
		return { "config: expected mapping" }
	end
	local mode, reason = Capability.modeOf(data.mode)
	if mode == nil then
		return { reason :: string }
	end
	if mode == "crafting" then
		return CraftingAdapter.validateConfig(data)
	end
	return Adapter.validateConfig(waveConfig(data))
end

--- A crafting save always carries its own `saveVersion` marker; a legacy wave
--- save never did. The marker therefore selects the reader, and a save written
--- by a newer crafting writer is refused by that reader rather than downgraded.
function M.validateSave(data: Shared.StateData): { string }
	if type(data) ~= "table" then
		return { "save: expected mapping" }
	end
	if data.saveVersion ~= nil then
		return CraftingAdapter.validateSave(data)
	end
	return Adapter.validateSave(data)
end

function M.create(config: Shared.ConfigData, services: Shared.Services): Shared.Instance
	local mode = Capability.modeOf(config.mode)
	if mode == "crafting" then
		return CraftingAdapter.new(config :: any, services)
	end
	return Adapter.new(waveConfig(config) :: any, services)
end

--- The capability descriptor a config resolves to, for CLI reporting.
function M.describe(config: Shared.ConfigData): (Capability.Descriptor?, string?)
	local mode, reason = Capability.modeOf(if type(config) == "table" then config.mode else nil)
	if mode == nil then
		return nil, reason
	end
	return Capability.describe(mode :: Capability.Mode), nil
end

return M
