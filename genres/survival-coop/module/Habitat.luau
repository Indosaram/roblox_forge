--!strict
-- Habitat: clock-driven respawn of wildlife into fixed habitat slots.
-- Copy-on-write and clock-free: the caller passes `now` and the live NPC count,
-- and receives which slots may spawn. A slot refills `respawnMillis` after its
-- occupant died; the world budget is never exceeded, so a full world defers
-- the respawn instead of over-spawning.
local Wildlife = require("./Wildlife")
local M = {}
M.MAXIMUM = 32
export type Slot = {
	id: string,
	kind: string,
	home: Wildlife.Position,
	respawnMillis: number,
	occupant: string?,
	vacatedAt: number?,
	generation: number,
}

local function integer(n: any, low: number, high: number): boolean
	return type(n) == "number" and n == n and n % 1 == 0 and n >= low and n <= high
end

--- A new, empty slot: due immediately (first population).
function M.slot(id: string, kind: string, home: Wildlife.Position, respawnMillis: number): Slot
	assert(#id > 0 and #id <= 48 and #kind > 0, "INVALID_SLOT")
	assert(integer(respawnMillis, 1, 86400000), "INVALID_RESPAWN")
	return {
		id = id,
		kind = kind,
		home = table.clone(home),
		respawnMillis = respawnMillis,
		vacatedAt = nil,
		generation = 0,
	}
end

--- Marks the slot's occupant dead at `now`.
function M.vacate(slot: Slot, occupant: string, now: number): Slot
	assert(integer(now, 0, 2 ^ 53 - 1), "INVALID_CLOCK")
	assert(slot.occupant == occupant, "NOT_OCCUPANT")
	local nextSlot = table.clone(slot)
	nextSlot.home = table.clone(slot.home)
	nextSlot.occupant, nextSlot.vacatedAt = nil, now
	return nextSlot
end

--- Fills the slot; the NPC id is deterministic (`<slot>#<generation>`).
function M.fill(slot: Slot, now: number): (Slot, string)
	assert(slot.occupant == nil and M.ready(slot, now), "SLOT_NOT_READY")
	local nextSlot = table.clone(slot)
	nextSlot.home = table.clone(slot.home)
	nextSlot.generation += 1
	nextSlot.occupant = slot.id .. "#" .. tostring(nextSlot.generation)
	nextSlot.vacatedAt = nil
	return nextSlot, nextSlot.occupant :: string
end

function M.ready(slot: Slot, now: number): boolean
	assert(integer(now, 0, 2 ^ 53 - 1), "INVALID_CLOCK")
	if slot.occupant ~= nil then
		return false
	end
	return slot.vacatedAt == nil or now >= slot.vacatedAt + slot.respawnMillis
end

--- Slot ids due at `now`, earliest-vacated first (then id), truncated to the
--- free world budget `maximum - live`.
function M.due(slots: { Slot }, now: number, live: number, maximum: number?): { string }
	local cap = maximum or M.MAXIMUM
	assert(integer(cap, 1, M.MAXIMUM) and integer(live, 0, cap), "INVALID_NPC_BUDGET")
	local ready: { Slot } = {}
	for _, slot in slots do
		if M.ready(slot, now) then
			table.insert(ready, slot)
		end
	end
	table.sort(ready, function(a, b)
		local left, right = a.vacatedAt or -1, b.vacatedAt or -1
		return if left == right then a.id < b.id else left < right
	end)
	local ids: { string } = {}
	for index = 1, math.min(#ready, cap - live) do
		table.insert(ids, ready[index].id)
	end
	return ids
end

return M
