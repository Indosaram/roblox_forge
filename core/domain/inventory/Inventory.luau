--!strict
-- Copy-on-write domain transitions. Persistence and authorization belong to callers.
local Catalog = require("./ItemCatalog")
local CapacityPolicy = require("../survival/CapacityPolicy")
local M = {}

export type Item = {
	itemId: string,
	catalogId: string,
	quantity: number,
	qualityMilli: number,
	durabilityMilli: number,
	-- Present only once a repair has permanently lowered the ceiling.
	maxDurabilityMilli: number?,
	-- Rolled latent attribute (a content tag), if any.
	latent: string?,
	attributes: { [string]: string | number | boolean },
}
export type Limits = {
	contentVersion: number?,
	kind: string?,
	slots: number,
	softWeightMilli: number,
	hardWeightMilli: number,
	speedPenaltyMilli: number?,
}
export type State = {
	id: string,
	version: number,
	limits: Limits,
	items: { [string]: Item },
	reservations: { [string]: { [string]: number } },
}

local function copyItem(item: Item): Item
	local copy = table.clone(item)
	copy.attributes = table.clone(item.attributes)
	return copy
end

function M.snapshot(state: State): State
	local copy = table.clone(state)
	copy.limits = table.clone(state.limits)
	copy.items = {}
	for id, item in state.items do
		copy.items[id] = copyItem(item)
	end
	copy.reservations = {}
	for owner, quantities in state.reservations do
		copy.reservations[owner] = table.clone(quantities)
	end
	return copy
end

function M.new(id: string, limits: Limits): State
	assert(Catalog.identity(id), "INVALID_CONTAINER_ID")
	local policy = CapacityPolicy.forVersion(limits.contentVersion)
	assert(limits.kind == nil or limits.kind == "bag" or limits.kind == "home", "INVALID_CONTAINER_KIND")
	assert(
		Catalog.integer(limits.slots, 1, if limits.kind == "home" then policy.homeSlots else policy.bagSlots),
		"INVALID_SLOTS"
	)
	assert(Catalog.integer(limits.softWeightMilli, 0, 90000), "INVALID_SOFT_WEIGHT")
	assert(Catalog.integer(limits.hardWeightMilli, limits.softWeightMilli, 90000), "INVALID_HARD_WEIGHT")
	assert(limits.speedPenaltyMilli == nil or Catalog.integer(limits.speedPenaltyMilli, 0, 1000), "INVALID_PENALTY")
	return { id = id, version = 0, limits = table.clone(limits), items = {}, reservations = {} }
end

local function version(state: State, expected: number): string?
	if not Catalog.integer(expected, 0, 2 ^ 53 - 2) or expected ~= state.version then
		return "STALE_VERSION"
	end
	return nil
end

