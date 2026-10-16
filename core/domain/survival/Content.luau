--!strict
-- Content: the versioned survival content catalog shared by survival packs.
--
-- This module validates and canonicalises catalog DATA only. It deliberately
-- implements no inventory, crafting job, placement, vitals or wildlife
-- behaviour -- those are separate domain modules owned by later tasks, and a
-- catalog that merely *declares* a quantity must never read as a working
-- mechanism. Every quantity a later rule has to compare, sum or scale is a
-- finite integral fixed-point value (milli-units for weight/durability/quality
-- and milliseconds for durations), so catalog maths never depends on float
-- formatting or accumulated rounding.

local Validation = require("../genre/Validation")
local Vitals = require("./Vitals")
local Archetype = require("./Archetype")

local M = {}

--- Catalog envelope version. A document declaring a *newer* version is refused
--- rather than downgraded: an old reader must never reinterpret new content.
M.VERSION = 1

--- Pinned rule identities. A catalog names the exact rule revision it was
--- authored against, so changing a rule is a visible versioned migration
--- instead of a silent reinterpretation of already-shipped content.
local RULES: { [string]: string } = {
	inheritance = "avg-quality-v1",
	durability = "quality-scaled-v1",
	ingredientSelection = "item-id-ascending",
	-- Return stored contents before removal; the separate build-cost refund is 50%.
	demolitionRefund = "full-storage-v1",
}
M.RULES = RULES

local RULE_NAMES = { "demolitionRefund", "durability", "ingredientSelection", "inheritance" }
local LIMIT_NAMES = {
	"hardWeightMilli",
	"qualityMilliMax",
	"qualityMilliMin",
	"slots",
	"softWeightMilli",
	"tribeMaxMembers",
}

--- Inbound inventory bounds every survival pack starts from. `softWeightMilli`
--- is the penalty threshold, `hardWeightMilli` the refusal threshold; reserved
--- quantity counts against both. Packs may tighten these, never exceed policy.
local DEFAULT_LIMITS: { [string]: number } = {
	slots = 20,
	hardWeightMilli = 90000,
	softWeightMilli = 60000,
	qualityMilliMin = 1,
	qualityMilliMax = 5000,
	tribeMaxMembers = 4,
}
M.DEFAULT_LIMITS = DEFAULT_LIMITS

local POLICY_MAXIMA: { [string]: number } = {
	slots = 20,
	hardWeightMilli = 90000,
	softWeightMilli = 90000,
	qualityMilliMin = 5000,
	qualityMilliMax = 5000,
	tribeMaxMembers = 4,
}

--- Absolute caps. They keep a canonical document inside the serialized-data
--- bounds the genre Executor already enforces (<=1024 entries, depth <=16).
local CAPS: { [string]: number } = {
	list = 256,
	tagsPerEntry = 16,
	slots = 100,
	weightMilli = 1000000,
	durabilityMilli = 1000000,
	qualityMilli = 5000,
	tribeMembers = 4,
	stack = 1000,
	quantity = 1000,
	millis = 86400000,
	footprint = 64,
	studs = 512,
	name = 64,
}
M.CAPS = CAPS

--- Sensing defaults from the approved wildlife contract. A catalog entry may
--- restate them, but never silently inherit a different number.
local WILDLIFE_DEFAULTS: { [string]: { [string]: number } } = {
	grazer = { senseStuds = 12, fleeStuds = 24 },
	hunter = {
		warnStuds = 12,
		attackStuds = 4,
		leashStuds = 40,
		telegraphMillis = 1000,
		cooldownMillis = 2000,
	},
}
M.WILDLIFE_DEFAULTS = WILDLIFE_DEFAULTS

export type Quantity = { item: string, quantity: number }
-- Catalog lookup data only: restoration for hunger/health, reduction for fatigue.
-- Applying it and debiting inventory are the authoritative command's job.
export type FoodEffects = { hungerMilli: number, healthMilli: number, fatigueMilli: number }
export type VitalsConfig = Vitals.Config
export type Item = {
	id: string,
	name: string,
	stackMax: number,
	weightMilli: number,
	maxDurabilityMilli: number?,
	foodEffects: FoodEffects?,
	tags: { string },
}
-- Crafting: a tag slot accepts any item carrying `tag` whose grade (1..5 stars)
-- is at least `minGrade`. `tier` is the minimum workbench tier; `latents` is
-- the declared-tag pool a latent attribute roll draws from.
export type Slot = { tag: string, minGrade: number, quantity: number }
export type Recipe = {
	id: string,
	craftMillis: number,
	inputs: { Quantity },
	outputs: { Quantity },
	station: string?,
	requiredToolTag: string?,
	slots: { Slot }?,
	tier: number?,
	latents: { string }?,
}
export type Node = { id: string, harvest: { Quantity }, respawnMillis: number }
export type Structure = {
	id: string,
	footprintX: number,
	footprintZ: number,
	station: boolean,
	cost: { Quantity },
	tier: number?,
}
export type Wildlife = {
	id: string,
	behavior: string,
	senseStuds: number?,
	fleeStuds: number?,
	warnStuds: number?,
	attackStuds: number?,
	leashStuds: number?,
	telegraphMillis: number?,
	cooldownMillis: number?,
	-- Archetype behaviour flag and danger band. Archetype entries always carry
	-- both after canonicalization; legacy grazer|hunter entries only if authored.
	flag: string?,
	dangerBand: number?,
}
-- Contracts section (plan §9.3): fixed first-day contracts, a seeded daily
-- pool, five faction trust tiers and fixed-composition sponsor bundles.
export type SponsorBundle = { tier: number, items: { Quantity } }
export type Faction = { id: string, name: string, trustThresholds: { number }, bundles: { SponsorBundle } }
export type ContractEntry = {
	id: string,
	faction: string,
	pool: string,
	deliver: { Quantity },
	reward: { Quantity },
	trust: number,
}
export type ContractCatalog = {
	factions: { Faction },
	entries: { ContractEntry },
	firstDay: { string },
	dailyCount: number,
	swapCooldownMillis: number,
	dayMillis: number,
}
export type Document = {
	version: number,
	contracts: ContractCatalog?,
	rules: { [string]: string },
	limits: { [string]: number },
	vitals: VitalsConfig?,
	tags: { string },
	items: { Item },
	recipes: { Recipe },
	nodes: { Node },
	structures: { Structure },
	wildlife: { Wildlife },
}

