--!strict
-- Pure shared-node candidate. The caller must atomically commit nodes, bag and
-- request receipt under one owner, compare both base versions, then publish.
-- This module is not a shared-world persistence owner or a replay ledger.
local Content = require("../../../core/domain/survival/Content")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Job = require("../../../core/domain/crafting/Job")
local M = {}

export type Position = { x: number, y: number, z: number }
export type Node = {
	id: string,
	catalogId: string,
	position: Position,
	charges: number,
	qualityMilli: number,
	requiredToolTag: string?,
}
export type State = { worldRevision: string, version: number, nodes: { [string]: Node } }
export type Context = { actorId: string, sessionEpoch: number, requestId: string }
-- Server-only projection of the existing equipment/reachable world ports.
-- Node identity and position come from State, never from a station lookup or client.
export type Access = {
	actorId: string,
	carriedContainer: string,
	worldRevision: string,
	equipment: (string) -> { [string]: boolean }?,
	reachable: (string, Position) -> boolean,
}
export type Candidate = {
	nodes: State,
	inventory: Inventory.State,
	itemIds: { string },
	baseNodeVersion: number,
	baseInventoryVersion: number,
}

function M.snapshot(state: State): State
	local result: State = { worldRevision = state.worldRevision, version = state.version, nodes = {} }
	for id, node in state.nodes do
		local copied = table.clone(node)
		copied.position = table.clone(node.position)
		result.nodes[id] = copied
	end
	return result
end

function M.new(worldRevision: string, content: Content.Document, nodes: { Node }): State
	assert(Catalog.identity(worldRevision), "INVALID_WORLD_REVISION")
	local state: State = { worldRevision = worldRevision, version = 0, nodes = {} }
	for _, node in nodes do
		assert(Catalog.identity(node.id) and not state.nodes[node.id], "INVALID_NODE_ID")
		assert(Catalog.integer(node.charges, 0, 1000), "INVALID_CHARGES")
		assert(
			Catalog.integer(node.qualityMilli, content.limits.qualityMilliMin, content.limits.qualityMilliMax),
			"INVALID_QUALITY"
		)
		assert(not node.requiredToolTag or table.find(content.tags, node.requiredToolTag), "INVALID_TOOL_TAG")
		local found = false
		for _, definition in content.nodes do
			if definition.id == node.catalogId then
				found = true
			end
		end
		assert(found, "UNKNOWN_NODE_CATALOG")
		for _, axis in { "x", "y", "z" } do
			local value = node.position[axis]
			assert(type(value) == "number" and value == value and math.abs(value) <= 1e6, "INVALID_POSITION")
		end
		state.nodes[node.id] = node
	end
	return M.snapshot(state)
end

function M.gather(
	state: State,
	inventory: Inventory.State,
	context: Context,
	content: Content.Document,
	nodeId: string,
	expectedNodeVersion: number,
	access: Access
): (Candidate?, string?)
	if context.actorId ~= access.actorId then
		return nil, "WRONG_ACTOR"
	end
	if inventory.id ~= access.carriedContainer then
		return nil, "WRONG_CONTAINER"
	end
	if state.worldRevision ~= access.worldRevision then
		return nil, "WRONG_WORLD"
	end
	if not Catalog.integer(expectedNodeVersion, 0, 2 ^ 53 - 2) or state.version ~= expectedNodeVersion then
		return nil, "STALE_VERSION"
	end
	if
		not Catalog.identity(context.actorId)
		or not Catalog.identity(context.requestId)
		or not Catalog.integer(context.sessionEpoch, 0, 2 ^ 53 - 1)
	then
		return nil, "INVALID_GATHER_IDENTITY"
	end
	local identity = string.format(
		"g%d:%s:%d:%d:%s",
		#context.actorId,
		context.actorId,
		context.sessionEpoch,
		#context.requestId,
		context.requestId
	)
	if #identity > 100 then
		return nil, "INVALID_GATHER_IDENTITY"
	end
	local node = state.nodes[nodeId]
	if not node then
		return nil, "UNKNOWN_NODE"
	end
	if node.charges == 0 then
		return nil, "NODE_DEPLETED"
	end
	if not access.reachable(context.actorId, table.clone(node.position)) then
		return nil, "NODE_UNREACHABLE"
	end
	if node.requiredToolTag then
		local equipped = access.equipment(context.actorId)
		local found = false
		for id, item in inventory.items do
			if equipped and equipped[id] and item.durabilityMilli > 0 and Inventory.available(inventory, id) > 0 then
				for _, definition in content.items do
					if definition.id == item.catalogId and table.find(definition.tags, node.requiredToolTag) then
						found = true
					end
				end
			end
		end
		if not found then
			return nil, "TOOL_UNAVAILABLE"
		end
	end
	local definition: Content.Node? = nil
	for _, entry in content.nodes do
		if entry.id == node.catalogId then
			definition = entry
		end
	end
	if not definition then
		return nil, "UNKNOWN_NODE_CATALOG"
	end
	local catalog = Job.catalog(content)
	local bag = Inventory.snapshot(inventory)
	local ids: { string } = {}
	for index, output in definition.harvest do
		local itemId = identity .. ":output:" .. tostring(index)
		local added, err = Inventory.add(bag, catalog, {
			itemId = itemId,
			catalogId = output.item,
			quantity = output.quantity,
			qualityMilli = node.qualityMilli,
			durabilityMilli = math.floor((catalog[output.item].maxDurabilityMilli or 0) * node.qualityMilli / 1000),
			attributes = {},
		}, bag.version)
		if not added then
			return nil, err
		end
		bag = added
		table.insert(ids, itemId)
	end
	local nodes = M.snapshot(state)
	nodes.nodes[nodeId].charges -= 1
	nodes.version += 1
	return {
		nodes = nodes,
		inventory = bag,
		itemIds = ids,
		baseNodeVersion = state.version,
		baseInventoryVersion = inventory.version,
	},
		nil
end

return M
