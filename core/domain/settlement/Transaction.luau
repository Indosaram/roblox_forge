--!strict
-- Pure candidates only. The caller persists both halves with the command receipt.
-- Context identities are server-issued, unique within the retained settlement epoch.
-- Settlement.usedIds is never pruned here; bounded epoch cleanup belongs to persistence.
local Settlement = require("./Settlement")
local Inventory = require("../inventory/Inventory")
local Catalog = require("../inventory/ItemCatalog")
local Transaction = {}

export type State = {
	settlement: Settlement.State,
	warehouse: Inventory.State,
	structureContents: { [string]: Inventory.State }?,
	-- Serialized workshop states remain owned by this aggregate, not player saves.
	workshops: { [string]: any }?,
}
export type Context = {
	commandId: string,
	actorId: string,
	settlementVersion: number,
	warehouseVersion: number,
	membershipRevision: number,
}
export type Request = { definition: Settlement.Definition, x: number, z: number, rotation: number }

-- Validate the ownership boundary even for server-created aggregate values.
-- A storage inventory's ID is exactly its owning built structure's ID.
function Transaction.validateOwnership(state: State): string?
	if not state.structureContents then
		return nil
	end
	for structureId, contents in state.structureContents do
		if
			not state.settlement.structures[structureId]
			or contents.id ~= structureId
			or contents.id == state.warehouse.id
		then
			return "INVALID_STORAGE_OWNER"
		end
	end
	return nil
end