local CATALOGS = { "items", "recipes", "nodes", "structures", "wildlife" }
local FOOD_FIELDS = { "hungerMilli", "healthMilli", "fatigueMilli" }
local VITALS_FIELDS = {
	"hungerMillisPerUnit",
	"fatigueMilliPerAction",
	"restMilliPerSecond",
	"starvationMillisPerUnit",
}
local VITALS_DEFAULTS: VitalsConfig = {
	hungerMillisPerUnit = 18000,
	fatigueMilliPerAction = 500,
	restMilliPerSecond = 2000,
	starvationMillisPerUnit = 5000,
}

local function isId(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, "^[a-z][a-z0-9%-]*$") ~= nil
end

local function isInt(value: any, low: number, high: number): boolean
	return Validation.finite(value) and value % 1 == 0 and value >= low and value <= high
end

local function unknown(errors: { string }, prefix: string, source: any, allowed: { string })
	for key in source do
		if type(key) ~= "string" or not table.find(allowed, key) then
			table.insert(errors, prefix .. ": unknown field " .. tostring(key))
		end
	end
end

--- Validates a `{item, quantity}` list against the declared item catalog.
local function quantities(errors: { string }, prefix: string, raw: any, items: { [string]: boolean })
	if not Validation.dense(raw, CAPS.list) or #raw == 0 then
		table.insert(errors, prefix .. ": expected nonempty dense list")
		return
	end
	local seen: { [string]: boolean } = {}
	for index, entry in raw :: { any } do
		local at = string.format("%s[%d]", prefix, index)
		if type(entry) ~= "table" then
			table.insert(errors, at .. ": expected mapping")
			continue
		end
		unknown(errors, at, entry, { "item", "quantity" })
		if not isId(entry.item) then
			table.insert(errors, at .. ".item: invalid id")
		elseif not items[entry.item] then
			table.insert(errors, at .. ".item: unknown item " .. entry.item)
		elseif seen[entry.item] then
			table.insert(errors, at .. ".item: duplicate item " .. entry.item)
		else
			seen[entry.item] = true
		end
		if not isInt(entry.quantity, 1, CAPS.quantity) then
			table.insert(errors, at .. ".quantity: expected integer 1.." .. CAPS.quantity)
		end
	end
end

--- Reports a recipe dependency cycle: a recipe whose input is produced by a
--- recipe that (transitively) consumes one of this recipe's outputs can never
--- be crafted from gathered inputs, so it is malformed content rather than a
--- runtime failure.
local function cycles(errors: { string }, recipes: { any })
	local producers: { [string]: { string } } = {}
	for _, recipe in recipes do
		if type(recipe) ~= "table" or not isId(recipe.id) or type(recipe.outputs) ~= "table" then
			continue
		end
		for _, output in recipe.outputs do
			if type(output) == "table" and type(output.item) == "string" then
				local list = producers[output.item]
				if list == nil then
					list = {}
					producers[output.item] = list
				end
				table.insert(list, recipe.id)
			end
		end
	end
	local byId: { [string]: any } = {}
	for _, recipe in recipes do
		if type(recipe) == "table" and isId(recipe.id) then
			byId[recipe.id] = recipe
		end
	end
	local state: { [string]: number } = {}
	local reported: { [string]: boolean } = {}
	local function visit(id: string)
		if state[id] == 2 then
			return
		end
		if state[id] == 1 then
			if not reported[id] then
				reported[id] = true
				table.insert(errors, "recipes: cyclic dependency through " .. id)
			end
			return
		end
		state[id] = 1
		local recipe = byId[id]
		if recipe ~= nil and type(recipe.inputs) == "table" then
			for _, input in recipe.inputs do
				if type(input) == "table" and type(input.item) == "string" then
					local sources: { string } = producers[input.item] or {}
					for _, producer in sources do
						visit(producer)
					end
				end
			end
		end
		state[id] = 2
	end
	local ids: { string } = {}
	for id in byId do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		visit(id)
	end
end

