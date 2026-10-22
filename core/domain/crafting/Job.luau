--!strict
-- Pure crafting transitions. Persist the returned job and inventory together.
local Content = require("../survival/Content")
local Catalog = require("../inventory/ItemCatalog")
local Inventory = require("../inventory/Inventory")
local Rng = require("../random/Rng")
local MaterialGrowth = require("./MaterialGrowth")
local M = {}

--- Free-play roll odds (permille). Purchases never change these: rolls read
--- only the recorded seed, the job id and the inputs (QA-BM-02).
M.CRIT_PERMILLE = 50
M.CRIT_BONUS_MILLI = 1000
M.LATENT_PERMILLE = 200

-- Recorded inputs of the free random rolls. `masteryCapMilli` caps the
-- material-average quality (mastery step); the crit bonus applies after it.
export type Roll = { seed: number, masteryCapMilli: number }
export type Options = {
	seed: number,
	masteryCapMilli: number?,
	-- Accepted so callers can pass ownership state through unchanged; never read.
	entitlements: { [string]: any }?,
}

export type Job = {
	id: string,
	containerId: string,
	catalogRevision: string,
	content: Content.Document,
	recipeId: string,
	state: string,
	reservedAt: number,
	startedAt: number?,
	finishAt: number?,
	inputs: { Inventory.Item },
	outputs: { Inventory.Item },
	roll: Roll?,
	critical: boolean?,
}

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

local function same(left: any, right: any): boolean
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end
	for key, value in left do
		if not same(value, right[key]) then
			return false
		end
	end
	for key in right do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function clock(now: number)
	assert(Catalog.integer(now, 0, 2 ^ 53 - 1 - Content.CAPS.millis), "INVALID_CLOCK")
end

local function recipe(content: Content.Document, id: string): Content.Recipe
	for _, entry in content.recipes do
		if entry.id == id then
			return entry
		end
	end
	error("UNKNOWN_RECIPE")
end

local function canonical(content: Content.Document): Content.Document
	local raw = copy(content)
	raw.survival_content = raw.version
	raw.version = nil
	local result, errors = Content.canonicalize(raw)
	assert(result, table.concat(errors, "; "))
	return result
end

function M.catalog(content: Content.Document): Catalog.Catalog
	local definitions: { Catalog.Definition } = {}
	for _, item in content.items do
		table.insert(definitions, {
			id = item.id,
			stackMax = item.stackMax,
			weightMilli = item.weightMilli,
			maxDurabilityMilli = item.maxDurabilityMilli,
		})
	end
	return Catalog.new(definitions)
end