local function validItem(catalog: Catalog.Catalog, item: Item): boolean
	local definition = catalog[item.catalogId]
	if not definition or not Catalog.identity(item.itemId) then
		return false
	end
	if not Catalog.integer(item.quantity, 1, definition.stackMax) or not Catalog.validInstance(definition, item) then
		return false
	end
	if type(item.attributes) ~= "table" then
		return false
	end
	local count = 0
	for key, value in item.attributes do
		count += 1
		if count > 16 or not Catalog.identity(key) then
			return false
		end
		if type(value) == "number" then
			if not Catalog.integer(value, -(2 ^ 53 - 1), 2 ^ 53 - 1) then
				return false
			end
		elseif type(value) ~= "boolean" and (type(value) ~= "string" or #value > 128) then
			return false
		end
	end
	return true
end

function M.weight(state: State, catalog: Catalog.Catalog): number
	local total = 0
	for _, item in state.items do
		total += catalog[item.catalogId].weightMilli * item.quantity
	end
	return total
end

function M.speedMultiplierMilli(state: State, catalog: Catalog.Catalog): number
	return if M.weight(state, catalog) > state.limits.softWeightMilli
		then 1000 - (state.limits.speedPenaltyMilli or 0)
		else 1000
end

local function capacity(state: State, catalog: Catalog.Catalog): string?
	local slots = 0
	for _ in state.items do
		slots += 1
	end
	if slots > state.limits.slots then
		return "FULL_SLOTS"
	end
	if M.weight(state, catalog) > state.limits.hardWeightMilli then
		return "FULL_WEIGHT"
	end
	return nil
end

function M.available(state: State, itemId: string): number
	local item = state.items[itemId]
	local amount = if item then item.quantity else 0
	for _, reservation in state.reservations do
		amount -= reservation[itemId] or 0
	end
	return amount
end

-- Reconstruct persisted reservations, never silently discard unsupported saves.
function M.fromSave(raw: any, catalog: Catalog.Catalog): State
	assert(type(raw) == "table" and raw.saveVersion == 1, "UNSUPPORTED_INVENTORY_SAVE")
	local state = M.new(raw.id, raw.limits)
	assert(Catalog.integer(raw.version, 0, 2 ^ 53 - 2), "INVALID_VERSION")
	assert(type(raw.items) == "table" and type(raw.reservations) == "table", "INVALID_INVENTORY_SAVE")
	for id, item in raw.items do
		assert(type(item) == "table" and id == item.itemId and validItem(catalog, item), "INVALID_ITEM")
		state.items[id] = copyItem(item)
	end
	assert(capacity(state, catalog) == nil, "INVALID_CAPACITY")
	for owner, quantities in raw.reservations do
		assert(Catalog.identity(owner) and type(quantities) == "table", "INVALID_RESERVATION")
		local count = 0
		for id, quantity in quantities do
			count += 1
			assert(Catalog.integer(quantity, 1, 1000) and M.available(state, id) >= quantity, "INVALID_RESERVATION")
		end
		assert(count > 0, "INVALID_RESERVATION")
		state.reservations[owner] = table.clone(quantities)
	end
	state.version = raw.version
	return state
end

function M.save(state: State): any
	local saved: any = M.snapshot(state)
	saved.saveVersion = 1
	return saved
end

function M.compatible(left: Item, right: Item): boolean
	if
		left.catalogId ~= right.catalogId
		or left.qualityMilli ~= right.qualityMilli
		or left.durabilityMilli ~= right.durabilityMilli
		or left.maxDurabilityMilli ~= right.maxDurabilityMilli
		or left.latent ~= right.latent
	then
		return false
	end
	for key, value in left.attributes do
		if right.attributes[key] ~= value then
			return false
		end
	end
	for key, value in right.attributes do
		if left.attributes[key] ~= value then
			return false
		end
	end
	return true
end

function M.add(state: State, catalog: Catalog.Catalog, item: Item, expected: number): (State?, string?)
	local err = version(state, expected)
	if err then
		return nil, err
	end
	if not validItem(catalog, item) then
		return nil, "INVALID_ITEM"
	end
	if state.items[item.itemId] then
		return nil, "DUPLICATE_ITEM_ID"
	end
	local nextState = M.snapshot(state)
	nextState.items[item.itemId] = copyItem(item)
	err = capacity(nextState, catalog)
	if err then
		return nil, err
	end
	nextState.version += 1
	return nextState, nil
end

function M.reserve(state: State, owner: string, quantities: { [string]: number }, expected: number): (State?, string?)
	local err = version(state, expected)
	if err then
		return nil, err
	end
	if not Catalog.identity(owner) or state.reservations[owner] then
		return nil, "RESERVATION_OWNER"
	end
	local count = 0
	for id, quantity in quantities do
		count += 1
		if not Catalog.integer(quantity, 1, 1000) or M.available(state, id) < quantity then
			return nil, "UNAVAILABLE"
		end
	end
	if count == 0 then
		return nil, "EMPTY_RESERVATION"
	end
	local nextState = M.snapshot(state)
	nextState.reservations[owner] = table.clone(quantities)
	nextState.version += 1
	return nextState, nil
end

function M.release(state: State, owner: string, expected: number): (State?, string?)
	local err = version(state, expected)
	if err then
		return nil, err
	end
	if not state.reservations[owner] then
		return nil, "RESERVATION_NOT_FOUND"
	end
	local nextState = M.snapshot(state)
	nextState.reservations[owner] = nil
	nextState.version += 1
	return nextState, nil
end

function M.consume(state: State, itemId: string, quantity: number, expected: number): (State?, string?)
	local err = version(state, expected)
	if err then
		return nil, err
	end
	if not Catalog.integer(quantity, 1, 1000) or M.available(state, itemId) < quantity then
		return nil, "UNAVAILABLE"
	end
	local nextState = M.snapshot(state)
	nextState.items[itemId].quantity -= quantity
	if nextState.items[itemId].quantity == 0 then
		nextState.items[itemId] = nil
	end
	nextState.version += 1
	return nextState, nil
end

-- Atomically consume one owner's reservation and install outputs against the projected state.
function M.exchange(
	state: State,
	catalog: Catalog.Catalog,
	owner: string,
	outputs: { Item },
	expected: number
): (State?, string?)
	local err = version(state, expected)
	if err then
		return nil, err
	end
	local reservation = state.reservations[owner]
	if not reservation then
		return nil, "RESERVATION_NOT_FOUND"
	end
	local nextState = M.snapshot(state)
	for id, quantity in reservation do
		nextState.items[id].quantity -= quantity
		if nextState.items[id].quantity == 0 then
			nextState.items[id] = nil
		end
	end
	nextState.reservations[owner] = nil
	for _, item in outputs do
		if not validItem(catalog, item) then
			return nil, "INVALID_ITEM"
		end
		if state.items[item.itemId] or nextState.items[item.itemId] then
			return nil, "DUPLICATE_ITEM_ID"
		end
		nextState.items[item.itemId] = copyItem(item)
	end
	err = capacity(nextState, catalog)
	if err then
		return nil, err
	end
	nextState.version += 1
	return nextState, nil
end

function M.split(
	state: State,
	catalog: Catalog.Catalog,
	itemId: string,
	quantity: number,
	newId: string,
	expected: number
): (State?, string?)
	local err = version(state, expected)
	if err then
		return nil, err
	end
	local item = state.items[itemId]
	if not item or not Catalog.integer(quantity, 1, item.quantity - 1) or M.available(state, itemId) < quantity then
		return nil, "UNAVAILABLE"
	end
	if not Catalog.identity(newId) or state.items[newId] then
		return nil, "DUPLICATE_ITEM_ID"
	end
	local nextState = M.snapshot(state)
	local splitItem = copyItem(item)
	splitItem.itemId = newId
	splitItem.quantity = quantity
	nextState.items[itemId].quantity -= quantity
	nextState.items[newId] = splitItem
	err = capacity(nextState, catalog)
	if err then
		return nil, err
	end
	nextState.version += 1
	return nextState, nil
end

function M.merge(
	state: State,
	catalog: Catalog.Catalog,
	sourceId: string,
	targetId: string,
	quantity: number,
	expected: number
): (State?, string?)
	local err = version(state, expected)
	if err then
		return nil, err
	end
	if sourceId == targetId then
		return nil, "SAME_ITEM"
	end
	local source, target = state.items[sourceId], state.items[targetId]
	if
		not source
		or not target
		or not Catalog.integer(quantity, 1, 1000)
		or M.available(state, sourceId) < quantity
	then
		return nil, "UNAVAILABLE"
	end
	if not M.compatible(source, target) then
		return nil, "INCOMPATIBLE_STACK"
	end
	if target.quantity + quantity > catalog[target.catalogId].stackMax then
		return nil, "FULL_STACK"
	end
	local nextState = M.snapshot(state)
	nextState.items[sourceId].quantity -= quantity
	nextState.items[targetId].quantity += quantity
	if nextState.items[sourceId].quantity == 0 then
		nextState.items[sourceId] = nil
	end
	nextState.version += 1
	return nextState, nil
end

-- A partial move requires a new stable ID. A whole move retains the source ID.
-- targetId selects an existing compatible stack, otherwise it names the moved stack.
function M.move(
	source: State,
	target: State,
	catalog: Catalog.Catalog,
	itemId: string,
	quantity: number,
	targetId: string,
	sourceVersion: number,
	targetVersion: number
): (State?, State?, string?)
	local err = version(source, sourceVersion) or version(target, targetVersion)
	if err then
		return nil, nil, err
	end
	if source.id == target.id then
		return nil, nil, "SAME_CONTAINER"
	end
	local item = source.items[itemId]
	if not item or not Catalog.integer(quantity, 1, 1000) or M.available(source, itemId) < quantity then
		return nil, nil, "UNAVAILABLE"
	end
	if not Catalog.identity(targetId) then
		return nil, nil, "INVALID_ITEM_ID"
	end
	local existing = target.items[targetId]
	if existing then
		if not M.compatible(item, existing) then
			return nil, nil, "INCOMPATIBLE_STACK"
		end
		if existing.quantity + quantity > catalog[item.catalogId].stackMax then
			return nil, nil, "FULL_STACK"
		end
	elseif
		(quantity == item.quantity and targetId ~= itemId)
		or (quantity < item.quantity and (targetId == itemId or source.items[targetId] ~= nil))
	then
		return nil, nil, "INVALID_ITEM_ID"
	end
	if target.items[itemId] then
		return nil, nil, "DUPLICATE_ITEM_ID"
	end
	local nextSource, nextTarget = M.snapshot(source), M.snapshot(target)
	nextSource.items[itemId].quantity -= quantity
	if nextSource.items[itemId].quantity == 0 then
		nextSource.items[itemId] = nil
	end
	if existing then
		nextTarget.items[targetId].quantity += quantity
	else
		local moved = copyItem(item)
		moved.itemId = targetId
		moved.quantity = quantity
		nextTarget.items[targetId] = moved
	end
	err = capacity(nextTarget, catalog)
	if err then
		return nil, nil, err
	end
	nextSource.version += 1
	nextTarget.version += 1
	return nextSource, nextTarget, nil
end

return M
