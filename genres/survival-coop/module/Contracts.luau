--!strict
-- Contracts: pure per-player contract board (plan §9.3).
--
-- * First day: the catalog's three fixed `firstDay` contracts, in authored
--   order. Delivering all three opens the long-term board.
-- * Board: `dailyCount` contracts per day drawn from the daily pool with
--   `Rng.new(seed):fork("contract")`, seed = player id hash + day key. The same
--   player on the same day always sees the same board.
-- * Swap: replaces one unaccepted daily slot; gated by `swapCooldownMillis` on
--   the injected clock.
-- * Trust: integer per faction, five tiers from the catalog thresholds.
-- * Sponsor bundles: fixed item lists per tier, claimable once. No chance.
--
-- Time is always a parameter (`nowMillis`). The module never debits or credits
-- inventory: `deliver` and `claimBundle` return the exact quantities for the
-- authoritative command to apply.

local Content = require("../../../core/domain/survival/Content")
local Rng = require("../../../core/domain/random/Rng")

local M = {}

export type Catalog = Content.ContractCatalog
export type Phase = "first-day" | "board"
export type Slot = { id: string, accepted: boolean }
export type State = {
	playerId: string,
	phase: Phase,
	firstDayDone: { [string]: boolean },
	accepted: { [string]: boolean },
	dayKey: number?,
	daily: { Slot },
	swaps: number,
	swapReadyAt: number,
	delivered: number,
	trust: { [string]: number },
	claimed: { [string]: boolean },
}
export type Delivery = {
	consume: { Content.Quantity },
	reward: { Content.Quantity },
	faction: string,
	trust: number,
	tierBefore: number,
	tierAfter: number,
	boardOpened: boolean,
}

local TWO_20 = 1048576
local MAX_CLOCK = 2 ^ 53 - 1

local function hash32(text: string): number
	local hash = 2166136261
	for index = 1, #text do
		local mixed = bit32.bxor(hash, string.byte(text, index))
		-- FNV prime 16777619 = 2^24 + 403, split so every product stays exact.
		hash = (bit32.lshift(mixed, 24) + mixed * 403) % 4294967296
	end
	return hash
end

local function clock(nowMillis: number)
	assert(
		type(nowMillis) == "number" and nowMillis % 1 == 0 and nowMillis >= 0 and nowMillis <= MAX_CLOCK,
		"INVALID_CLOCK"
	)
end

local function entry(catalog: Catalog, id: string): Content.ContractEntry?
	for _, candidate in catalog.entries do
		if candidate.id == id then
			return candidate
		end
	end
	return nil
end

local function faction(catalog: Catalog, id: string): Content.Faction?
	for _, candidate in catalog.factions do
		if candidate.id == id then
			return candidate
		end
	end
	return nil
end

local function copy(list: { Content.Quantity }): { Content.Quantity }
	local result: { Content.Quantity } = {}
	for _, quantity in list do
		table.insert(result, { item = quantity.item, quantity = quantity.quantity })
	end
	return result
end

--- Day key of an injected clock: whole `dayMillis` periods since epoch 0.
function M.dayKey(catalog: Catalog, nowMillis: number): number
	clock(nowMillis)
	return nowMillis // catalog.dayMillis
end