local function validateLimits(errors: { string }, raw: any)
	if type(raw) ~= "table" then
		table.insert(errors, "limits: expected mapping")
		return
	end
	unknown(errors, "limits", raw, LIMIT_NAMES)
	-- Every tunable limit is bounded by the APPROVED SURVIVAL POLICY
	-- (POLICY_MAXIMA), not by the looser engine CAPS. A pack may tighten a
	-- limit; a catalog that tries to raise one above the approved inventory
	-- contract (20 slots, 90 hard weight including reserved quantity, quality
	-- clamped to 5000 milliunits, 4 tribe members) is rejected here, before
	-- anything is written.
	local bounds: { [string]: { number } } = {
		slots = { 1, POLICY_MAXIMA.slots },
		hardWeightMilli = { 1, POLICY_MAXIMA.hardWeightMilli },
		softWeightMilli = { 1, POLICY_MAXIMA.softWeightMilli },
		qualityMilliMin = { 1, POLICY_MAXIMA.qualityMilliMin },
		qualityMilliMax = { 1, POLICY_MAXIMA.qualityMilliMax },
		tribeMaxMembers = { 1, POLICY_MAXIMA.tribeMaxMembers },
	}
	for _, key in LIMIT_NAMES do
		local bound = bounds[key]
		if not isInt(raw[key], bound[1], bound[2]) then
			table.insert(
				errors,
				string.format(
					"limits.%s: expected integer %d..%d (approved survival policy maximum)",
					key,
					bound[1],
					bound[2]
				)
			)
		end
	end
	if
		isInt(raw.softWeightMilli, 1, POLICY_MAXIMA.softWeightMilli)
		and isInt(raw.hardWeightMilli, 1, POLICY_MAXIMA.hardWeightMilli)
	then
		if raw.softWeightMilli > raw.hardWeightMilli then
			table.insert(errors, "limits.softWeightMilli: must not exceed hardWeightMilli")
		end
	end
	if
		isInt(raw.qualityMilliMin, 1, POLICY_MAXIMA.qualityMilliMin)
		and isInt(raw.qualityMilliMax, 1, POLICY_MAXIMA.qualityMilliMax)
	then
		if raw.qualityMilliMin > raw.qualityMilliMax then
			table.insert(errors, "limits.qualityMilliMin: must not exceed qualityMilliMax")
		end
	end
end

local function validateTags(errors: { string }, raw: any): { [string]: boolean }
	local declared: { [string]: boolean } = {}
	if not Validation.dense(raw, CAPS.list) then
		table.insert(errors, "tags: expected dense list")
		return declared
	end
	for index, tag in raw do
		if not isId(tag) then
			table.insert(errors, string.format("tags[%d]: invalid id", index))
		elseif declared[tag] then
			table.insert(errors, string.format("tags[%d]: duplicate tag %s", index, tag))
		else
			declared[tag] = true
		end
	end
	return declared
end

local function validateVitals(errors: { string }, raw: any)
	if raw == nil then
		return
	end
	if type(raw) ~= "table" then
		table.insert(errors, "vitals: expected mapping")
		return
	end
	unknown(errors, "vitals", raw, VITALS_FIELDS)
	for _, field in VITALS_FIELDS do
		local period = field == "hungerMillisPerUnit" or field == "starvationMillisPerUnit"
		local low, high = if period then 1 else 0, if period then CAPS.millis else 100000
		if raw[field] ~= nil and not isInt(raw[field], low, high) then
			table.insert(errors, string.format("vitals.%s: expected integer %d..%d", field, low, high))
		end
	end
end

local function validateItems(errors: { string }, raw: any, tags: { [string]: boolean }): { [string]: boolean }
	local ids: { [string]: boolean } = {}
	if not Validation.dense(raw, CAPS.list) or #raw == 0 then
		table.insert(errors, "items: expected nonempty dense list")
		return ids
	end
	for index, item in raw do
		local at = string.format("items[%d]", index)
		if type(item) ~= "table" then
			table.insert(errors, at .. ": expected mapping")
			continue
		end
		unknown(
			errors,
			at,
			item,
			{ "id", "name", "stackMax", "weightMilli", "maxDurabilityMilli", "tags", "foodEffects" }
		)
		if item.foodEffects ~= nil then
			if type(item.foodEffects) ~= "table" then
				table.insert(errors, at .. ".foodEffects: expected mapping")
			else
				unknown(errors, at .. ".foodEffects", item.foodEffects, FOOD_FIELDS)
				for _, field in FOOD_FIELDS do
					if not isInt(item.foodEffects[field], 0, 100000) then
						table.insert(errors, at .. ".foodEffects." .. field .. ": expected integer 0..100000")
					end
				end
			end
		end
		if not isId(item.id) then
			table.insert(errors, at .. ".id: invalid id")
		elseif ids[item.id] then
			table.insert(errors, at .. ".id: duplicate item " .. item.id)
		else
			ids[item.id] = true
		end
		if type(item.name) ~= "string" or #item.name == 0 or #item.name > CAPS.name then
			table.insert(errors, at .. ".name: expected 1.." .. CAPS.name .. " characters")
		end
		if not isInt(item.stackMax, 1, CAPS.stack) then
			table.insert(errors, at .. ".stackMax: expected integer 1.." .. CAPS.stack)
		end
		if not isInt(item.weightMilli, 0, CAPS.weightMilli) then
			table.insert(errors, at .. ".weightMilli: expected integer 0.." .. CAPS.weightMilli)
		end
		if item.maxDurabilityMilli ~= nil and not isInt(item.maxDurabilityMilli, 1, CAPS.durabilityMilli) then
			table.insert(errors, at .. ".maxDurabilityMilli: expected integer 1.." .. CAPS.durabilityMilli)
		end
		if item.tags ~= nil then
			if not Validation.dense(item.tags, CAPS.tagsPerEntry) then
				table.insert(errors, at .. ".tags: expected dense list")
			else
				local seen: { [string]: boolean } = {}
				for tagIndex, tag in item.tags do
					if not isId(tag) or not tags[tag] then
						table.insert(
							errors,
							string.format("%s.tags[%d]: undeclared tag %s", at, tagIndex, tostring(tag))
						)
					elseif seen[tag] then
						table.insert(errors, string.format("%s.tags[%d]: duplicate tag %s", at, tagIndex, tag))
					else
						seen[tag] = true
					end
				end
			end
		end
	end
	return ids
