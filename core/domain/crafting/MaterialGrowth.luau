--!strict
-- Selected, consumed primary units determine inherited properties. Auxiliary
-- units meet costs but never raise material level, quality or attributes.
local Rng = require("../random/Rng")
local M = {}

export type Material = {
	item: string,
	quantity: number,
	level: number,
	quality: number,
	budget: number,
	attributes: { [string]: number },
	history: string,
	sourceSpeciesId: string?,
}

function M.copy(material: Material): Material
	local result = table.clone(material)
	result.attributes = table.clone(material.attributes)
	return result
end

function M.raw(content: any, item: string, level: number, quality: number, species: string?): Material
	assert(quality % 1 == 0 and quality >= 0 and quality <= 3, "INVALID_MATERIAL_QUALITY")
	for _, profile in content.materials do
		if profile.item == item then
			assert(table.find(profile.levels, level), "INVALID_MATERIAL_LEVEL")
			assert(species == nil or table.find(profile.sources, species), "INVALID_MATERIAL_ORIGIN")
			return {
				item = item,
				quantity = 1,
				level = level,
				quality = quality,
				budget = profile.processingBudget,
				attributes = table.clone(profile.attributes),
				history = "",
				sourceSpeciesId = species,
			}
		end
	end
	error("UNKNOWN_MATERIAL")
end

local function find(rows: { any }, id: string): any
	for _, row in rows do
		if row.id == id then
			return row
		end
	end
	return nil
end

function M.recipe(content: any, id: string): (any, any)
	local row = find(content.recipes, id)
	if row then
		return row, find(content.recipeDetails, id)
	end
	row = find(content.operations, id)
	return row, row
end

-- This computes a candidate only. Its owner commits input consumption and all
-- outputs together; a rejected candidate must never debit inventory.
function M.craft(content: any, id: string, inputs: { Material }): (Material?, string?)
	local row, detail = M.recipe(content, id)
	if not row or not detail or #row.outputs == 0 or #row.inputs == 0 then
		return nil, "UNKNOWN_RECIPE"
	end
	local counts: { [string]: number } = {}
	for _, input in inputs do
		if input.quantity < 1 or input.quantity % 1 ~= 0 then
			return nil, "INVALID_QUANTITY"
		end
		counts[input.item] = (counts[input.item] or 0) + input.quantity
	end
	for _, required in row.inputs do
		if counts[required.item] ~= required.quantity then
			return nil, "INPUT_MISMATCH"
		end
		counts[required.item] = nil
	end
	if next(counts) then
		return nil, "INPUT_MISMATCH"
	end
	local weight, level, quality, budget = 0, 0, math.huge, math.huge
	local attributes: { [string]: number } = {}
	local history = {}
	local species: string? = nil
	local sameSpecies = true
	for _, input in inputs do
		if table.find(detail.primaryInputs or {}, input.item) then
			if input.level < (detail.primaryMaterialLevel or 0) then
				return nil, "MATERIAL_LEVEL_GATE"
			end
			if detail.sourceSpeciesId then
				for _, profile in content.materials do
					if
						profile.item == input.item
						and table.find(profile.sources, detail.sourceSpeciesId)
						and input.sourceSpeciesId ~= detail.sourceSpeciesId
					then
						return nil, "SOURCE_SPECIES_GATE"
					end
				end
			end
			if weight == 0 then
				species = input.sourceSpeciesId
			elseif species ~= input.sourceSpeciesId then
				sameSpecies = false
			end
			weight += input.quantity
			level += input.level * input.quantity
			quality = math.min(quality, input.quality)
			budget = math.min(budget, input.budget)
			for key, value in input.attributes do
				attributes[key] = (attributes[key] or 0) + value * input.quantity
			end
			table.insert(history, input.item .. "(" .. input.history .. ")x" .. tostring(input.quantity))
		end
	end
	if weight == 0 then
		return nil, "NO_PRIMARY_MATERIAL"
	end
	for key, value in attributes do
		attributes[key] = math.floor(value / weight)
	end
	local process = string.match(id, "^([a-z]+)%-")
	local policy = find(content.operations, "processing-policy-" .. tostring(process))
	if policy then
		for _, effect in policy.effects do
			if effect.id == "processing-budget-consumed" then
				if budget < effect.value then
					return nil, "PROCESSING_BUDGET"
				end
				budget -= effect.value
			elseif effect.unit == "attribute-clamp-0-10" then
				attributes[effect.id] = math.clamp((attributes[effect.id] or 0) + effect.value, 0, 10)
			end
		end
	end
	table.sort(history)
	return {
		item = row.outputs[1].item,
		quantity = row.outputs[1].quantity,
		level = math.floor(level / weight),
		quality = quality,
		budget = budget,
		attributes = attributes,
		history = id .. ":" .. table.concat(history, ";"),
		sourceSpeciesId = if sameSpecies then species else nil,
	},
		nil
end

-- Mastery is free-currency gameplay randomness, one stable fork per consumed
-- primary unit. Cancellation returns must be excluded by the transaction owner.
function M.refunds(
	inputs: { Material },
	primary: { string },
	probability: number,
	seed: number,
	receipt: string
): { [string]: number }
	local result: { [string]: number } = {}
	local stream = Rng.new(seed):fork(receipt)
	for index, input in inputs do
		if table.find(primary, input.item) then
			for unit = 1, input.quantity do
				if stream:fork(tostring(index) .. ":" .. tostring(unit)):nextNumber() < probability then
					result[input.item] = (result[input.item] or 0) + 1
				end
			end
		end
	end
	return result
end

return M