function Transaction.snapshot(state: State): State
	local err = Transaction.validateOwnership(state)
	assert(err == nil, err)
	local result: State =
		{ settlement = Settlement.snapshot(state.settlement), warehouse = Inventory.snapshot(state.warehouse) }
	local function copy(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local cloned = {}
		for key, child in value do
			cloned[key] = copy(child)
		end
		return cloned
	end
	result.workshops = copy(state.workshops)
	if state.structureContents then
		local contents: { [string]: Inventory.State } = {}
		for id, inventory in state.structureContents do
			contents[id] = Inventory.snapshot(inventory)
		end
		result.structureContents = contents
	end
	return result
end

-- Length framing avoids collisions between tribe/command boundaries. No random IDs.
function Transaction.reservationId(tribeId: string, commandId: string): string
	return string.format("build:%d:%s:%s", #tribeId, tribeId, commandId)
end

local function check(state: State, context: Context): string?
	local ownershipError = Transaction.validateOwnership(state)
	if ownershipError then
		return ownershipError
	end
	if not Catalog.identity(context.commandId) then
		return "INVALID_COMMAND_ID"
	elseif context.warehouseVersion ~= state.warehouse.version then
		return "STALE_WAREHOUSE_VERSION"
	end
	return nil
end

function Transaction.reserve(
	state: State,
	catalog: Catalog.Catalog,
	context: Context,
	request: Request
): (State?, string?)
	local err = check(state, context)
	if err then
		return nil, err
	end
	local id = Transaction.reservationId(state.settlement.config.tribeId, context.commandId)
	if not Catalog.identity(id) then
		return nil, "INVALID_RESERVATION_ID"
	end
	local settlement, refusal =
		Settlement.reserve(state.settlement, context.actorId, context.settlementVersion, context.membershipRevision, {
			id = id,
			definition = request.definition,
			x = request.x,
			z = request.z,
			rotation = request.rotation,
		})
	if not settlement then
		return nil, refusal
	end
	local ids: { string } = {}
	for itemId in state.warehouse.items do
		table.insert(ids, itemId)
	end
	table.sort(ids)
	local quantities: { [string]: number } = {}
	for _, cost in request.definition.cost do
		if not catalog[cost.item] then
			return nil, "UNKNOWN_COST_ITEM"
		end
		local remaining = cost.quantity
		for _, itemId in ids do
			if state.warehouse.items[itemId].catalogId == cost.item then
				local quantity = math.min(remaining, Inventory.available(state.warehouse, itemId))
				if quantity > 0 then
					quantities[itemId] = quantity
					remaining -= quantity
				end
			end
		end
		if remaining > 0 then
			return nil, "UNAVAILABLE"
		end
	end
	local warehouse = Inventory.snapshot(state.warehouse)
	if next(quantities) then
		local reserved, inventoryError = Inventory.reserve(warehouse, id, quantities, context.warehouseVersion)
		if not reserved then
			return nil, inventoryError
		end
		warehouse = reserved
	end
	local result = Transaction.snapshot(state)
	result.settlement, result.warehouse = settlement, warehouse
	return result, nil
end

function Transaction.commit(
	state: State,
	catalog: Catalog.Catalog,
	context: Context,
	reservationId: string
): (State?, string?)
	local err = check(state, context)
	if err then
		return nil, err
	end
	-- Authorization and the pinned membership revision are checked before any debit.
	local settlement, refusal =
		Settlement.commit(state.settlement, context.actorId, context.settlementVersion, reservationId)
	if not settlement then
		return nil, refusal
	end
	local warehouse = Inventory.snapshot(state.warehouse)
	if #state.settlement.reservations[reservationId].definition.cost > 0 then
		local consumed, inventoryError =
			Inventory.exchange(warehouse, catalog, reservationId, {}, context.warehouseVersion)
		if not consumed then
			return nil, inventoryError
		end
		warehouse = consumed
	end
	local result = Transaction.snapshot(state)
	result.settlement, result.warehouse = settlement, warehouse
	return result, nil
end

function Transaction.cancel(state: State, context: Context, reservationId: string): (State?, string?)
	local err = check(state, context)
	if err then
		return nil, err
	end
	local settlement, refusal =
		Settlement.cancel(state.settlement, context.actorId, context.settlementVersion, reservationId)
	if not settlement then
		return nil, refusal
	end
	local warehouse = Inventory.snapshot(state.warehouse)
	if #state.settlement.reservations[reservationId].definition.cost > 0 then
		local released, inventoryError = Inventory.release(warehouse, reservationId, context.warehouseVersion)
		if not released then
			return nil, inventoryError
		end
		warehouse = released
	end
	local result = Transaction.snapshot(state)
	result.settlement, result.warehouse = settlement, warehouse
	return result, nil
end

-- Return whole owned stacks, merging only identical metadata in sorted order.
local function returnContents(
	source: Inventory.State,
	warehouse: Inventory.State,
	catalog: Catalog.Catalog
): (Inventory.State?, string?)
	if next(source.reservations) then
		return nil, "STORAGE_RESERVED"
	end
	local itemIds: { string } = {}
	for id in source.items do
		table.insert(itemIds, id)
	end
	table.sort(itemIds)
	for _, id in itemIds do
		local item = source.items[id]
		local quantity = item.quantity
		local targetIds: { string } = {}
		for targetId in warehouse.items do
			table.insert(targetIds, targetId)
		end
		table.sort(targetIds)
		for _, targetId in targetIds do
			local target = warehouse.items[targetId]
			local amount = math.min(quantity, catalog[item.catalogId].stackMax - target.quantity)
			if amount > 0 and Inventory.compatible(item, target) then
				local left, right, err =
					Inventory.move(source, warehouse, catalog, id, amount, targetId, source.version, warehouse.version)
				if not left or not right then
					return nil, err
				end
				source, warehouse = left, right
				quantity -= amount
			end
		end
		if quantity > 0 then
			local left, right, err =
				Inventory.move(source, warehouse, catalog, id, quantity, id, source.version, warehouse.version)
			if not left or not right then
				return nil, err
			end
			source, warehouse = left, right
		end
	end
	return warehouse, nil
end

-- Build costs specify catalog quantities, not item provenance. Refunds are fresh
-- base-quality catalog materials; existing items/attributes are never overwritten.
-- Explicit owned storage returns in full before the separate build-cost refund.
function Transaction.demolish(
	state: State,
	catalog: Catalog.Catalog,
	context: Context,
	structureId: string
): (State?, string?)
	local err = check(state, context)
	if err then
		return nil, err
	end
	local settlement, refusal, refund = Settlement.demolish(
		state.settlement,
		context.actorId,
		context.settlementVersion,
		context.membershipRevision,
		structureId
	)
	if not settlement or not refund then
		return nil, refusal
	end
	table.sort(refund, function(a, b)
		return a.item < b.item
	end)
	local warehouse = Inventory.snapshot(state.warehouse)
	local contents = if state.structureContents then state.structureContents[structureId] else nil
	if contents then
		local returned, storageError = returnContents(contents, warehouse, catalog)
		if not returned then
			return nil, storageError
		end
		warehouse = returned
	end
	local outputIndex = 0
	for _, cost in refund do
		local definition = catalog[cost.item]
		if not definition then
			return nil, "UNKNOWN_COST_ITEM"
		end
		local remaining = cost.quantity
		while remaining > 0 do
			outputIndex += 1
			local id = string.format("refund:%d:%s:%d", #context.commandId, context.commandId, outputIndex)
			if not Catalog.identity(id) then
				return nil, "INVALID_OUTPUT_ID"
			end
			local quantity = math.min(remaining, definition.stackMax)
			local item: Inventory.Item = {
				itemId = id,
				catalogId = cost.item,
				quantity = quantity,
				qualityMilli = 1000,
				durabilityMilli = definition.maxDurabilityMilli or 0,
				attributes = {},
			}
			-- A temporary pure source lets Inventory enforce both merging and capacity,
			-- including a full-slot warehouse whose compatible stacks still have room.
			local source = Inventory.new(
				if warehouse.id == "refund-source" then "refund-source-2" else "refund-source",
				{ slots = 20, softWeightMilli = 90000, hardWeightMilli = 90000 }
			)
			local added, addError = Inventory.add(source, catalog, item, source.version)
			if not added then
				return nil, addError
			end
			source = added
			local returned, returnError = returnContents(source, warehouse, catalog)
			if not returned then
				return nil, returnError
			end
			warehouse = returned
			remaining -= item.quantity
		end
	end
	local result = Transaction.snapshot(state)
	result.settlement, result.warehouse = settlement, warehouse
	if result.structureContents then
		result.structureContents[structureId] = nil
	end
	return result, nil
end

return Transaction