end

local function validateStructures(errors: { string }, raw: any, items: { [string]: boolean }): { [string]: boolean }
	local stations: { [string]: boolean } = {}
	if raw == nil then
		return stations
	end
	if not Validation.dense(raw, CAPS.list) then
		table.insert(errors, "structures: expected dense list")
		return stations
	end
	local ids: { [string]: boolean } = {}
	for index, entry in raw do
		local at = string.format("structures[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, at .. ": expected mapping")
			continue
		end
		unknown(errors, at, entry, { "id", "footprintX", "footprintZ", "station", "cost", "tier" })
		if entry.tier ~= nil and (not isInt(entry.tier, 1, 5) or entry.station ~= true) then
			table.insert(errors, at .. ".tier: expected integer 1..5 on a station")
		end
		if not isId(entry.id) then
			table.insert(errors, at .. ".id: invalid id")
		elseif ids[entry.id] then
			table.insert(errors, at .. ".id: duplicate structure " .. entry.id)
		else
			ids[entry.id] = true
			if entry.station == true then
				stations[entry.id] = true
			end
		end
		for _, axis in { "footprintX", "footprintZ" } do
			if not isInt(entry[axis], 1, CAPS.footprint) then
				table.insert(errors, string.format("%s.%s: expected integer 1..%d", at, axis, CAPS.footprint))
			end
		end
		if entry.station ~= nil and type(entry.station) ~= "boolean" then
			table.insert(errors, at .. ".station: expected boolean")
		end
		quantities(errors, at .. ".cost", entry.cost, items)
	end
	return stations
end

local function validateRecipes(
	errors: { string },
	raw: any,
	items: { [string]: boolean },
	tags: { [string]: boolean },
	stations: { [string]: boolean }
)
	if raw == nil then
		return
	end
	if not Validation.dense(raw, CAPS.list) then
		table.insert(errors, "recipes: expected dense list")
		return
	end
	local ids: { [string]: boolean } = {}
	for index, recipe in raw do
		local at = string.format("recipes[%d]", index)
		if type(recipe) ~= "table" then
			table.insert(errors, at .. ": expected mapping")
			continue
		end
		unknown(
			errors,
			at,
			recipe,
			{ "id", "craftMillis", "inputs", "outputs", "station", "requiredToolTag", "slots", "tier", "latents" }
		)
		local slotted = false
		if recipe.slots ~= nil then
			if not Validation.dense(recipe.slots, CAPS.tagsPerEntry) or #recipe.slots == 0 then
				table.insert(errors, at .. ".slots: expected nonempty dense list")
			else
				slotted = true
				for slotIndex, slot in recipe.slots do
					local slotAt = string.format("%s.slots[%d]", at, slotIndex)
					if type(slot) ~= "table" then
						table.insert(errors, slotAt .. ": expected mapping")
						continue
					end
					unknown(errors, slotAt, slot, { "tag", "minGrade", "quantity" })
					if not isId(slot.tag) or not tags[slot.tag] then
						table.insert(errors, slotAt .. ".tag: undeclared tag " .. tostring(slot.tag))
					end
					if not isInt(slot.minGrade, 1, 5) then
						table.insert(errors, slotAt .. ".minGrade: expected integer 1..5")
					end
					if not isInt(slot.quantity, 1, CAPS.quantity) then
						table.insert(errors, slotAt .. ".quantity: expected integer 1.." .. CAPS.quantity)
					end
				end
			end
		end
		if recipe.tier ~= nil and (not isInt(recipe.tier, 1, 5) or recipe.station == nil) then
			table.insert(errors, at .. ".tier: expected integer 1..5 with a station")
		end
		if recipe.latents ~= nil then
			if not Validation.dense(recipe.latents, CAPS.tagsPerEntry) or #recipe.latents == 0 then
				table.insert(errors, at .. ".latents: expected nonempty dense list")
			else
				local seenLatent: { [string]: boolean } = {}
				for latentIndex, latent in recipe.latents do
					if not isId(latent) or not tags[latent] or seenLatent[latent] then
						table.insert(
							errors,
							string.format(
								"%s.latents[%d]: undeclared or duplicate tag %s",
								at,
								latentIndex,
								tostring(latent)
							)
						)
					else
						seenLatent[latent] = true
					end
				end
			end
		end
		if not isId(recipe.id) then
			table.insert(errors, at .. ".id: invalid id")
		elseif ids[recipe.id] then
			table.insert(errors, at .. ".id: duplicate recipe " .. recipe.id)
		else
			ids[recipe.id] = true
		end
		if not isInt(recipe.craftMillis, 1, CAPS.millis) then
			table.insert(errors, at .. ".craftMillis: expected integer 1.." .. CAPS.millis)
		end
		-- Tag slots may replace fixed inputs entirely.
		local hasInputs = recipe.inputs ~= nil and not (type(recipe.inputs) == "table" and next(recipe.inputs) == nil)
		if not slotted or hasInputs then
			quantities(errors, at .. ".inputs", recipe.inputs, items)
		end
		quantities(errors, at .. ".outputs", recipe.outputs, items)
		if recipe.station ~= nil then
			if not isId(recipe.station) then
				table.insert(errors, at .. ".station: invalid id")
			elseif not stations[recipe.station] then
				table.insert(errors, at .. ".station: unknown station " .. recipe.station)
			end
		end
		if recipe.requiredToolTag ~= nil then
			if not isId(recipe.requiredToolTag) then
				table.insert(errors, at .. ".requiredToolTag: invalid id")
			elseif not tags[recipe.requiredToolTag] then
				table.insert(errors, at .. ".requiredToolTag: undeclared tag " .. recipe.requiredToolTag)
			end
		end
	end
	if Validation.dense(raw, CAPS.list) then
		cycles(errors, raw)
	end
end

local function validateNodes(errors: { string }, raw: any, items: { [string]: boolean })
	if raw == nil then
		return
	end
	if not Validation.dense(raw, CAPS.list) then
		table.insert(errors, "nodes: expected dense list")
		return
	end
	local ids: { [string]: boolean } = {}
	for index, node in raw do
		local at = string.format("nodes[%d]", index)
		if type(node) ~= "table" then
			table.insert(errors, at .. ": expected mapping")
			continue
		end
		unknown(errors, at, node, { "id", "harvest", "respawnMillis" })
		if not isId(node.id) then
			table.insert(errors, at .. ".id: invalid id")
		elseif ids[node.id] then
			table.insert(errors, at .. ".id: duplicate node " .. node.id)
		else
			ids[node.id] = true
		end
		if not isInt(node.respawnMillis, 1, CAPS.millis) then
			table.insert(errors, at .. ".respawnMillis: expected integer 1.." .. CAPS.millis)
		end
		quantities(errors, at .. ".harvest", node.harvest, items)
	end
end

--- Contracts section. Trust has exactly five tiers; tier 1 starts at 0 and
--- every later threshold is strictly higher. Sponsor bundles are fixed item
--- lists keyed by tier: there is no weight, chance or roll field to declare.
local CONTRACT_TIERS = 5
local CONTRACT_POOLS = { "first-day", "daily" }
local CONTRACT_FIRST_DAY = 3
local CONTRACT_DEFAULTS = { dailyCount = 3, swapCooldownMillis = 3600000, dayMillis = 86400000 }
M.CONTRACT_TIERS = CONTRACT_TIERS
M.CONTRACT_DEFAULTS = CONTRACT_DEFAULTS

local function validateContracts(errors: { string }, raw: any, items: { [string]: boolean })
	if raw == nil then
		return
	end
	if type(raw) ~= "table" then
		table.insert(errors, "contracts: expected mapping")
		return
	end
	unknown(
		errors,
		"contracts",
		raw,
		{ "factions", "entries", "firstDay", "dailyCount", "swapCooldownMillis", "dayMillis" }
	)
	local factions: { [string]: boolean } = {}
	if not Validation.dense(raw.factions, CAPS.list) or #raw.factions == 0 then
		table.insert(errors, "contracts.factions: expected nonempty dense list")
	else
		for index, faction in raw.factions do
			local at = string.format("contracts.factions[%d]", index)
			if type(faction) ~= "table" then
				table.insert(errors, at .. ": expected mapping")
				continue
			end
			unknown(errors, at, faction, { "id", "name", "trustThresholds", "bundles" })
			if not isId(faction.id) then
				table.insert(errors, at .. ".id: invalid id")
			elseif factions[faction.id] then
				table.insert(errors, at .. ".id: duplicate faction " .. faction.id)
			else
				factions[faction.id] = true
			end
			if type(faction.name) ~= "string" or #faction.name == 0 or #faction.name > CAPS.name then
				table.insert(errors, at .. ".name: expected 1.." .. CAPS.name .. " characters")
			end
			local thresholds = faction.trustThresholds
			if not Validation.dense(thresholds, CONTRACT_TIERS) or #thresholds ~= CONTRACT_TIERS then
				table.insert(errors, string.format("%s.trustThresholds: expected exactly %d tiers", at, CONTRACT_TIERS))
			else
				for tier, value in thresholds do
					local previous = if tier == 1 then nil else thresholds[tier - 1]
					local ok = if previous == nil
						then value == 0
						else isInt(previous, 0, CAPS.weightMilli) and isInt(value, previous + 1, CAPS.weightMilli)
					if not ok then
						table.insert(
							errors,
							string.format(
								"%s.trustThresholds[%d]: expected 0 then strictly ascending integers",
								at,
								tier
							)
						)
						break
					end
				end
			end
			if faction.bundles ~= nil then
				if not Validation.dense(faction.bundles, CONTRACT_TIERS) then
					table.insert(errors, at .. ".bundles: expected dense list")
				else
					local tiers: { [number]: boolean } = {}
					for bundleIndex, bundle in faction.bundles do
						local bundleAt = string.format("%s.bundles[%d]", at, bundleIndex)
						if type(bundle) ~= "table" then
							table.insert(errors, bundleAt .. ": expected mapping")
							continue
						end
						unknown(errors, bundleAt, bundle, { "tier", "items" })
						if not isInt(bundle.tier, 1, CONTRACT_TIERS) then
							table.insert(
								errors,
								string.format("%s.tier: expected integer 1..%d", bundleAt, CONTRACT_TIERS)
							)
						elseif tiers[bundle.tier] then
							table.insert(errors, bundleAt .. ".tier: duplicate tier " .. bundle.tier)
						else
							tiers[bundle.tier] = true
						end
						quantities(errors, bundleAt .. ".items", bundle.items, items)
					end
				end
			end
		end
	end
	local pools: { [string]: string } = {}
	local dailySize = 0
	if not Validation.dense(raw.entries, CAPS.list) or #raw.entries == 0 then
		table.insert(errors, "contracts.entries: expected nonempty dense list")
	else
		for index, entry in raw.entries do
			local at = string.format("contracts.entries[%d]", index)
			if type(entry) ~= "table" then
				table.insert(errors, at .. ": expected mapping")
				continue
			end
			unknown(errors, at, entry, { "id", "faction", "pool", "deliver", "reward", "trust" })
			if not isId(entry.id) then
				table.insert(errors, at .. ".id: invalid id")
			elseif pools[entry.id] then
				table.insert(errors, at .. ".id: duplicate contract " .. entry.id)
			elseif table.find(CONTRACT_POOLS, entry.pool) then
				pools[entry.id] = entry.pool
				if entry.pool == "daily" then
					dailySize += 1
				end
			end
			if not table.find(CONTRACT_POOLS, entry.pool) then
				table.insert(errors, at .. ".pool: expected first-day|daily")
			end
			if not isId(entry.faction) or not factions[entry.faction] then
				table.insert(errors, at .. ".faction: unknown faction " .. tostring(entry.faction))
			end
			quantities(errors, at .. ".deliver", entry.deliver, items)
			if entry.reward ~= nil then
				quantities(errors, at .. ".reward", entry.reward, items)
			end
			if not isInt(entry.trust, 0, CAPS.quantity) then
				table.insert(errors, at .. ".trust: expected integer 0.." .. CAPS.quantity)
			end
		end
	end
	if not Validation.dense(raw.firstDay, CONTRACT_FIRST_DAY) or #raw.firstDay ~= CONTRACT_FIRST_DAY then
		table.insert(errors, string.format("contracts.firstDay: expected exactly %d contract ids", CONTRACT_FIRST_DAY))
	else
		local seen: { [string]: boolean } = {}
		for index, id in raw.firstDay do
			local at = string.format("contracts.firstDay[%d]", index)
			if type(id) ~= "string" or pools[id] ~= "first-day" then
				table.insert(errors, at .. ": expected a first-day contract id, got " .. tostring(id))
			elseif seen[id] then
				table.insert(errors, at .. ": duplicate contract " .. id)
			else
				seen[id] = true
			end
		end
	end
	local dailyCount = if raw.dailyCount == nil then CONTRACT_DEFAULTS.dailyCount else raw.dailyCount
	if not isInt(dailyCount, 1, 8) then
		table.insert(errors, "contracts.dailyCount: expected integer 1..8")
	elseif dailySize < dailyCount then
		table.insert(errors, string.format("contracts.entries: daily pool has %d, needs %d", dailySize, dailyCount))
	end
	for _, field in { "swapCooldownMillis", "dayMillis" } do
		if raw[field] ~= nil and not isInt(raw[field], 1, CAPS.millis) then
			table.insert(errors, string.format("contracts.%s: expected integer 1..%d", field, CAPS.millis))
		end
	end
end

local GRAZER_FIELDS: { string } = { "senseStuds", "fleeStuds" }
local HUNTER_FIELDS: { string } = { "warnStuds", "attackStuds", "leashStuds", "telegraphMillis", "cooldownMillis" }

local function validateWildlife(errors: { string }, raw: any)
	if raw == nil then
		return
	end
	if not Validation.dense(raw, CAPS.list) then
		table.insert(errors, "wildlife: expected dense list")
		return
	end
	local ids: { [string]: boolean } = {}
	for index, entry in raw do
		local at = string.format("wildlife[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, at .. ": expected mapping")
			continue
		end
		local allowed = { "id", "behavior", "flag", "dangerBand" }
		for _, field in GRAZER_FIELDS do
			table.insert(allowed, field)
		end
		for _, field in HUNTER_FIELDS do
			table.insert(allowed, field)
		end
		unknown(errors, at, entry, allowed)
		if not isId(entry.id) then
			table.insert(errors, at .. ".id: invalid id")
		elseif ids[entry.id] then
			table.insert(errors, at .. ".id: duplicate wildlife " .. entry.id)
		else
			ids[entry.id] = true
		end
		-- Legacy engine names (grazer|hunter) stay valid; an archetype id runs
		-- the engine its archetype declares.
		local engine = if type(entry.behavior) == "string" then Archetype.engine(entry.behavior) else nil
		if engine == nil then
			table.insert(errors, at .. ".behavior: expected grazer|hunter or an archetype id")
			continue
		end
		if entry.flag ~= nil and not Archetype.allowsFlag(engine, entry.flag) then
			table.insert(errors, string.format("%s.flag: %s not valid for %s engine", at, tostring(entry.flag), engine))
		end
		if entry.dangerBand ~= nil and not Archetype.isBand(entry.dangerBand) then
			table.insert(
				errors,
				string.format("%s.dangerBand: expected integer %d..%d", at, Archetype.BAND_MIN, Archetype.BAND_MAX)
			)
		end
		local own: { string } = if engine == "grazer" then GRAZER_FIELDS else HUNTER_FIELDS
		local foreign: { string } = if engine == "grazer" then HUNTER_FIELDS else GRAZER_FIELDS
		for _, field in foreign do
			if entry[field] ~= nil then
				table.insert(errors, string.format("%s.%s: not valid for %s", at, field, entry.behavior))
			end
		end
		local resolved: { [string]: number } = {}
		for _, field in own do
			local value = if entry[field] == nil then WILDLIFE_DEFAULTS[engine][field] else entry[field]
			local cap = if string.match(field, "Millis$") then CAPS.millis else CAPS.studs
			if not isInt(value, 1, cap) then
				table.insert(errors, string.format("%s.%s: expected integer 1..%d", at, field, cap))
			else
				resolved[field] = value
			end
		end
		if engine == "grazer" then
			if resolved.senseStuds and resolved.fleeStuds and resolved.senseStuds >= resolved.fleeStuds then
				table.insert(errors, at .. ".senseStuds: must be below fleeStuds")
			end
		elseif resolved.attackStuds and resolved.warnStuds and resolved.leashStuds then
			if not (resolved.attackStuds < resolved.warnStuds and resolved.warnStuds <= resolved.leashStuds) then
				table.insert(errors, at .. ".warnStuds: expected attackStuds < warnStuds <= leashStuds")
			end
		end
	end
end

--- Returns every schema or policy violation in a decoded content document, in
--- sorted order. An empty list means the document is a valid catalog; it does
--- NOT mean any mechanism that consumes the catalog is implemented.
function M.validate(raw: any): { string }
	if type(raw) ~= "table" then
		return { "content: expected mapping" }
	end
	local errors: { string } = {}
	unknown(errors, "content", raw, {
		"survival_content",
		"rules",
		"limits",
		"tags",
		"items",
		"recipes",
		"nodes",
		"structures",
		"wildlife",
		"vitals",
		"contracts",
	})
	if raw.survival_content ~= M.VERSION then
		table.insert(
			errors,
			string.format(
				"survival_content: unsupported version %s (this reader supports %d)",
				tostring(raw.survival_content),
				M.VERSION
			)
		)
	end
	if type(raw.rules) ~= "table" then
		table.insert(errors, "rules: expected mapping")
	else
		unknown(errors, "rules", raw.rules, RULE_NAMES)
		for _, key in RULE_NAMES do
			if raw.rules[key] ~= RULES[key] then
				table.insert(
					errors,
					string.format("rules.%s: expected pinned %q, got %s", key, RULES[key], tostring(raw.rules[key]))
				)
			end
		end
	end
	validateLimits(errors, raw.limits)
	validateVitals(errors, raw.vitals)
	local tags = validateTags(errors, if raw.tags == nil then {} else raw.tags)
	local items = validateItems(errors, raw.items, tags)
	local stations = validateStructures(errors, raw.structures, items)
	validateRecipes(errors, raw.recipes, items, tags, stations)
	validateNodes(errors, raw.nodes, items)
	validateWildlife(errors, raw.wildlife)
	validateContracts(errors, raw.contracts, items)
	table.sort(errors)
	return errors
end

local function sortById(list: { any })
	table.sort(list, function(left, right)
		return left.id < right.id
	end)
end

local function canonicalQuantities(raw: any): { Quantity }
	local list: { Quantity } = {}
	for _, entry in raw or {} do
		table.insert(list, { item = entry.item, quantity = entry.quantity })
	end
	-- Deterministic ingredient selection: ascending item id, always.
	table.sort(list, function(left, right)
		return left.item < right.item
	end)
	return list
end

local function sortedStrings(raw: { string }): { string }
	local list = table.clone(raw)
	table.sort(list)
	return list
end

local function canonicalSlots(raw: any): { Slot }?
	if raw == nil then
		return nil
	end
	local list: { Slot } = {}
	for _, slot in raw do
		table.insert(list, { tag = slot.tag, minGrade = slot.minGrade, quantity = slot.quantity })
	end
	table.sort(list, function(left, right)
		if left.tag ~= right.tag then
			return left.tag < right.tag
		end
		return left.minGrade < right.minGrade
	end)
	return list
end

--- Validates `raw` and returns its canonical form: defaults resolved, every
--- catalog sorted by id and every quantity list sorted by item id. Two runs
--- over the same source always produce byte-identical rendered output.
function M.canonicalize(raw: any): (Document?, { string })
	local errors = M.validate(raw)
	if #errors > 0 then
		return nil, errors
	end
	local tags: { string } = {}
	for _, tag in raw.tags or {} do
		table.insert(tags, tag)
	end
	table.sort(tags)
	local items: { Item } = {}
	for _, item in raw.items do
		local itemTags: { string } = {}
		for _, tag in item.tags or {} do
			table.insert(itemTags, tag)
		end
		table.sort(itemTags)
		table.insert(items, {
			id = item.id,
			name = item.name,
			stackMax = item.stackMax,
			weightMilli = item.weightMilli,
			maxDurabilityMilli = item.maxDurabilityMilli,
			foodEffects = if item.foodEffects == nil then nil else table.clone(item.foodEffects),
			tags = itemTags,
		})
	end
	sortById(items)
	local recipes: { Recipe } = {}
	for _, recipe in raw.recipes or {} do
		table.insert(recipes, {
			id = recipe.id,
			craftMillis = recipe.craftMillis,
			inputs = canonicalQuantities(recipe.inputs),
			outputs = canonicalQuantities(recipe.outputs),
			station = recipe.station,
			requiredToolTag = recipe.requiredToolTag,
			slots = canonicalSlots(recipe.slots),
			tier = recipe.tier,
			latents = if recipe.latents == nil then nil else sortedStrings(recipe.latents),
		})
	end
	sortById(recipes)
	local nodes: { Node } = {}
	for _, node in raw.nodes or {} do
		table.insert(
			nodes,
			{ id = node.id, harvest = canonicalQuantities(node.harvest), respawnMillis = node.respawnMillis }
		)
	end
	sortById(nodes)
	local structures: { Structure } = {}
	for _, structure in raw.structures or {} do
		table.insert(structures, {
			id = structure.id,
			footprintX = structure.footprintX,
			footprintZ = structure.footprintZ,
			station = structure.station == true,
			cost = canonicalQuantities(structure.cost),
			tier = structure.tier,
		})
	end
	sortById(structures)
	local wildlife: { Wildlife } = {}
	local rawWildlife: { any } = raw.wildlife or {}
	for _, entry in rawWildlife do
		local resolved: Wildlife = { id = entry.id, behavior = entry.behavior }
		local archetype = assert(Archetype.get(entry.behavior), "validated behavior")
		local fields: { string } = if archetype.engine == "grazer" then GRAZER_FIELDS else HUNTER_FIELDS
		for _, field in fields do
			(resolved :: any)[field] = if entry[field] == nil
				then WILDLIFE_DEFAULTS[archetype.engine][field]
				else entry[field]
		end
		-- Archetypes always publish their resolved flag and band; legacy entries
		-- render byte-identically unless they author one.
		local isArchetype = Archetype.isArchetype(entry.behavior)
		resolved.flag = if entry.flag ~= nil then entry.flag elseif isArchetype then archetype.flag else nil
		resolved.dangerBand = if entry.dangerBand ~= nil then entry.dangerBand elseif isArchetype then 1 else nil
		table.insert(wildlife, resolved)
	end
	sortById(wildlife)
	local limits: { [string]: number } = {}
	for _, key in LIMIT_NAMES do
		limits[key] = raw.limits[key]
	end
	local rules: { [string]: string } = table.clone(RULES)
	local vitals: VitalsConfig? = nil
	if raw.vitals ~= nil then
		local resolved = table.clone(VITALS_DEFAULTS)
		for _, field in VITALS_FIELDS do
			if raw.vitals[field] ~= nil then
				(resolved :: any)[field] = raw.vitals[field]
			end
		end
		vitals = resolved
	end
	local contracts: ContractCatalog? = nil
	if raw.contracts ~= nil then
		local source = raw.contracts
		local factions: { Faction } = {}
		for _, faction in source.factions do
			local bundles: { SponsorBundle } = {}
			for _, bundle in faction.bundles or {} do
				table.insert(bundles, { tier = bundle.tier, items = canonicalQuantities(bundle.items) })
			end
			table.sort(bundles, function(left, right)
				return left.tier < right.tier
			end)
			table.insert(factions, {
				id = faction.id,
				name = faction.name,
				trustThresholds = table.clone(faction.trustThresholds),
				bundles = bundles,
			})
		end
		sortById(factions)
		local entries: { ContractEntry } = {}
		for _, entry in source.entries do
			table.insert(entries, {
				id = entry.id,
				faction = entry.faction,
				pool = entry.pool,
				deliver = canonicalQuantities(entry.deliver),
				reward = canonicalQuantities(entry.reward),
				trust = entry.trust,
			})
		end
		sortById(entries)
		contracts = {
			factions = factions,
			entries = entries,
			-- Authored order is the fixed first-day order; it is never sorted.
			firstDay = table.clone(source.firstDay),
			dailyCount = source.dailyCount or CONTRACT_DEFAULTS.dailyCount,
			swapCooldownMillis = source.swapCooldownMillis or CONTRACT_DEFAULTS.swapCooldownMillis,
			dayMillis = source.dayMillis or CONTRACT_DEFAULTS.dayMillis,
		}
	end
	return {
		version = M.VERSION,
		contracts = contracts,
		rules = rules,
		limits = limits,
		vitals = vitals,
		tags = tags,
		items = items,
		recipes = recipes,
		nodes = nodes,
		structures = structures,
		wildlife = wildlife,
	}, {}
end

--- The catalog names a later mechanism is allowed to reference. Nothing here
--- asserts that the mechanism exists.
function M.catalogNames(): { string }
	return table.clone(CATALOGS)
end

return M
