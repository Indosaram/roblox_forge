--!strict
-- Detailed authored catalogs. Legacy content remains the executable v1 projection.
local Validation = require("../genre/Validation")
local CapacityPolicy = require("./CapacityPolicy")
local M = {}

-- Descriptor grammar: ? optional, [] dense collection, @ catalog reference.
-- Every object rejects unknown keys; all authored rows carry provenance.
local schemas: { [string]: { [string]: string } } = {
	provenance = { classification = "classification", sourceId = "?text" },
	effect = { id = "id", value = "number", unit = "text" },
	quantity = { item = "@items", quantity = "positive" },
	point = { x = "number", y = "number", z = "number" },
	bounds = { min = "point", max = "point" },
	anchor = { id = "id", position = "point" },
	landmark = { id = "id", kind = "text", position = "point", size = "point" },
	art = { landmark = "landmark" },
	gate = {
		characterLevel = "?level",
		developmentRank = "?integer",
		clanLevel = "?integer",
		requiresTerritory = "?boolean",
		capability = "?id",
		skillNodes = "?[]@skillNodes",
		completed = "?[]id",
	},
	objective = { id = "id", action = "text", target = "id", quantity = "positive", stageId = "?@stages" },
	rewards = {
		items = "?[]quantity",
		xp = "?integer",
		coins = "?integer",
		development = "?integer",
		reputation = "?[]effect",
	},
	resource = {
		id = "id",
		item = "@items",
		position = "point",
		stock = "positive",
		level = "level",
		yield = "positive",
		respawnSeconds = "positive",
		gates = "?gate",
		tool = "?@items",
	},
	spawn = {
		id = "id",
		speciesId = "@wildlife",
		position = "point",
		count = "positive",
		level = "level",
		radius = "number",
	},
	hazard = {
		id = "id",
		kind = "text",
		position = "point",
		radius = "positive",
		intensity = "number",
		effects = "[]effect",
	},
	refuge = { id = "id", bounds = "bounds" },
	path = { id = "id", points = "[]point", width = "positive" },
	attack = {
		id = "id",
		damage = "integer",
		windupSeconds = "number",
		range = "positive",
		recoverySeconds = "number",
		shape = "text",
	},
	drop = { item = "@items", quantity = "positive", skillNode = "?@skillNodes" },
	mount = {
		enabled = "boolean",
		cargoSlots = "integer",
		walkSpeed = "number",
		runSpeed = "number",
		stamina = "integer",
		effects = "[]effect",
	},
	attributes = {
		hardness = "attribute",
		flexibility = "attribute",
		sharpness = "attribute",
		insulation = "attribute",
		nutrition = "attribute",
		fertility = "attribute",
	},
	progressionTree = {
		maxLevel = "level",
		spPerLevel = "positive",
		maxMastery = "level",
		actionXP = "positive",
		xpBase = "positive",
		xpStep = "positive",
	},
	climateResistance = { cold = "number", heat = "number" },
	buffStrength = { resistance = "number", stamina = "number", recovery = "number" },
	volcano = {
		clearSeconds = "positive",
		stormSeconds = "positive",
		stormMultiplier = "positive",
		healthPerSecond = "number",
		fatiguePerSecond = "number",
		springRecovery = "number",
		bootsItem = "@items",
		bootsMultiplier = "number",
		lavaMaxHealthFraction = "number",
	},
	progressionPolicy = {
		combat = "?combatPolicy",
		companion = "?companionPolicy",
		volcano = "?volcano",
		tree = "progressionTree",
		sharpnessPerPoint = "number",
		insulationCold = "number",
		minimumWear = "number",
		flexibilityWear = "number",
		precision = "positive",
		maxVital = "positive",
		energyBase = "number",
		energyNutrition = "number",
		healthBase = "number",
		exposureHealth = "number",
		exposureFatigue = "number",
		buffSeconds = "positive",
		buffStrength = "buffStrength",
		feed = "mapBoolean",
		foodFamilies = "mapFamily",
		clothing = "mapClimate",
	},
	combatPolicy = {
		windupMillis = "positive",
		dodgeMillis = "positive",
		guardMillis = "positive",
		guardPermille = "integer",
		defenseRecoveryMillis = "positive",
	},
	companionPolicy = {
		capacity = "positive",
		feedItem = "@items",
		feedCount = "positive",
		trainingMillis = "positive",
		maxSatiety = "positive",
		feedSatiety = "positive",
		hungerMillis = "positive",
		downMillis = "positive",
		ropeItem = "@items",
		stunMillis = "positive",
		stunRecoveryMillis = "positive",
		stunRange = "positive",
		basePermille = "integer",
		levelPermille = "integer",
		bonusPermille = "integer",
		minPermille = "integer",
		maxPermille = "integer",
		seed = "integer",
	},
	homeTier = { rank = "positive", sideStuds = "positive", plotCap = "positive", development = "integer" },
	clanPolicy = {
		-- Shared policies remain opt-in for other packs.
		provenance = "provenance",
		maxMembers = "positive",
		maxLevel = "positive",
		missionExperience = "positive",
		levelExperience = "positive",
		hallLevel = "positive",
		cancelRefund = "number",
	},
	outpostPolicy = {
		provenance = "provenance",
		minTeam = "positive",
		maxTeam = "positive",
		matchSeconds = "positive",
		captureSeconds = "positive",
		ownershipSeconds = "positive",
	},
	musicVoice = {
		id = "id",
		frequency = "number",
		attack = "number",
		release = "number",
		decay = "number",
		harmonics = "[]number",
		noise = "number",
		gain = "number",
	},
	musicInstrument = {
		id = "id",
		assetKey = "text",
		attack = "?number",
		release = "?number",
		decay = "?number",
		harmonics = "?[]number",
		noise = "?number",
		gain = "?number",
		placed = "?boolean",
		pitchMin = "?positive",
		drums = "?[]musicVoice",
	},
	musicInstruments = {
		piano = "musicInstrument",
		guitar = "musicInstrument",
		bass = "musicInstrument",
		violin = "musicInstrument",
		flute = "musicInstrument",
		clarinet = "musicInstrument",
		trumpet = "musicInstrument",
		drums = "musicInstrument",
	},
	music = {
		maxBytes = "positive",
		tempoMin = "positive",
		tempoMax = "positive",
		maxParts = "positive",
		maxPerformers = "positive",
		maxNotesPerPart = "positive",
		ticksPerQuarter = "positive",
		maxDurationSeconds = "positive",
		maxPolyphony = "positive",
		pitchMin = "positive",
		pitchMax = "positive",
		velocityMin = "positive",
		velocityMax = "positive",
		radiusStuds = "positive",
		countdownSeconds = "positive",
		instruments = "musicInstruments",
	},
	brawlWeather = {
		at = "integer",
		id = "id",
		sprintMultiplier = "?number",
		rangeCap = "?positive",
		noMount = "?boolean",
	},
	brawlPolicy = {
		provenance = "provenance",
		layout = "@layouts",
		minimumLevel = "level",
		minimumPlayers = "positive",
		maximumPlayers = "positive",
		preparationSeconds = "positive",
		durationSeconds = "positive",
		collapseAt = "positive",
		initialRadius = "positive",
		outsideDamageFraction = "number",
		daySeconds = "positive",
		dailySettlements = "positive",
		participationReward = "integer",
		winReward = "integer",
		maximumBalance = "positive",
		weather = "[]brawlWeather",
		spawns = "[]point",
	},
	missionPolicy = {
		provenance = "provenance",
		surveySeconds = "positive",
		interactionStuds = "positive",
		escortSpeed = "positive",
		followStuds = "positive",
		stopStuds = "positive",
		cargoSlots = "positive",
		bandageOffset = "point",
		starterWeapon = "@items",
		weaponDamageMilli = "positive",
		weaponWearMilli = "positive",
		weaponRangeStuds = "positive",
		weaponCooldownMillis = "positive",
	},
	buildingKits = {
		floor = "@items",
		pillar = "@items",
		stairs = "@items",
	},
	buildingPolicy = {
		provenance = "provenance",
		cellStuds = "positive",
		stairSteps = "positive",
		kits = "buildingKits",
	},
	homePolicy = {
		provenance = "provenance",
		tiers = "[]homeTier",
		dock = "point",
		dockSize = "point",
		padSize = "point",
		structureSize = "point",
		baseSlots = "positive",
		labRank = "positive",
		floors = "[]integer",
	},
	skillCategories = { id = "id", provenance = "provenance", entryActions = "[]id", nameKey = "text" },
	skillNodes = {
		id = "id",
		provenance = "provenance",
		category = "@skillCategories",
		rank = "rank",
		cost = "positive",
		proficiency = "integer",
		prerequisites = "[]@skillNodes",
		effects = "[]effect",
	},
	materials = {
		id = "id",
		provenance = "provenance",
		item = "@items",
		attributes = "attributes",
		levels = "[]level",
		quality = "integer",
		processingBudget = "integer",
		sources = "[]id",
	},
	operations = {
		id = "id",
		provenance = "provenance",
		kind = "operationKind",
		inputs = "[]quantity",
		outputs = "[]quantity",
		seconds = "duration",
		gates = "?gate",
		station = "?@structures",
		stationTier = "?rank",
		effects = "[]effect",
		cost = "?integer",
		tier = "?integer",
		primaryMaterialLevel = "?materialLevel",
		primaryInputs = "?[]@items",
		auxiliaryInputs = "?[]@items",
		eligibleTags = "?[]id",
		targetConsumed = "?boolean",
	},
	recipeDetails = {
		id = "@recipes",
		provenance = "provenance",
		minCharacterLevel = "level",
		primaryMaterialLevel = "materialLevel",
		primaryInputs = "[]@items",
		auxiliaryInputs = "[]@items",
		stationTier = "?rank",
		skillNodes = "[]@skillNodes",
		seconds = "duration",
		sourceSpeciesId = "?@wildlife",
	},
	wildlifeDetails = {
		id = "@wildlife",
		renderEnvelope = "?point",
		riderHeight = "?number",
		provenance = "provenance",
		level = "level",
		health = "positive",
		damage = "integer",
		walkSpeed = "number",
		runSpeed = "number",
		biomes = "[]id",
		behaviour = "wildlifeBehaviour",
		sense = "positive",
		leash = "positive",
		attacks = "[]attack",
		dropReservoirs = "[]drop",
		captureClass = "captureClass",
		mount = "mount",
		effects = "?[]effect",
	},
	layouts = {
		id = "id",
		art = "?art",
		provenance = "provenance",
		bounds = "bounds",
		biomes = "[]id",
		anchors = "[]anchor",
		resourceNodes = "[]resource",
		spawns = "[]spawn",
		hazards = "[]hazard",
		refuges = "[]refuge",
		paths = "[]path",
		rotationDegrees = "?integer",
		mirrorX = "?boolean",
	},
	stages = {
		id = "id",
		provenance = "provenance",
		layout = "@layouts",
		gates = "gate",
		objectives = "[]objective",
		nextStage = "?@stages",
	},
	supportRegions = { id = "id", provenance = "provenance", layout = "@layouts", gates = "gate", role = "text" },
	missions = {
		id = "id",
		provenance = "provenance",
		gates = "gate",
		objectives = "[]objective",
		rewards = "rewards",
		dialogueKeys = "[]text",
	},
	guides = {
		id = "id",
		provenance = "provenance",
		gates = "gate",
		objectives = "[]objective",
		rewards = "rewards",
		dialogueKeys = "[]text",
	},
	chapters = {
		id = "id",
		provenance = "provenance",
		gates = "gate",
		objectives = "[]objective",
		rewards = "rewards",
		dialogueKeys = "[]text",
	},
}
M.SECTIONS = {
	"skillCategories",
	"skillNodes",
	"materials",
	"operations",
	"recipeDetails",
	"wildlifeDetails",
	"layouts",
	"stages",
	"supportRegions",
	"missions",
	"guides",
	"chapters",
}
M.POLICIES = {
	"progressionPolicy",
	"homePolicy",
	"buildingPolicy",
	"missionPolicy",
	"clanPolicy",
	"outpostPolicy",
	"brawlPolicy",
	"music",
}
local enums: { [string]: { string } } = {
	classification = { "CONFIRMED", "RECONSTRUCTED", "HISTORICAL_EVENT" },
	operationKind = {
		"practice",
		"instrument",
		"upgrade",
		"research",
		"modifier",
		"support-tier",
		"clan-research",
		"repair",
		"food",
		"processing",
	},
	wildlifeBehaviour = { "flee", "retaliate", "territorial", "predator" },
	captureClass = { "basic", "advanced", "never" },
}

