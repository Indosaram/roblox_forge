--!strict
local Late = require("../../../core/domain/survival/LateEquipment")
local Data = require("../../../core/domain/genre/SerializedData")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local M = {}

-- The personal aggregate owns state, wallet, bag, and equipment together.
-- Spatial and progression facts must come from server-owned world/progression ports.
function M.apply(
	content: any,
	aggregate: any,
	action: string,
	args: any,
	receipt: string,
	now: number,
	facts: any
): (any?, string?)
	local state = aggregate.lateEquipment or Late.new()
	if state.receipts[receipt] then
		return nil, "DUPLICATE_RECEIPT"
	end
	local result = Data.clone(aggregate)
	local catalog = Catalog.new(content.items)
	local bag = Inventory.fromSave(aggregate.bag, catalog)
	if action == "start" then
		local available: any = {}
		for itemId, item in bag.items do
			available[item.catalogId] = (available[item.catalogId] or 0) + Inventory.available(bag, itemId)
		end
		local context = table.clone(facts)
		context.materials, context.coins, context.equipment = available, aggregate.coins, aggregate.equipment
		local nextState, reason =
			Late.start(content, state, aggregate.tree, args.id, args.target, args.slot, receipt, now, context)
		if not nextState then
			return nil, reason
		end
		local row = Late.operation(content, args.id)
		-- Stable selection; only unreserved quantities can be consumed.
		local ids = {}
		for id in bag.items do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, input in row.inputs do
			local remaining = input.quantity
			for _, id in ids do
				local item = bag.items[id]
				if item and item.catalogId == input.item and remaining > 0 then
					local quantity = math.min(remaining, Inventory.available(bag, id))
					if quantity > 0 then
						bag = assert(Inventory.consume(bag, id, quantity, bag.version))
						remaining -= quantity
					end
				end
			end
		end
		result.bag, result.coins, result.lateEquipment =
			Inventory.save(bag), aggregate.coins - (row.cost or 0), nextState
	elseif action == "complete" or action == "cancel" then
		local nextState, output, reason = Late.finish(content, state, args.jobId, now, action == "cancel")
		if not nextState then
			return nil, reason
		end
		nextState.receipts[receipt] = true
		result.lateEquipment = nextState
		result.coins += output.refund
		if output.target and not output.cancelled then
			local equipment = result.equipment[output.target]
			if not equipment then
				return nil, "UNKNOWN_EQUIPMENT"
			end
			if output.operation.kind == "modifier" then
				equipment.modifications = equipment.modifications or {}
				equipment.modifications[tostring(output.slot)] = Data.clone(output.operation.effects)
			else
				equipment.support = output.operation.id
				equipment.completed = equipment.completed or {}
				equipment.completed[output.operation.id] = true
			end
		end
	else
		return nil, "UNKNOWN_ACTION"
	end
	return result, nil
end

return M
