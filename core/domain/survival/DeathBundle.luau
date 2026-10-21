--!strict
-- Server-only candidate transitions. Persist both returned states atomically with
-- the death/respawn event. Authority and equipment come from server state, not RPC.
-- A durable increasing death sequence is the terminal identity horizon: no old
-- sequence is ever accepted again. At most eight active bundles (20 stacks each).
-- Reservations stay owned by the carried inventory; crafting jobs are untouched.
local Inventory = require("../inventory/Inventory")
local Catalog = require("../inventory/ItemCatalog")
local Vitals = require("./Vitals")
local M = {}
local MAX_CLOCK = 2 ^ 53 - 1 - 600000

export type Authority = { ownerId: string, serverId: string }
export type Bundle = { expiresMillis: number, inventory: Inventory.State }
export type State = {
	ownerId: string,
	serverId: string,
	carriedId: string,
	clockMillis: number,
	lastSequence: number,
	bundles: { [string]: Bundle },
}

local function ids(items: any): { string }
	local result = {}
	for id in items do
		table.insert(result, id)
	end
	table.sort(result)
	return result
end

function M.new(ownerId: string, serverId: string, carriedId: string, nowMillis: number): State
	assert(Catalog.identity(ownerId) and Catalog.identity(serverId) and Catalog.identity(carriedId), "INVALID_IDENTITY")
	assert(Catalog.integer(nowMillis, 0, MAX_CLOCK), "INVALID_CLOCK")
	return {
		ownerId = ownerId,
		serverId = serverId,
		carriedId = carriedId,
		clockMillis = nowMillis,
		lastSequence = 0,
		bundles = {},
	}
end

function M.snapshot(state: State): State
	local nextState = table.clone(state)
	nextState.bundles = {}
	for id, bundle in state.bundles do
		nextState.bundles[id] =
			{ expiresMillis = bundle.expiresMillis, inventory = Inventory.snapshot(bundle.inventory) }
	end
	return nextState
end

local function authorized(state: State, authority: Authority, nowMillis: number): string?
	if authority.ownerId ~= state.ownerId or authority.serverId ~= state.serverId then
		return "UNAUTHORIZED"
	end
	if not Catalog.integer(nowMillis, state.clockMillis, MAX_CLOCK) then
		return "INVALID_CLOCK"
	end
	return nil
end

function M.expire(state: State, authority: Authority, nowMillis: number): (State?, string?)
	local err = authorized(state, authority, nowMillis)
	if err then
		return nil, err
	end
	local nextState = M.snapshot(state)
	nextState.clockMillis = nowMillis
	for id, bundle in nextState.bundles do
		if nowMillis >= bundle.expiresMillis then
			nextState.bundles[id] = nil
		end
	end
	return nextState, nil
end

function M.drop(
	state: State,
	carried: Inventory.State,
	catalog: Catalog.Catalog,
	vitals: Vitals.State,
	authority: Authority,
	deathSequence: number,
	equippedIds: { [string]: boolean },
	nowMillis: number
): (State?, Inventory.State?, string?)
	local err = authorized(state, authority, nowMillis)
	if err then
		return nil, nil, err
	end
	if carried.id ~= state.carriedId then
		return nil, nil, "WRONG_CONTAINER"
	end
	if not vitals.online or vitals.healthMilli ~= 0 or vitals.clockMillis ~= nowMillis then
		return nil, nil, "NOT_CURRENT_DEATH"
	end
	if not Catalog.integer(deathSequence, 1, 2 ^ 53 - 2) or deathSequence ~= state.lastSequence + 1 then
		return nil, nil, "DEATH_SEQUENCE"
	end
	for id, equipped in equippedIds do
		if equipped ~= true or not carried.items[id] then
			return nil, nil, "INVALID_EQUIPMENT"
		end
	end
	local nextState = M.expire(state, authority, nowMillis) :: State
	local nextCarried = Inventory.snapshot(carried)
	for _, existing in nextState.bundles do
		for id in carried.items do
			if existing.inventory.items[id] then
				return nil, nil, "DUPLICATE_ITEM_ID"
			end
		end
	end
	local policy = Vitals.deathPolicy(vitals)
	local deathId = "death:" .. tostring(deathSequence)
	if policy.dropBag then
		if #ids(nextState.bundles) >= 8 then
			return nil, nil, "FULL_BUNDLES"
		end
		local bundle = Inventory.new(deathId, {
			slots = if carried.limits.contentVersion == 2 then carried.limits.slots else 20,
			contentVersion = carried.limits.contentVersion,
			softWeightMilli = 90000,
			hardWeightMilli = 90000,
		})
		for index, id in ids(carried.items) do
			local quantity = Inventory.available(carried, id)
			if not equippedIds[id] and quantity > 0 then
				local targetId = if quantity == carried.items[id].quantity
					then id
					else deathId .. ":split:" .. tostring(index)
				local source, target, moveError = Inventory.move(
					nextCarried,
					bundle,
					catalog,
					id,
					quantity,
					targetId,
					nextCarried.version,
					bundle.version
				)
				if not source or not target then
					return nil, nil, moveError
				end
				nextCarried, bundle = source, target
			end
		end
		if next(bundle.items) then
			nextState.bundles[deathId] = { expiresMillis = nowMillis + policy.ownerOnlyMillis, inventory = bundle }
		end
	end
	nextState.lastSequence = deathSequence
	return nextState, nextCarried, nil
