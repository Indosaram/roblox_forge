--!strict
-- Events: ordered analytics event registry with a validating, counting emitter.
-- Survival events (plan 11.9) additionally declare typed payload fields in
-- TYPES; anomaly inputs from plan 7.1-5 (ratePerMinute, pathRepeatId,
-- transferGiven/transferReceived) are optional payload fields only.

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
	"gather",
	"craft",
	"build",
	"death",
	"travel",
	"trade",
	"tame",
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
	gather = { "actorId", "nodeId", "quantity" },
	craft = { "actorId", "recipeId", "jobId" },
	build = { "actorId", "structureId", "placementId" },
	death = { "actorId", "cause" },
	travel = { "actorId", "fromId", "toId" },
	trade = { "actorId", "counterpartyId", "itemId", "quantity" },
	tame = { "actorId", "creatureId", "speciesId" },
}

-- Field kinds: "string" is a non-empty string, "number" a finite number and
-- "count" a finite non-negative integer. Declared fields are checked whenever
-- present; required ones come from SCHEMA.
export type Kind = "string" | "number" | "count"

local TYPES: { [string]: { [string]: Kind } } = {
	gather = {
		actorId = "string",
		nodeId = "string",
		quantity = "count",
		atMillis = "number",
		ratePerMinute = "number",
		pathRepeatId = "string",
	},
	craft = {
		actorId = "string",
		recipeId = "string",
		jobId = "string",
		settlementId = "string",
		atMillis = "number",
		ratePerMinute = "number",
	},
	build = {
		actorId = "string",
		structureId = "string",
		placementId = "string",
		settlementId = "string",
		atMillis = "number",
	},
	death = {
		actorId = "string",
		cause = "string",
		deathId = "string",
		droppedItems = "count",
		atMillis = "number",
	},
	travel = {
		actorId = "string",
		fromId = "string",
		toId = "string",
		atMillis = "number",
		pathRepeatId = "string",
	},
	trade = {
		actorId = "string",
		counterpartyId = "string",
		itemId = "string",
		quantity = "count",
		transferGiven = "count",
		transferReceived = "count",
		atMillis = "number",
	},
	tame = {
		actorId = "string",
		creatureId = "string",
		speciesId = "string",
		atMillis = "number",
	},
}

-- The survival funnel/report group, in registry order.
local SURVIVAL: { string } = { "gather", "craft", "build", "death", "travel", "trade", "tame" }

Events.NAMES = NAMES
Events.SCHEMA = SCHEMA
Events.TYPES = TYPES
Events.SURVIVAL = SURVIVAL

local function matches(kind: string, value: any): boolean
	if kind == "string" then
		return type(value) == "string" and #value > 0
	end
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return false
	end
	return kind == "number" or (value >= 0 and value == math.floor(value))
end

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
	local types = TYPES[name]
	if types then
		for field, kind in types do
			local value = provided[field]
			if value ~= nil and not matches(kind, value) then
				error(string.format("invalid field '%s' for event '%s': expected %s", field, name, kind))
			end
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