--- Render contextual row types from the same descriptors used by validation.
--- Optional nested fields must not be inferred from the first array entry.
function M.types(): string
	local names = {}
	for name in schemas do
		table.insert(names, name)
	end
	table.sort(names)
	local resolve: (string) -> string
	resolve = function(descriptor: string): string
		if descriptor:sub(1, 1) == "?" then
			return resolve(descriptor:sub(2)) .. "?"
		elseif descriptor:sub(1, 2) == "[]" then
			return "{ " .. resolve(descriptor:sub(3)) .. " }"
		elseif descriptor == "mapBoolean" then
			return "{ [string]: boolean }"
		elseif descriptor == "mapFamily" then
			return "{ [string]: string }"
		elseif descriptor == "mapClimate" then
			return "{ [string]: V2_climateResistance }"
		elseif schemas[descriptor] then
			return "V2_" .. descriptor
		elseif descriptor:sub(1, 1) == "@" or enums[descriptor] or descriptor == "id" or descriptor == "text" then
			return "string"
		elseif descriptor == "boolean" then
			return "boolean"
		else
			return "number"
		end
	end
	local lines = {}
	for _, name in names do
		local keys = {}
		for key in schemas[name] do
			table.insert(keys, key)
		end
		table.sort(keys)
		local fields = {}
		for _, key in keys do
			table.insert(fields, key .. ": " .. resolve(schemas[name][key]))
		end
		table.insert(lines, "export type V2_" .. name .. " = { " .. table.concat(fields, ", ") .. " }")
	end
	return table.concat(lines, "\n")
