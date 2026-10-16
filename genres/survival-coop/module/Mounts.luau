--!strict
-- Mounts: species-driven ride values (plan SYS-101 / FAUNA-05, SYS-123 / SYS-051).
--
-- Pure and clock-free. Whether a species can be ridden, its ride speed and its
-- carry capacity are species values authored in the pack and validated against
-- the canonical wildlife content (species ids and their archetype flag). A
-- skin is cosmetic: it names a species and a paid marker and nothing else, so
-- a paid skin resolves to exactly the free same-species speed and carry in
-- every zone, and no skin can ever add carry capacity. In a PvP opt-in zone
-- the ride speed is clamped to one shared cap, so paid and free mounts of any
-- species are bounded identically.
local Content = require("../../../core/domain/survival/Content")
local Archetype = require("../../../core/domain/survival/Archetype")
local M = {}

export type SpeciesRule = { rideable: boolean, rideSpeedStuds: number, carryMilli: number }
export type SkinRule = { species: string, paid: boolean }
export type Rules = {
	pvpSpeedCapStuds: number,
	species: { [string]: SpeciesRule },
	skins: { [string]: SkinRule }?,
}
export type Species = { rideable: boolean, rideSpeedStuds: number, carryMilli: number, flag: string? }
export type Catalog = { pvpSpeedCapStuds: number, species: { [string]: Species }, skins: { [string]: SkinRule } }
export type Zone = { pvp: boolean }
export type Ride = {
	species: string,
	skin: string?,
	paid: boolean,
	speedStuds: number,
	carryMilli: number,
	clamped: boolean,
}

M.MAX_SPEED_STUDS = 200
M.MAX_CARRY_MILLI = 10000000

local function integer(n: any, low: number, high: number): boolean
	return type(n) == "number" and n == n and n % 1 == 0 and n >= low and n <= high
end

local function exact(value: any, fields: { string }, code: string)
	assert(type(value) == "table", code)
	for key in value do
		assert(table.find(fields, key) ~= nil, code)
	end
end

--- Validates pack rules against canonical wildlife content and freezes them.
--- Every species id must exist in `content.wildlife`; an unlisted species is
--- simply not rideable. Species and skin entries accept no extra fields.
function M.catalog(content: Content.Document, rules: Rules): Catalog
	exact(rules, { "pvpSpeedCapStuds", "species", "skins" }, "INVALID_MOUNT_RULES")
	assert(integer(rules.pvpSpeedCapStuds, 1, M.MAX_SPEED_STUDS), "INVALID_SPEED_CAP")
	assert(type(rules.species) == "table", "INVALID_MOUNT_SPECIES")
	local known: { [string]: boolean } = {}
	local flags: { [string]: string } = {}
	for _, entry in content.wildlife do
		-- Only archetype wildlife (which always publish a flag) can be ridden.
		known[entry.id] = Archetype.isArchetype(entry.behavior)
		if entry.flag ~= nil then
			flags[entry.id] = entry.flag
		end
	end
	local result: Catalog = { pvpSpeedCapStuds = rules.pvpSpeedCapStuds, species = {}, skins = {} }
	for id, rule in rules.species do
		assert(type(id) == "string" and known[id] ~= nil, "UNKNOWN_SPECIES")
		exact(rule, { "rideable", "rideSpeedStuds", "carryMilli" }, "INVALID_SPECIES_RULE")
		assert(type(rule.rideable) == "boolean", "INVALID_RIDEABLE")
		assert(not rule.rideable or known[id], "RIDEABLE_NEEDS_ARCHETYPE")
		assert(integer(rule.carryMilli, 0, M.MAX_CARRY_MILLI), "INVALID_CARRY")
		if rule.rideable then
			assert(integer(rule.rideSpeedStuds, 1, M.MAX_SPEED_STUDS), "INVALID_RIDE_SPEED")
		else
			assert(rule.rideSpeedStuds == 0 and rule.carryMilli == 0, "UNRIDEABLE_HAS_VALUES")
		end
		local rideable: boolean = rule.rideable
		result.species[id] = table.freeze({
			rideable = rideable,
			rideSpeedStuds = rule.rideSpeedStuds,
			carryMilli = rule.carryMilli,
			flag = flags[id],
		})
	end
	local skins: { [string]: SkinRule } = rules.skins or {}
	for id, skin in skins do
		assert(type(id) == "string" and #id > 0 and #id <= 64, "INVALID_SKIN_ID")
		-- Exactly {species, paid}: a skin cannot carry speed, carry or any effect.
		exact(skin, { "species", "paid" }, "SKIN_IS_COSMETIC")
		assert(type(skin.paid) == "boolean", "INVALID_SKIN_PAID")
		local base = result.species[skin.species]
		assert(base ~= nil and base.rideable, "SKIN_SPECIES_NOT_RIDEABLE")
		result.skins[id] = table.freeze({ species = skin.species, paid = skin.paid })
	end
	table.freeze(result.species)
	table.freeze(result.skins)
	return table.freeze(result)
end

function M.isRideable(catalog: Catalog, species: string): boolean
	local rule = catalog.species[species]
	return rule ~= nil and rule.rideable
end

--- Resolves the ride a species gives in `zone`. The skin only selects the
--- appearance; speed and carry come from the species, and speed is clamped to
--- the shared cap in a PvP opt-in zone. Returns nil plus a reason on refusal.
function M.resolve(catalog: Catalog, species: string, skin: string?, zone: Zone): (Ride?, string?)
	assert(type(zone) == "table" and type(zone.pvp) == "boolean", "INVALID_ZONE")
	local rule = catalog.species[species]
	if rule == nil then
		return nil, "UNKNOWN_SPECIES"
	end
	if not rule.rideable then
		return nil, "NOT_RIDEABLE"
	end
	local paid = false
	if skin ~= nil then
		local entry = catalog.skins[skin]
		if entry == nil then
			return nil, "UNKNOWN_SKIN"
		end
		if entry.species ~= species then
			return nil, "SKIN_SPECIES_MISMATCH"
		end
		paid = entry.paid
	end
	local clamped = zone.pvp and rule.rideSpeedStuds > catalog.pvpSpeedCapStuds
	return {
		species = species,
		skin = skin,
		paid = paid,
		speedStuds = if clamped then catalog.pvpSpeedCapStuds else rule.rideSpeedStuds,
		carryMilli = rule.carryMilli,
		clamped = clamped,
	},
		nil
end

--- Carry capacity while riding: the bag's own capacity plus the species carry.
--- Only a species value is ever added; skins never appear here (SYS-051).
function M.carryCapacity(baseMilli: number, ride: Ride?): number
	assert(integer(baseMilli, 0, 2 ^ 31), "INVALID_BASE_CARRY")
	return baseMilli + (if ride then ride.carryMilli else 0)
end

return M