local function outputs(job: Job): ({ Inventory.Item }, boolean)
	local total, weighted = 0, 0
	local attributes = copy(job.inputs[1].attributes)
	for _, input in job.inputs do
		total += input.quantity
		weighted += input.quantity * input.qualityMilli
		local keys: { string } = {}
		for key in attributes do
			table.insert(keys, key)
		end
		table.sort(keys)
		for _, key in keys do
			if input.attributes[key] ~= attributes[key] then
				attributes[key] = nil
			end
		end
	end
	local limits = job.content.limits
	local quality = math.clamp(math.floor(weighted / total), limits.qualityMilliMin, limits.qualityMilliMax)
	local selected = recipe(job.content, job.recipeId)
	local latent: string? = nil
	local critical = false
	local roll = job.roll
	if roll then
		quality = math.max(limits.qualityMilliMin, math.min(quality, roll.masteryCapMilli))
		local stream = Rng.new(roll.seed):fork("job:" .. job.id)
		critical = stream:fork("craft-crit"):nextInteger(1, 1000) <= M.CRIT_PERMILLE
		if critical then
			quality = math.min(quality + M.CRIT_BONUS_MILLI, limits.qualityMilliMax)
		end
		local pool = selected.latents
		if pool then
			local latentStream = stream:fork("latent")
			if latentStream:nextInteger(1, 1000) <= M.LATENT_PERMILLE then
				latent = pool[latentStream:nextInteger(1, #pool)]
			end
		end
	end
	local catalog = M.catalog(job.content)
	local material: any = nil
	if (job.content :: any).progressionPolicy then
		local inputs = {}
		local recorded = true
		for _, input in job.inputs do
			if not input.material then
				recorded = false
				break
			end
			local value = MaterialGrowth.copy(input.material)
			value.quantity = input.quantity
			table.insert(inputs, value)
		end
		if recorded then
			material = MaterialGrowth.craft(job.content, job.recipeId, inputs)
		end
	end
	local result: { Inventory.Item } = {}
	for _, output in selected.outputs do
		local definition = catalog[output.item]
		local remaining = output.quantity
		while remaining > 0 do
			local quantity = math.min(remaining, definition.stackMax)
			table.insert(result, {
				itemId = job.id .. ":output:" .. tostring(#result + 1),
				catalogId = output.item,
				quantity = quantity,
				qualityMilli = quality,
				durabilityMilli = math.floor((definition.maxDurabilityMilli or 0) * quality / 1000),
				latent = latent,
				attributes = copy(attributes),
				material = if material and material.item == output.item then MaterialGrowth.copy(material) else nil,
			})
			remaining -= quantity
		end
	end
	return result, critical
end

local function tagged(content: Content.Document, catalogId: string, tag: string): boolean
	for _, item in content.items do
		if item.id == catalogId then
			return table.find(item.tags, tag) ~= nil
		end
	end
	return false
end

-- A tag slot accepts an item carrying the tag at or above the minimum grade.
local function eligible(content: Content.Document, slot: Content.Slot, item: Inventory.Item): boolean
	return tagged(content, item.catalogId, slot.tag) and Catalog.grade(item.qualityMilli) >= slot.minGrade
end

--- Workbench tier a station kind provides (structures default to tier 1).
function M.stationTier(content: Content.Document, kind: string?): number
	for _, structure in content.structures do
		if structure.id == kind then
			return structure.tier or 1
		end
	end
	return 0
end

local function agreement(job: Job, inventory: Inventory.State): boolean
	if inventory.id ~= job.containerId then
		return false
	end
	local reservation = inventory.reservations[job.id]
	if job.state == "Committed" or job.state == "Cancelled" then
		return reservation == nil
	end
	if not reservation then
		return false
	end
	local quantities = {}
	for _, input in job.inputs do
		local actual = inventory.items[input.itemId]
		if not actual or not Inventory.compatible(input, actual) or actual.quantity < input.quantity then
			return false
		end
		quantities[input.itemId] = input.quantity
	end
	return same(quantities, reservation)
end

function M.snapshot(job: Job): Job
	return copy(job)
end

function M.reserve(
	inventory: Inventory.State,
	content: Content.Document,
	revision: string,
	recipeId: string,
	jobId: string,
	now: number,
	options: Options?
): (Job?, Inventory.State?, string?)
	clock(now)
	assert(Catalog.identity(jobId) and #jobId <= 100 and Catalog.identity(revision), "INVALID_JOB_IDENTITY")
	local roll: Roll? = nil
	if options then
		local cap = options.masteryCapMilli or content.limits.qualityMilliMax
		assert(Catalog.integer(options.seed, 0, 2 ^ 53 - 1), "INVALID_CRAFT_SEED")
		assert(Catalog.integer(cap, 1, 5000), "INVALID_MASTERY_CAP")
		roll = { seed = options.seed, masteryCapMilli = cap }
	end
	-- Pin only the catalogs a job can consume. World geometry and mission rows
	-- otherwise get copied into every retained job and revalidated on every
	-- personal inventory refresh, making a short craft grow with the whole world.
	local source: any = content
	if content.version == 2 then
		source = table.clone(content)
		for _, key in
			{
				"layouts",
				"stages",
				"supportRegions",
				"missions",
				"guides",
				"chapters",
				"wildlifeDetails",
				"homePolicy",
				"missionPolicy",
				"brawlPolicy",
				"clanPolicy",
				"outpostPolicy",
				"music",
				"contracts",
				"camp",
				"nodes",
				"skills",
				"vitals",
			}
		do
			source[key] = nil
		end
		source.recipes = { recipe(content, recipeId) }
		source.recipeDetails = {}
		for _, detail in (content :: any).recipeDetails or {} do
			if detail.id == recipeId then
				table.insert(source.recipeDetails, detail)
			end
		end
		local needed = {}
		local function include(id: string)
			if needed[id] then
				return
			end
			needed[id] = true
			for _, node in (content :: any).skillNodes or {} do
				if node.id == id then
					for _, prerequisite in node.prerequisites do
						include(prerequisite)
					end
				end
			end
		end
		for _, detail in source.recipeDetails do
			for _, id in detail.skillNodes do
				include(id)
			end
		end
		source.skillNodes = {}
		for _, node in (content :: any).skillNodes or {} do
			if needed[node.id] then
				table.insert(source.skillNodes, node)
			end
		end
		source.skillCategories = {}
		for _, category in (content :: any).skillCategories or {} do
			for _, node in source.skillNodes do
				if node.category == category.id then
					table.insert(source.skillCategories, category)
					break
				end
			end
		end
		source.operations = {}
		local process = string.match(recipeId, "^([a-z]+)%-")
		for _, operation in (content :: any).operations or {} do
			if operation.id == "processing-policy-" .. tostring(process) then
				table.insert(source.operations, operation)
			end
		end
		source.materials = {}
		for _, material in (content :: any).materials or {} do
			for _, input in source.recipes[1].inputs do
				if material.item == input.item then
					table.insert(source.materials, material)
				end
			end
		end
		source.structures = {}
		for _, structure in content.structures do
			if structure.id == source.recipes[1].station then
				table.insert(source.structures, structure)
			end
		end
		source.wildlife = {}
		local wildlife: { Content.Wildlife } = content.wildlife or {}
		for _, species in wildlife do
			for _, detail in source.recipeDetails do
				if detail.sourceSpeciesId == species.id then
					table.insert(source.wildlife, species)
				end
			end
		end
		-- Completion measures the entire bag, including items acquired while
		-- the job runs, so the item catalog must remain complete.
		if source.progressionPolicy then
			source.progressionPolicy = table.clone(source.progressionPolicy)
			source.progressionPolicy.companion, source.progressionPolicy.volcano = nil, nil
			source.progressionPolicy.feed = {}
			source.progressionPolicy.foodFamilies = {}
			source.progressionPolicy.clothing = {}
		end
	end
	local pinned = canonical(source)
	local selected = recipe(pinned, recipeId)
	local ids: { string } = {}
	for id in inventory.items do
		table.insert(ids, id)
	end
	table.sort(ids)
	local quantities = {}
	local inputs: { Inventory.Item } = {}
	for _, required in selected.inputs do
		local remaining = required.quantity
		for _, id in ids do
			local item = inventory.items[id]
			if item.catalogId == required.item and remaining > 0 then
				local amount = math.min(remaining, Inventory.available(inventory, id))
				if amount > 0 then
					local input = copy(item)
					input.quantity = amount
					table.insert(inputs, input)
					quantities[id] = amount
					remaining -= amount
				end
			end
		end
		if remaining > 0 then
			return nil, nil, "MISSING_INPUTS"
		end
	end
	-- Tag slots draw, in canonical slot order, from ascending item ids.
	for _, slot in (selected.slots or {}) :: { Content.Slot } do
		local remaining = slot.quantity
		for _, id in ids do
			local item = inventory.items[id]
			if remaining > 0 and eligible(pinned, slot, item) then
				local amount = math.min(remaining, Inventory.available(inventory, id) - (quantities[id] or 0))
				if amount > 0 then
					local input = copy(item)
					input.quantity = amount
					table.insert(inputs, input)
					quantities[id] = (quantities[id] or 0) + amount
					remaining -= amount
				end
			end
		end
		if remaining > 0 then
			return nil, nil, "MISSING_INPUTS"
		end
	end
	-- One input entry per inventory item, even when two requirements share it.
	local merged: { [string]: Inventory.Item } = {}
	for _, input in inputs do
		local existing = merged[input.itemId]
		if existing then
			existing.quantity += input.quantity
		else
			merged[input.itemId] = input
		end
	end
	inputs = {}
	for _, input in merged do
		table.insert(inputs, input)
	end
	table.sort(inputs, function(a, b)
		return a.itemId < b.itemId
	end)
	local reserved, err = Inventory.reserve(inventory, jobId, quantities, inventory.version)
	if not reserved then
		return nil, nil, err
	end
	local job: Job = {
		id = jobId,
		containerId = inventory.id,
		catalogRevision = revision,
		content = pinned,
		recipeId = recipeId,
		state = "Reserved",
		reservedAt = now,
		inputs = inputs,
		outputs = {},
		roll = roll,
	}
	local produced, critical = outputs(job)
	job.outputs = produced
	job.critical = if roll then critical else nil
	return job, reserved, nil
end

function M.start(job: Job, now: number): Job
	clock(now)
	local result = M.snapshot(job)
	if result.state == "Reserved" then
		assert(now >= result.reservedAt, "CLOCK_REGRESSION")
		result.state = "Running"
		result.startedAt = now
		result.finishAt = now + recipe(result.content, result.recipeId).craftMillis
	end
	return result
end

function M.advance(job: Job, now: number): Job
	clock(now)
	local result = M.snapshot(job)
	if result.state == "Running" and now >= (result.finishAt :: number) then
		result.state = "Ready"
	end
	return result
end

function M.complete(job: Job, inventory: Inventory.State, now: number): (Job, Inventory.State, string?)
	local result = M.advance(job, now)
	local unchanged = Inventory.snapshot(inventory)
	if not agreement(result, inventory) then
		return result, unchanged, "RESERVATION_MISMATCH"
	end
	if result.state == "Committed" then
		return result, unchanged, nil
	elseif result.state ~= "Ready" then
		return result, unchanged, "NOT_READY"
	end
	local exchanged, err =
		Inventory.exchange(inventory, M.catalog(result.content), result.id, result.outputs, inventory.version)
	if not exchanged then
		return result, unchanged, err
	end
	result.state = "Committed"
	return result, exchanged, nil
end

function M.cancel(job: Job, inventory: Inventory.State): (Job, Inventory.State, string?)
	local result, unchanged = M.snapshot(job), Inventory.snapshot(inventory)
	if not agreement(result, inventory) then
		return result, unchanged, "RESERVATION_MISMATCH"
	elseif result.state == "Committed" then
		return result, unchanged, "ALREADY_COMMITTED"
	elseif result.state == "Cancelled" then
		return result, unchanged, nil
	end
	local released, err = Inventory.release(inventory, result.id, inventory.version)
	if not released then
		return result, unchanged, err
	end
	result.state = "Cancelled"
	return result, released, nil
end

function M.save(job: Job): any
	local result: any = M.snapshot(job)
	-- Version 2 carries the recorded roll; rolls never apply to version 1 jobs.
	result.saveVersion = if job.roll then 2 else 1
	return result
end

--- Coin cost of one repair: the operation's base `cost` times the item tier (the `-tN` id
--- suffix; untiered gear counts as tier 1). A recurring Coin sink, never Robux.
function M.repairCost(operation: any, catalogId: string): number
	local tier = tonumber(string.match(catalogId, "%-t(%d+)$")) or 1
	return (operation.cost or 0) * tier
end

--- Repairs one unreserved item in place: durability refills to a permanently
--- lowered maximum (ItemCatalog.REPAIR_LOSS_PERMILLE per repair).
function M.repair(
	inventory: Inventory.State,
	catalog: Catalog.Catalog,
	itemId: string,
	expected: number
): (Inventory.State?, string?)
	if expected ~= inventory.version then
		return nil, "STALE_VERSION"
	end
	local item = inventory.items[itemId]
	if not item then
		return nil, "UNKNOWN_ITEM"
	elseif Inventory.available(inventory, itemId) ~= item.quantity then
		return nil, "ITEM_RESERVED"
	end
	local maximum, err = Catalog.repaired(catalog[item.catalogId], item)
	if not maximum then
		return nil, err
	end
	local result = Inventory.snapshot(inventory)
	result.items[itemId].maxDurabilityMilli = maximum
	result.items[itemId].durabilityMilli = maximum
	result.version += 1
	return result, nil
end

function M.fromSave(raw: any, inventory: Inventory.State): Job
	assert(
		type(raw) == "table" and (raw.saveVersion == 1 and raw.roll == nil or raw.saveVersion == 2),
		"UNSUPPORTED_CRAFTING_SAVE"
	)
	if raw.saveVersion == 2 then
		assert(
			type(raw.roll) == "table"
				and Catalog.integer(raw.roll.seed, 0, 2 ^ 53 - 1)
				and Catalog.integer(raw.roll.masteryCapMilli, 1, 5000)
				and type(raw.critical) == "boolean",
			"INVALID_CRAFT_ROLL"
		)
	end
	assert(
		Catalog.identity(raw.id) and #raw.id <= 100 and Catalog.identity(raw.catalogRevision),
		"INVALID_JOB_IDENTITY"
	)
	assert(table.find({ "Reserved", "Running", "Ready", "Committed", "Cancelled" }, raw.state), "INVALID_JOB_STATE")
	clock(raw.reservedAt)
	local restored = copy(raw)
	restored.saveVersion = nil
	local result: Job = restored
	result.content = canonical(result.content)
	local selected = recipe(result.content, result.recipeId)
	if result.state == "Reserved" then
		assert(result.startedAt == nil and result.finishAt == nil, "INVALID_DEADLINE")
	elseif result.state ~= "Cancelled" or result.startedAt ~= nil then
		clock(result.startedAt :: number)
		assert(
			(result.startedAt :: number) >= result.reservedAt
				and result.finishAt == (result.startedAt :: number) + selected.craftMillis,
			"INVALID_DEADLINE"
		)
	else
		assert(result.finishAt == nil, "INVALID_DEADLINE")
	end
	assert(type(result.inputs) == "table" and #result.inputs > 0, "INVALID_INPUTS")
	local totals = {}
	local previous = ""
	for _, input in result.inputs do
		assert(Catalog.identity(input.itemId) and input.itemId > previous, "INVALID_INPUT_ORDER")
		assert(
			Catalog.integer(input.quantity, 1, 1000) and Catalog.integer(input.qualityMilli, 1, 5000),
			"INVALID_INPUT"
		)
		previous = input.itemId
		totals[input.catalogId] = (totals[input.catalogId] or 0) + input.quantity
	end
	-- Fixed inputs are matched by catalog id; the rest must fill the tag slots.
	local slotted = 0
	for _, slot in (selected.slots or {}) :: { Content.Slot } do
		slotted += slot.quantity
	end
	for _, input in selected.inputs do
		totals[input.item] = (totals[input.item] or 0) - input.quantity
	end
	local spare = 0
	for catalogId, amount in totals do
		assert(amount >= 0, "INVALID_INPUTS")
		spare += amount
		if amount > 0 then
			local accepted = false
			for _, input in result.inputs do
				if input.catalogId == catalogId then
					for _, slot in (selected.slots or {}) :: { Content.Slot } do
						accepted = accepted or eligible(result.content, slot, input)
					end
				end
			end
			assert(accepted, "INVALID_INPUTS")
		end
	end
	assert(spare == slotted, "INVALID_INPUTS")
	local expectedOutputs, critical = outputs(result)
	assert(same(result.outputs, expectedOutputs), "INVALID_OUTPUTS")
	assert(result.critical == (if result.roll then critical else nil), "INVALID_OUTPUTS")
	assert(agreement(result, inventory), "RESERVATION_MISMATCH")
	return result
end

return M
