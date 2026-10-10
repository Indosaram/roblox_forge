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
export type Recipe = {
	id: string,
	craftMillis: number,
	inputs: { Quantity },
	outputs: { Quantity },
	station: string?,
	requiredToolTag: string?,
}
export type Node = { id: string, harvest: { Quantity }, respawnMillis: number }
export type Structure = {
	id: string,
	footprintX: number,
	footprintZ: number,
	station: boolean,
	cost: { Quantity },
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
}
export type Document = {
	version: number,
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
		unknown(errors, at, entry, { "id", "footprintX", "footprintZ", "station", "cost" })
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
		unknown(errors, at, recipe, { "id", "craftMillis", "inputs", "outputs", "station", "requiredToolTag" })
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
		quantities(errors, at .. ".inputs", recipe.inputs, items)
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
		local allowed = { "id", "behavior" }
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
		if entry.behavior ~= "grazer" and entry.behavior ~= "hunter" then
			table.insert(errors, at .. ".behavior: expected grazer|hunter")
			continue
		end
		local own: { string } = if entry.behavior == "grazer" then GRAZER_FIELDS else HUNTER_FIELDS
		local foreign: { string } = if entry.behavior == "grazer" then HUNTER_FIELDS else GRAZER_FIELDS
		for _, field in foreign do
			if entry[field] ~= nil then
				table.insert(errors, string.format("%s.%s: not valid for %s", at, field, entry.behavior))
			end
		end
		local resolved: { [string]: number } = {}
		for _, field in own do
			local value = if entry[field] == nil then WILDLIFE_DEFAULTS[entry.behavior][field] else entry[field]
			local cap = if string.match(field, "Millis$") then CAPS.millis else CAPS.studs
			if not isInt(value, 1, cap) then
				table.insert(errors, string.format("%s.%s: expected integer 1..%d", at, field, cap))
			else
				resolved[field] = value
			end
		end
		if entry.behavior == "grazer" then
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
		})
	end
	sortById(structures)
	local wildlife: { Wildlife } = {}
	local rawWildlife: { any } = raw.wildlife or {}
	for _, entry in rawWildlife do
		local resolved: Wildlife = { id = entry.id, behavior = entry.behavior }
		local fields: { string } = if entry.behavior == "grazer" then GRAZER_FIELDS else HUNTER_FIELDS
		for _, field in fields do
			(resolved :: any)[field] = if entry[field] == nil
				then WILDLIFE_DEFAULTS[entry.behavior][field]
				else entry[field]
		end
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
	return {
		version = M.VERSION,
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
