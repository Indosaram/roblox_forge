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

function M.integer(value: any, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value >= minimum and value <= maximum and value % 1 == 0
end

function M.identity(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128
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
