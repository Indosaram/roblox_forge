--!strict
-- Food spoilage on an explicit clock. Each edible stack carries its equivalent age
-- (`freshAge`, ms) as of a clock reading (`freshAt`, ms) as instance attributes.
-- Age keeps running from there at the rate of the container the stack sits in
-- (a refrigerated container runs at the authored multiplier). Moving a stack
-- between containers rebases it first, so its age is never reset or misattributed.
-- Callers pass the clock and the container's refrigeration; this module never reads time.
local Inventory = require("../inventory/Inventory")
local M = {}

M.OPERATION = "food-spoilage"
M.RATE_EFFECT = "refrigeration-age-rate"

export type Policy = {
	limitMillis: number,
	refrigeratedPermille: number,
	output: string,
	perishable: { [string]: boolean },
}

--- Policy from the `food-spoilage` operation; nil when the content has none.
--- Only food that can become the output without growing its stack or weight is
--- perishable, so a settled container never exceeds the capacity it already held.
function M.policy(content: any): Policy?
	local row: any = nil
	for _, operation in content.operations or {} do
		if operation.id == M.OPERATION then
			row = operation
		end
	end
	if not row or not row.outputs or not row.outputs[1] then
		return nil
	end
	local permille = 1000
	for _, effect in row.effects or {} do
		if effect.id == M.RATE_EFFECT then
			permille = math.floor(effect.value * 1000 + 0.5)
		end
	end
	local output = row.outputs[1].item
	local target: any = nil
	for _, item in content.items do
		if item.id == output then
			target = item
		end
	end
	if not target then
		return nil
	end
	local perishable = {}
	for _, item in content.items do
		if
			item.foodEffects
			and item.id ~= output
			and item.stackMax <= target.stackMax
			and item.weightMilli >= target.weightMilli
		then
			perishable[item.id] = true
		end
	end
	return {
		limitMillis = row.seconds * 1000,
		refrigeratedPermille = permille,
		output = output,
		perishable = perishable,
	}
end

local function stamped(item: Inventory.Item): boolean
	return type(item.attributes.freshAt) == "number" and type(item.attributes.freshAge) == "number"
end

--- Equivalent age in ms at `nowMillis`; nil for non-perishable or not-yet-stamped stacks.
function M.age(item: Inventory.Item, policy: Policy, nowMillis: number, refrigerated: boolean): number?
	if not policy.perishable[item.catalogId] or not stamped(item) then
		return nil
	end
	local elapsed = math.max(0, nowMillis - (item.attributes.freshAt :: number))
	local rate = if refrigerated then policy.refrigeratedPermille else 1000
	return (item.attributes.freshAge :: number) + elapsed * rate // 1000
end

--- Remaining freshness in permille (1000 fresh, 0 spoiled); nil when not perishable.
--- An unstamped stack is fresh: its clock starts at the next settlement.
function M.freshness(item: Inventory.Item, policy: Policy, nowMillis: number, refrigerated: boolean): number?
	if not policy.perishable[item.catalogId] then
		return nil
	end
	local current = M.age(item, policy, nowMillis, refrigerated) or 0
	return math.max(0, (policy.limitMillis - current) * 1000 // policy.limitMillis)
end

-- Copy of `item` aged to `nowMillis` (or turned into the spoilage output); nil when unchanged.
local function advance(
	item: Inventory.Item,
	policy: Policy,
	nowMillis: number,
	refrigerated: boolean,
	rebase: boolean
): Inventory.Item?
	if not policy.perishable[item.catalogId] then
		return nil
	end
	local current = M.age(item, policy, nowMillis, refrigerated)
	local attributes: { [string]: any } = table.clone(item.attributes)
	local result = table.clone(item)
	if current and current >= policy.limitMillis then
		attributes.freshAt, attributes.freshAge = nil, nil
		result.catalogId = policy.output
		if item.material then
			local material = table.clone(item.material)
			material.attributes = table.clone(item.material.attributes)
			material.item = policy.output
			result.material = material
		end
	elseif current == nil then
		attributes.freshAt, attributes.freshAge = nowMillis, 0
	elseif rebase and (item.attributes.freshAt :: number) < nowMillis then
		attributes.freshAt, attributes.freshAge = nowMillis, current
	else
		return nil
	end
	result.attributes = attributes
	return result
end

--- Item moved out of a container at `nowMillis`: its age is fixed at the source rate.
--- Returns the input when nothing changes; an expired stack comes back spoiled.
function M.rebase(item: Inventory.Item, policy: Policy, nowMillis: number, refrigerated: boolean): Inventory.Item
	return advance(item, policy, nowMillis, refrigerated, true) or item
end

local function reserved(state: Inventory.State): { [string]: boolean }
	local held = {}
	for _, quantities in state.reservations do
		for itemId in quantities do
			held[itemId] = true
		end
	end
	return held
end

local function sortedIds(state: Inventory.State): { string }
	local ids = {}
	for itemId in state.items do
		table.insert(ids, itemId)
	end
	table.sort(ids)
	return ids
end

--- Stamp first-seen food and turn expired, unreserved stacks into the spoilage output
--- (quantity and level kept). Fresh stamped stacks are left as they are: their age is
--- derived from `freshAt`. Like vitals, settlement is a pure function of the clock, so the
--- container version is kept: a client's expected version stays valid across it.
--- Returns the input itself when nothing changed.
function M.settle(state: Inventory.State, policy: Policy, nowMillis: number, refrigerated: boolean): Inventory.State
	local held = reserved(state)
	local result: Inventory.State? = nil
	for _, itemId in sortedIds(state) do
		local nextItem = if held[itemId]
			then nil
			else advance(state.items[itemId], policy, nowMillis, refrigerated, false)
		if nextItem then
			if not result then
				result = Inventory.snapshot(state)
			end
			(result :: Inventory.State).items[itemId] = nextItem
		end
	end
	return result or state
end

return M
