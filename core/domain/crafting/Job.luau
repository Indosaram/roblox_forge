--!strict
-- Pure crafting transitions. Persist the returned job and inventory together.
local Content = require("../survival/Content")
local Catalog = require("../inventory/ItemCatalog")
local Inventory = require("../inventory/Inventory")
local M = {}

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

local function outputs(job: Job): { Inventory.Item }
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
	local quality =
		math.clamp(math.floor(weighted / total), job.content.limits.qualityMilliMin, job.content.limits.qualityMilliMax)
	local catalog = M.catalog(job.content)
	local result: { Inventory.Item } = {}
	for _, output in recipe(job.content, job.recipeId).outputs do
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
				attributes = copy(attributes),
			})
			remaining -= quantity
		end
	end
	return result
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
	now: number
): (Job?, Inventory.State?, string?)
	clock(now)
	assert(Catalog.identity(jobId) and #jobId <= 100 and Catalog.identity(revision), "INVALID_JOB_IDENTITY")
	local pinned = canonical(content)
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
	}
	job.outputs = outputs(job)
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
	result.saveVersion = 1
	return result
end

function M.fromSave(raw: any, inventory: Inventory.State): Job
	assert(type(raw) == "table" and raw.saveVersion == 1, "UNSUPPORTED_CRAFTING_SAVE")
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
	local required = {}
	for _, input in selected.inputs do
		required[input.item] = input.quantity
	end
	assert(same(totals, required), "INVALID_INPUTS")
	assert(same(result.outputs, outputs(result)), "INVALID_OUTPUTS")
	assert(agreement(result, inventory), "RESERVATION_MISMATCH")
	return result
end

return M