end

function M.identity(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 256 and value:match("^[%a][%w%._%-]*$") ~= nil
end

function M.descriptor(name: string, key: string): string?
	return if schemas[name] then schemas[name][key] else nil
end

function M.isObject(name: string): boolean
	return schemas[name] ~= nil
end

function M.constructors(used: { [string]: boolean }): string
	local lines = {}
	for name in used do
		table.insert(
			lines,
			"local function v2_" .. name .. "(value: V2_" .. name .. "): V2_" .. name .. " return value end"
		)
	end
	table.sort(lines)
	return table.concat(lines, "\n")
end

function M.validate(raw: any): { string }
	local errors: { string } = {}
	local catalogs: { [string]: { [string]: boolean } } = {}
	for _, section in { "items", "recipes", "structures", "wildlife", table.unpack(M.SECTIONS) } do
		local ids: { [string]: boolean } = {}
		catalogs[section] = ids
		if Validation.dense(raw[section], 1024) then
			for _, row in raw[section] do
				if type(row) == "table" and type(row.id) == "string" then
					if ids[row.id] then
						table.insert(errors, section .. ": duplicate id " .. row.id)
					end
					ids[row.id] = true
				end
			end
		end
	end
	local function reject(at: string, message: string)
		table.insert(errors, at .. ": " .. message)
	end
	local check: (any, string, string) -> ()
	check = function(value: any, descriptor: string, at: string)
		if descriptor:sub(1, 1) == "?" then
			if value ~= nil then
				check(value, descriptor:sub(2), at)
			end
			return
		end
		if descriptor == "mapBoolean" or descriptor == "mapFamily" or descriptor == "mapClimate" then
			if type(value) ~= "table" then
				reject(at, "expected item policy mapping")
				return
			end
			for item, entry in value do
				if not catalogs.items[item] then
					reject(at, "unknown item reference " .. tostring(item))
				end
				if descriptor == "mapBoolean" then
					check(entry, "boolean", at .. "." .. tostring(item))
				elseif descriptor == "mapClimate" then
					check(entry, "climateResistance", at .. "." .. tostring(item))
				elseif entry ~= "stamina" and entry ~= "recovery" and entry ~= "resistance" then
					reject(at .. "." .. tostring(item), "expected stamina, recovery or resistance")
				end
			end
			return
		end
		if descriptor:sub(1, 2) == "[]" then
			if not Validation.dense(value, 1024) then
				reject(at, "expected dense list of at most 1024")
				return
			end
			local seen: { [string]: boolean } = {}
			for i, entry in value do
				check(entry, descriptor:sub(3), at .. "[" .. i .. "]")
				local id = if type(entry) == "table" then entry.id or entry.item else entry
				if type(id) == "string" then
					if seen[id] then
						reject(at, "duplicate id " .. id)
					end
					seen[id] = true
				end
			end
			return
		end
		if descriptor:sub(1, 1) == "@" then
			if type(value) ~= "string" or not catalogs[descriptor:sub(2)][value] then
				reject(at, "unknown " .. descriptor:sub(2) .. " reference " .. tostring(value))
			end
			return
		end
		local fields = schemas[descriptor]
		if fields then
			if type(value) ~= "table" then
				reject(at, "expected mapping")
				return
			end
			for key in value do
				if not fields[key] then
					reject(at, "unknown field " .. tostring(key))
				end
			end
			for key, field in fields do
				check(value[key], field, at .. "." .. key)
			end
			if
				descriptor == "provenance"
				and value.classification == "CONFIRMED"
				and (type(value.sourceId) ~= "string" or value.sourceId == "")
			then
				reject(at, "CONFIRMED requires sourceId; authored reconstruction must remain RECONSTRUCTED")
			end
			if descriptor == "bounds" and type(value.min) == "table" and type(value.max) == "table" then
				for _, axis in { "x", "y", "z" } do
					if
						Validation.finite(value.min[axis])
						and Validation.finite(value.max[axis])
						and value.min[axis] > value.max[axis]
					then
						reject(at, "min must not exceed max")
					end
				end
			end
			if
				descriptor == "mount"
				and Validation.finite(value.cargoSlots)
				and Validation.finite(value.walkSpeed)
				and Validation.finite(value.runSpeed)
				and Validation.finite(value.stamina)
			then
				if
					value.cargoSlots > CapacityPolicy.forVersion(2).homeSlots
					or value.walkSpeed < 0
					or value.runSpeed < 1
					or value.runSpeed > 200
					or value.walkSpeed > value.runSpeed
					or value.stamina < 1
					or value.stamina > 1000000
				then
					reject(at, "invalid mount policy bounds")
				end
			end
			return
		end
		if enums[descriptor] then
			if not table.find(enums[descriptor], value) then
				reject(at, "expected " .. table.concat(enums[descriptor], " | "))
			end
		elseif descriptor == "boolean" then
			if type(value) ~= "boolean" then
				reject(at, "expected boolean")
			end
		elseif descriptor == "id" or descriptor == "text" then
			if
				type(value) ~= "string"
				or #value == 0
				or #value > 256
				or (descriptor == "id" and not M.identity(value))
			then
				reject(at, "expected " .. descriptor)
			end
		else
			local high = if descriptor == "level" or descriptor == "materialLevel"
				then 60
				elseif descriptor == "rank" then 6
				elseif descriptor == "attribute" then 10
				else 1000000000
			local low = if descriptor == "positive"
					or descriptor == "duration"
					or descriptor == "level"
					or descriptor == "rank"
				then 1
				elseif descriptor == "number" then -1000000000
				else 0
			if
				not Validation.finite(value)
				or value < low
				or value > high
				or (descriptor ~= "number" and descriptor ~= "duration" and value % 1 ~= 0)
			then
				reject(at, "expected " .. descriptor .. " " .. low .. ".." .. high)
			end
		end
	end
	for _, section in M.SECTIONS do
		if raw[section] ~= nil then
			check(raw[section], "[]" .. section, section)
		end
	end
	for _, policy in M.POLICIES do
		if raw[policy] ~= nil then
			check(raw[policy], policy, policy)
		end
	end
	-- Node prerequisite graphs must be acyclic, including self-dependencies.
	local nodes: { [string]: any } = {}
	for _, node in if Validation.dense(raw.skillNodes, 1024) then raw.skillNodes else {} do
		if type(node) == "table" and type(node.id) == "string" then
			nodes[node.id] = node
		end
	end
	local visiting: { [string]: boolean } = {}
	local done: { [string]: boolean } = {}
	local visit: (string) -> ()
	visit = function(id: string)
		if visiting[id] then
			reject("skillNodes", "prerequisite cycle " .. id)
			return
		end
		if done[id] then
			return
		end
		visiting[id] = true
		local node = nodes[id]
		if node and Validation.dense(node.prerequisites, 1024) then
			for _, prerequisite in node.prerequisites do
				if nodes[prerequisite] then
					visit(prerequisite)
				end
			end
		end
		visiting[id] = nil
		done[id] = true
	end
	for id in nodes do
		visit(id)
	end
	if #errors == 0 then
		if raw.skillCategories and #raw.skillCategories > 12 then
			reject("skillCategories", "expected at most 12 categories")
		end
		local ranks: { [string]: { [number]: boolean } } = {}
		for _, node in raw.skillNodes or {} do
			local category = ranks[node.category] or {}
			ranks[node.category] = category
			if category[node.rank] then
				reject("skillNodes", "duplicate category rank " .. node.category .. ":" .. node.rank)
			end
			category[node.rank] = true
		end
		local recipes: { [string]: any } = {}
		for _, recipe in raw.recipes or {} do
			if type(recipe) == "table" and type(recipe.id) == "string" then
				recipes[recipe.id] = recipe
			end
		end
		for _, detail in raw.recipeDetails or {} do
			local recipe = recipes[detail.id]
			if recipe and type(recipe.craftMillis) == "number" and detail.seconds * 1000 ~= recipe.craftMillis then
				reject("recipeDetails." .. detail.id, "seconds must equal recipe craftMillis / 1000")
			end
			if detail.stationTier and (not recipe or not recipe.station) then
				reject("recipeDetails." .. detail.id, "stationTier requires recipe station")
			end
			local inputs: { [string]: boolean } = {}
			for _, input in if recipe and type(recipe.inputs) == "table" then recipe.inputs else {} do
				if type(input) == "table" and type(input.item) == "string" then
					inputs[input.item] = true
				end
			end
			local assigned: { [string]: boolean } = {}
			for _, item in detail.primaryInputs do
				if not inputs[item] then
					reject("recipeDetails." .. detail.id, "primary input is not a recipe ingredient " .. item)
				end
				assigned[item] = true
			end
			for _, item in detail.auxiliaryInputs do
				if not inputs[item] or assigned[item] then
					reject("recipeDetails." .. detail.id, "invalid or overlapping auxiliary ingredient " .. item)
				end
				assigned[item] = true
			end
			for item in inputs do
				if not assigned[item] then
					reject("recipeDetails." .. detail.id, "unclassified recipe ingredient " .. item)
				end
			end
		end
	end
	table.sort(errors)
	return errors
end

-- Preserve sequence semantics for paths/dialogue; sort identity collections and sets.
function M.canonical(value: any, field: string?): any
	if type(value) ~= "table" then
		return value
	end
	local result: any = {}
	for key, entry in value do
		result[key] = M.canonical(entry, tostring(key))
	end
	if #result > 0 and field ~= "points" and field ~= "dialogueKeys" then
		if field == "weather" then
			table.sort(result, function(a: any, b: any)
				return a.at < b.at
			end)
		elseif type(result[1]) == "table" and (result[1].id or result[1].item) then
			table.sort(result, function(a: any, b: any)
				return (a.id or a.item) < (b.id or b.item)
			end)
		elseif type(result[1]) == "string" or type(result[1]) == "number" then
			table.sort(result)
		end
	end
	return result
end

return M
