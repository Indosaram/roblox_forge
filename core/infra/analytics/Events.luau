--!strict
-- Events: ordered analytics event registry with a validating, counting emitter.

export type Fields = { [string]: any }
export type Sink = (name: string, fields: Fields) -> ()

local Events = {}

local NAMES: { string } = {
	"session_start",
	"session_end",
	"tutorial_step",
	"tutorial_complete",
	"egg_purchase",
	"egg_hatch",
	"kaiju_merge",
	"siege_join",
	"raid_success",
	"quest_claim",
	"store_open",
	"robux_purchase",
}

local SCHEMA: { [string]: { string } } = {
	session_start = {},
	session_end = {},
	tutorial_step = { "step" },
	tutorial_complete = {},
	egg_purchase = { "eggId", "price" },
	egg_hatch = { "eggId", "kaijuId", "rarity" },
	kaiju_merge = { "fromKaijuId", "toKaijuId" },
	siege_join = { "siegeId" },
	raid_success = { "raidId" },
	quest_claim = { "questId" },
	store_open = {},
	robux_purchase = { "productKey", "price" },
}

Events.NAMES = NAMES
Events.SCHEMA = SCHEMA

local Emitter = {}
Emitter.__index = Emitter

export type Emitter = typeof(setmetatable({} :: { _sink: Sink, _counts: { [string]: number } }, Emitter))

local function validate(name: string, fields: Fields?): Fields
	local schema = SCHEMA[name]
	if schema == nil then
		error("unknown event: " .. tostring(name))
	end
	local provided = fields or {}
	for _, required in schema do
		if provided[required] == nil then
			error(string.format("missing field '%s' for event '%s'", required, name))
		end
	end
	return provided
end

function Emitter.emit(self: Emitter, name: string, fields: Fields?): ()
	local provided = validate(name, fields)
	self._sink(name, provided)
	self._counts[name] = (self._counts[name] or 0) + 1
end

function Emitter.counts(self: Emitter): { [string]: number }
	return table.clone(self._counts)
end

function Events.new(sink: Sink): Emitter
	if type(sink) ~= "function" then
		error("invalid sink")
	end
	return setmetatable({ _sink = sink, _counts = {} :: { [string]: number } }, Emitter)
end

return Events