end

-- Whole-bundle pickup only. Failed projected capacity changes neither input.
function M.pickup(
	state: State,
	carried: Inventory.State,
	catalog: Catalog.Catalog,
	vitals: Vitals.State,
	authority: Authority,
	deathId: string,
	nowMillis: number
): (State?, Inventory.State?, string?)
	local err = authorized(state, authority, nowMillis)
	if err then
		return nil, nil, err
	end
	if carried.id ~= state.carriedId then
		return nil, nil, "WRONG_CONTAINER"
	end
	if not vitals.online or vitals.healthMilli <= 0 or vitals.clockMillis ~= nowMillis then
		return nil, nil, "NOT_CURRENT_LIVING_ACTOR"
	end
	local bundle = state.bundles[deathId]
	if not bundle then
		return nil, nil, "BUNDLE_NOT_FOUND"
	end
	if nowMillis >= bundle.expiresMillis then
		return nil, nil, "BUNDLE_EXPIRED"
	end
	local nextState = M.expire(state, authority, nowMillis) :: State
	local nextCarried, remaining = Inventory.snapshot(carried), Inventory.snapshot(bundle.inventory)
	for _, id in ids(remaining.items) do
		local source, target, moveError = Inventory.move(
			remaining,
			nextCarried,
			catalog,
			id,
			remaining.items[id].quantity,
			id,
			remaining.version,
			nextCarried.version
		)
		if not source or not target then
			return nil, nil, moveError
		end
		remaining, nextCarried = source, target
	end
	nextState.bundles[deathId] = nil
	return nextState, nextCarried, nil
end

function M.save(state: State): any
	local saved: any = M.snapshot(state)
	saved.saveVersion = 1
	for id, bundle in state.bundles do
		saved.bundles[id].inventory = Inventory.save(bundle.inventory)
	end
	return saved
end

function M.fromSave(raw: any, catalog: Catalog.Catalog): State
	assert(type(raw) == "table" and raw.saveVersion == 1, "UNSUPPORTED_DEATH_SAVE")
	local state = M.new(raw.ownerId, raw.serverId, raw.carriedId, raw.clockMillis)
	assert(Catalog.integer(raw.lastSequence, 0, 2 ^ 53 - 2), "INVALID_DEATH_SEQUENCE")
	assert(type(raw.bundles) == "table" and #ids(raw.bundles) <= 8, "INVALID_BUNDLES")
	state.lastSequence = raw.lastSequence
	local owned = {}
	for id, bundle in raw.bundles do
		local sequence = tonumber(string.match(id, "^death:(%d+)$"))
		assert(
			sequence and Catalog.integer(sequence, 1, state.lastSequence) and id == "death:" .. tostring(sequence),
			"INVALID_DEATH_ID"
		)
		assert(Catalog.integer(bundle.expiresMillis, 0, 2 ^ 53 - 1), "INVALID_EXPIRY")
		local inventory = Inventory.fromSave(bundle.inventory, catalog)
		assert(inventory.id == id and not next(inventory.reservations), "INVALID_BUNDLE_INVENTORY")
		for itemId in inventory.items do
			assert(not owned[itemId], "DUPLICATE_ITEM_ID")
			owned[itemId] = true
		end
		state.bundles[id] = { expiresMillis = bundle.expiresMillis, inventory = inventory }
	end
	return state
end

return M
