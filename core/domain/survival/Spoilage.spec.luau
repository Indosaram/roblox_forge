--!strict
-- G9: food ages on an explicit clock; a refrigerator ages it at a quarter rate.
local Spoilage = require("./Spoilage")
local Inventory = require("../inventory/Inventory")
local ItemCatalog = require("../inventory/ItemCatalog")

local HOUR = 3600 * 1000
local content: any = {
	items = {
		{ id = "berry", name = "Berry", stackMax = 50, weightMilli = 10, tags = {}, foodEffects = { hungerMilli = 1 } },
		{ id = "spoiled-food", name = "Spoiled", stackMax = 50, weightMilli = 10, tags = {} } :: any,
		{ id = "stone", name = "Stone", stackMax = 50, weightMilli = 10, tags = {} } :: any,
	},
	operations = {
		{
			id = "food-spoilage",
			kind = "food",
			seconds = 172800,
			outputs = { { item = "spoiled-food", quantity = 1 } },
			effects = { { id = "refrigeration-age-rate", value = 0.25, unit = "multiplier" } },
		},
	},
}
local catalog = ItemCatalog.new(content.items)

local function bag(): Inventory.State
	local state = Inventory.new("bag", { slots = 10, softWeightMilli = 9000, hardWeightMilli = 9000 })
	for _, entry in { { "b", "berry" }, { "s", "stone" } } do
		state = assert(Inventory.add(state, catalog, {
			itemId = entry[1],
			catalogId = entry[2],
			quantity = 3,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = { level = 7 },
		}, state.version))
	end
	return state
end

return {
	["policy comes from the food-spoilage operation"] = function()
		local policy = assert(Spoilage.policy(content))
		assert(policy.limitMillis == 172800 * 1000 and policy.refrigeratedPermille == 250, "48 h and 0.25")
		assert(policy.perishable.berry and not policy.perishable.stone, "edible items only")
		assert(Spoilage.policy({ items = content.items }) == nil, "no operation -> no spoilage")
	end,
	["aged berry spoils into spoiled-food and keeps its level"] = function()
		local policy = assert(Spoilage.policy(content))
		local fresh = bag()
		local stamped = Spoilage.settle(fresh, policy, 1000, false)
		local berry = stamped.items.b
		assert(berry.attributes.freshAt == 1000 and berry.attributes.freshAge == 0, "first sight stamps age 0")
		assert(stamped.items.s.attributes.freshAt == nil, "non-food is never stamped")
		assert(Spoilage.settle(stamped, policy, 1000 + 47 * HOUR, false) == stamped, "fresh food is not rewritten")
		assert(Spoilage.freshness(berry, policy, 1000 + 47 * HOUR, false) == 20, "1 h of 48 left -> 20 permille")
		local due = 1000 + 48 * HOUR
		local spoiled = Spoilage.settle(stamped, policy, due, false)
		local item = spoiled.items.b
		assert(item.catalogId == "spoiled-food" and item.quantity == 3, "whole stack spoils")
		assert(item.attributes.level == 7 and item.attributes.freshAt == nil, "level kept, clock dropped")
		assert(spoiled.version == stamped.version, "time-derived settlement keeps the container version")
		assert(Spoilage.settle(spoiled, policy, 1000 + 99 * HOUR, false) == spoiled, "spoiled food is inert")
	end,
	["refrigerated berry spoils 4x slower and movement never resets age"] = function()
		local policy = assert(Spoilage.policy(content))
		local start = Spoilage.settle(bag(), policy, 0, false)
		assert(Spoilage.age(start.items.b, policy, 48 * HOUR, true) == 12 * HOUR, "quarter-rate age")
		assert(Spoilage.settle(start, policy, 48 * HOUR, true).items.b.catalogId == "berry", "48 h cold is 12 h")
		local late = (48 * 4 - 1) * HOUR
		assert(Spoilage.settle(start, policy, late, true).items.b.catalogId == "berry", "fresh until 4x")
		assert(Spoilage.settle(start, policy, 48 * 4 * HOUR, true).items.b.catalogId == "spoiled-food", "spoils at 4x")
		-- 47 h in the bag, then a refrigerator: the remaining hour runs at a quarter rate.
		local moved = Spoilage.rebase(start.items.b, policy, 47 * HOUR, false)
		assert(moved.attributes.freshAt == 47 * HOUR and moved.attributes.freshAge == 47 * HOUR, "bag age kept")
		assert(Spoilage.age(moved, policy, 47 * HOUR + 3 * HOUR, true) == 47 * HOUR + 45 * 60 * 1000, "cold hour")
		local back = Spoilage.rebase(moved, policy, 47 * HOUR + 4 * HOUR, true)
		assert(back.catalogId == "spoiled-food", "the fridge only slows it down")
		assert(Spoilage.rebase(back, policy, 99 * HOUR, false) == back, "spoiled food is not rebased")
	end,
	["settlement is pure, skips reserved stacks and refuses a clock moving backwards"] = function()
		local policy = assert(Spoilage.policy(content))
		local start = Spoilage.settle(bag(), policy, 100, false)
		assert(Spoilage.age(start.items.b, policy, 50, false) == 0, "no negative age")
		assert(Spoilage.rebase(start.items.b, policy, 50, false) == start.items.b, "no rebase into the past")
		local before = start.items.b.attributes.freshAt
		Spoilage.settle(start, policy, 100 + 48 * HOUR, false)
		assert(start.items.b.attributes.freshAt == before and start.items.b.catalogId == "berry", "input untouched")
		local held = assert(Inventory.reserve(start, "job", { b = 1 }, start.version))
		assert(Spoilage.settle(held, policy, 100 + 48 * HOUR, false) == held, "reserved stack untouched")
	end,
}
