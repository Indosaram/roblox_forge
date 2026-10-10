--!strict
local Content = require("./Content")
local Vitals = require("./Vitals")
local Inventory = require("../inventory/Inventory")
local ItemCatalog = require("../inventory/ItemCatalog")
local M = {}

-- Content is the canonical server catalog, never client effects. The caller
-- advances vitals first and commits BOTH candidates through its replay journal.
function M.consume(
	inventory: Inventory.State,
	vitals: Vitals.State,
	content: Content.Document,
	itemId: string
): (Inventory.State?, Vitals.State?, string?)
	if not ItemCatalog.identity(itemId) then
		return nil, nil, "INVALID_ITEM_ID"
	end
	if not vitals.online or vitals.healthMilli == 0 then
		return nil, nil, "NOT_ALIVE"
	end
	local item = inventory.items[itemId]
	if not item or Inventory.available(inventory, itemId) < 1 then
		return nil, nil, "UNAVAILABLE"
	end
	local effect: Content.FoodEffects? = nil
	for _, definition in content.items do
		if definition.id == item.catalogId then
			effect = definition.foodEffects
			break
		end
	end
	if not effect then
		return nil, nil, "NOT_FOOD"
	end
	local nextVitals = Vitals.food(vitals, effect)
	if
		nextVitals.hungerMilli == vitals.hungerMilli
		and nextVitals.healthMilli == vitals.healthMilli
		and nextVitals.fatigueMilli == vitals.fatigueMilli
	then
		return nil, nil, "NO_EFFECT"
	end
	local nextInventory, err = Inventory.consume(inventory, itemId, 1, inventory.version)
	if not nextInventory then
		return nil, nil, err
	end
	nextVitals.config = table.freeze(table.clone(nextVitals.config))
	return nextInventory, nextVitals, nil
end

return M