--- Seed for one player's board on one day. The player hash occupies the high
--- bits and the day key the low 20 bits, so the result stays a safe integer.
function M.seed(playerId: string, dayKey: number): number
	assert(type(playerId) == "string" and #playerId > 0, "INVALID_PLAYER")
	assert(type(dayKey) == "number" and dayKey % 1 == 0 and dayKey >= 0, "INVALID_DAY")
	return hash32(playerId) * TWO_20 + dayKey % TWO_20
end

local function dailyPool(catalog: Catalog): { string }
	local pool: { string } = {}
	for _, candidate in catalog.entries do
		if candidate.pool == "daily" then
			table.insert(pool, candidate.id)
		end
	end
	table.sort(pool)
	return pool
end

local function stream(playerId: string, dayKey: number): Rng.Rng
	return Rng.new(M.seed(playerId, dayKey)):fork("contract")
end

--- The day's contract ids, before any swap. Deterministic per player and day.
function M.roll(catalog: Catalog, playerId: string, dayKey: number): { string }
	local pool = dailyPool(catalog)
	local rng = stream(playerId, dayKey)
	local picked: { string } = {}
	for index = 1, math.min(catalog.dailyCount, #pool) do
		local chosen = rng:nextInteger(index, #pool)
		pool[index], pool[chosen] = pool[chosen], pool[index]
		table.insert(picked, pool[index])
	end
	return picked
end

function M.new(playerId: string): State
	assert(type(playerId) == "string" and #playerId > 0, "INVALID_PLAYER")
	return {
		playerId = playerId,
		phase = "first-day",
		firstDayDone = {},
		accepted = {},
		dayKey = nil,
		daily = {},
		swaps = 0,
		swapReadyAt = 0,
		delivered = 0,
		trust = {},
		claimed = {},
	}
end

--- Rolls the board for a new day. First-day state and same-day state are left
--- untouched, so a rejoin on the same day sees the same slots and swaps.
function M.refresh(state: State, catalog: Catalog, nowMillis: number)
	if state.phase ~= "board" then
		return
	end
	local day = M.dayKey(catalog, nowMillis)
	if state.dayKey == day then
		return
	end
	state.dayKey = day
	state.swaps = 0
	state.daily = {}
	for _, id in M.roll(catalog, state.playerId, day) do
		table.insert(state.daily, { id = id, accepted = false })
	end
end

--- Contract ids the player can currently see, in display order.
function M.offers(state: State, catalog: Catalog, nowMillis: number): { string }
	M.refresh(state, catalog, nowMillis)
	local ids: { string } = {}
	if state.phase == "first-day" then
		for _, id in catalog.firstDay do
			if not state.firstDayDone[id] then
				table.insert(ids, id)
			end
		end
	else
		for _, slot in state.daily do
			table.insert(ids, slot.id)
		end
	end
	return ids
end

function M.accept(state: State, catalog: Catalog, id: string, nowMillis: number): (boolean, string?)
	if not table.find(M.offers(state, catalog, nowMillis), id) then
		return false, "NOT_OFFERED"
	end
	if state.accepted[id] then
		return false, "ALREADY_ACCEPTED"
	end
	if state.phase == "first-day" then
		-- First-day contracts are taught one at a time, in authored order.
		for _, earlier in catalog.firstDay do
			if earlier == id then
				break
			end
			if not state.firstDayDone[earlier] then
				return false, "OUT_OF_ORDER"
			end
		end
	end
	state.accepted[id] = true
	for _, slot in state.daily do
		if slot.id == id then
			slot.accepted = true
		end
	end
	return true, nil
end

function M.tier(catalog: Catalog, factionId: string, trust: number): number
	local found = faction(catalog, factionId)
	assert(found ~= nil, "UNKNOWN_FACTION")
	local tier = 1
	for index, threshold in found.trustThresholds do
		if trust >= threshold then
			tier = index
		end
	end
	return tier
end

--- Delivers an accepted contract when `held` covers every required quantity.
--- Returns the exact consume/reward lists; the caller applies them atomically.
function M.deliver(
	state: State,
	catalog: Catalog,
	id: string,
	held: { [string]: number },
	nowMillis: number
): (Delivery?, string?)
	clock(nowMillis)
	if not state.accepted[id] then
		return nil, "NOT_ACCEPTED"
	end
	local found = entry(catalog, id)
	if found == nil then
		return nil, "UNKNOWN_CONTRACT"
	end
	for _, need in found.deliver do
		if (held[need.item] or 0) < need.quantity then
			return nil, "INSUFFICIENT_ITEMS"
		end
	end
	local before = state.trust[found.faction] or 0
	local tierBefore = M.tier(catalog, found.faction, before)
	state.trust[found.faction] = before + found.trust
	state.accepted[id] = nil
	state.delivered += 1
	local boardOpened = false
	if state.phase == "first-day" then
		state.firstDayDone[id] = true
		local all = true
		for _, fixed in catalog.firstDay do
			all = all and state.firstDayDone[fixed] == true
		end
		if all then
			state.phase = "board"
			boardOpened = true
			M.refresh(state, catalog, nowMillis)
		end
	else
		for index, slot in state.daily do
			if slot.id == id then
				table.remove(state.daily, index)
				break
			end
		end
	end
	return {
		consume = copy(found.deliver),
		reward = copy(found.reward),
		faction = found.faction,
		trust = state.trust[found.faction],
		tierBefore = tierBefore,
		tierAfter = M.tier(catalog, found.faction, state.trust[found.faction]),
		boardOpened = boardOpened,
	},
		nil
end

--- Replaces one unaccepted daily slot with an unseen daily contract. The draw
--- is a labelled fork of the day's stream, so it replays exactly.
function M.swap(state: State, catalog: Catalog, slotIndex: number, nowMillis: number): (string?, string?)
	M.refresh(state, catalog, nowMillis)
	if state.phase ~= "board" then
		return nil, "BOARD_LOCKED"
	end
	local slot = state.daily[slotIndex]
	if slot == nil then
		return nil, "UNKNOWN_SLOT"
	end
	if slot.accepted then
		return nil, "SLOT_ACCEPTED"
	end
	if nowMillis < state.swapReadyAt then
		return nil, "SWAP_COOLDOWN"
	end
	local showing: { [string]: boolean } = {}
	for _, other in state.daily do
		showing[other.id] = true
	end
	local candidates: { string } = {}
	for _, id in dailyPool(catalog) do
		if not showing[id] then
			table.insert(candidates, id)
		end
	end
	if #candidates == 0 then
		return nil, "POOL_EXHAUSTED"
	end
	state.swaps += 1
	local rng = stream(state.playerId, state.dayKey :: number):fork("swap:" .. state.swaps)
	slot.id = candidates[rng:nextInteger(1, #candidates)]
	state.swapReadyAt = nowMillis + catalog.swapCooldownMillis
	return slot.id, nil
end

--- Fixed sponsor bundle for a reached tier, claimable once per faction tier.
function M.claimBundle(
	state: State,
	catalog: Catalog,
	factionId: string,
	tier: number
): ({ Content.Quantity }?, string?)
	local found = faction(catalog, factionId)
	if found == nil then
		return nil, "UNKNOWN_FACTION"
	end
	if M.tier(catalog, factionId, state.trust[factionId] or 0) < tier then
		return nil, "TIER_LOCKED"
	end
	local key = factionId .. ":" .. tostring(tier)
	if state.claimed[key] then
		return nil, "ALREADY_CLAIMED"
	end
	for _, bundle in found.bundles do
		if bundle.tier == tier then
			state.claimed[key] = true
			return copy(bundle.items), nil
		end
	end
	return nil, "NO_BUNDLE"
end

function M.toSave(state: State): any
	local daily = {}
	for _, slot in state.daily do
		table.insert(daily, { id = slot.id, accepted = slot.accepted })
	end
	return {
		playerId = state.playerId,
		phase = state.phase,
		firstDayDone = table.clone(state.firstDayDone),
		accepted = table.clone(state.accepted),
		dayKey = state.dayKey,
		daily = daily,
		swaps = state.swaps,
		swapReadyAt = state.swapReadyAt,
		delivered = state.delivered,
		trust = table.clone(state.trust),
		claimed = table.clone(state.claimed),
	}
end

function M.fromSave(saved: any): State
	local state = M.new(saved.playerId)
	state.phase = if saved.phase == "board" then "board" else "first-day"
	state.firstDayDone = table.clone(saved.firstDayDone or {})
	state.accepted = table.clone(saved.accepted or {})
	state.dayKey = saved.dayKey
	for _, slot in saved.daily or {} do
		table.insert(state.daily, { id = slot.id, accepted = slot.accepted == true })
	end
	state.swaps = saved.swaps or 0
	state.swapReadyAt = saved.swapReadyAt or 0
	state.delivered = saved.delivered or 0
	state.trust = table.clone(saved.trust or {})
	state.claimed = table.clone(saved.claimed or {})
	return state
end

return M
