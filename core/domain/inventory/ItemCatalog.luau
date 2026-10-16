--!strict
-- Catalog data is copied at the boundary; all numeric units are integers.
local M = {}

export type Definition = {
	id: string,
	stackMax: number,
	weightMilli: number,
	maxDurabilityMilli: number?,
}
export type Catalog = { [string]: Definition }
-- Per-instance fields carried by every inventory item. `maxDurabilityMilli`
-- is absent until a repair lowers it below the quality-derived ceiling.
export type Instance = {
	qualityMilli: number,
	durabilityMilli: number,
	maxDurabilityMilli: number?,
	latent: string?,
}

--- Permille of the current maximum lost permanently by each repair.
M.REPAIR_LOSS_PERMILLE = 100

function M.integer(value: any, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value >= minimum and value <= maximum and value % 1 == 0
end

function M.identity(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128
end

--- 1..5 star grade of a quality value (1000 milli per grade).
function M.grade(qualityMilli: number): number
	return math.clamp(math.floor(qualityMilli / 1000), 1, 5)
end

--- Quality-derived durability ceiling of a fresh instance.
function M.durabilityCeiling(definition: Definition, qualityMilli: number): number
	return math.floor((definition.maxDurabilityMilli or 0) * qualityMilli / 1000)
end

--- Current maximum durability of an instance (repairs lower it permanently).
function M.maxDurability(definition: Definition, item: Instance): number
	return item.maxDurabilityMilli or M.durabilityCeiling(definition, item.qualityMilli)
end

--- Valid instance fields for `definition`; attributes are checked by the caller.
function M.validInstance(definition: Definition, item: Instance): boolean
	if not M.integer(item.qualityMilli, 1, 5000) then
		return false
	end
	local ceiling = M.durabilityCeiling(definition, item.qualityMilli)
	if item.maxDurabilityMilli ~= nil and not M.integer(item.maxDurabilityMilli, 0, ceiling) then
		return false
	end
	if item.latent ~= nil and (type(item.latent) ~= "string" or #item.latent == 0 or #item.latent > 64) then
		return false
	end
	return M.integer(item.durabilityMilli, 0, M.maxDurability(definition, item))
end

--- Repaired copy of the instance fields: the maximum drops by
--- REPAIR_LOSS_PERMILLE (at least 1 milli) and durability refills to it.
function M.repaired(definition: Definition, item: Instance): (number?, string?)
	local maximum = M.maxDurability(definition, item)
	if (definition.maxDurabilityMilli or 0) == 0 then
		return nil, "NOT_REPAIRABLE"
	elseif maximum == 0 then
		return nil, "WORN_OUT"
	elseif item.durabilityMilli >= maximum then
		return nil, "NOTHING_TO_REPAIR"
	end
	return maximum - math.max(1, math.floor(maximum * M.REPAIR_LOSS_PERMILLE / 1000)), nil
end

function M.new(items: { Definition }): Catalog
	local result: Catalog = {}
	for _, item in items do
		assert(M.identity(item.id) and not result[item.id], "INVALID_CATALOG_ID")
		assert(M.integer(item.stackMax, 1, 1000), "INVALID_STACK_MAX")
		assert(M.integer(item.weightMilli, 0, 1000000), "INVALID_WEIGHT")
		assert(item.maxDurabilityMilli == nil or M.integer(item.maxDurabilityMilli, 0, 1000000), "INVALID_DURABILITY")
		result[item.id] = table.freeze({
			id = item.id,
			stackMax = item.stackMax,
			weightMilli = item.weightMilli,
			maxDurabilityMilli = item.maxDurabilityMilli,
		})
	end
	return table.freeze(result)
end

return M
