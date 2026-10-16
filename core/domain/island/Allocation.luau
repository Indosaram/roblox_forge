--!strict
-- Allocation: deterministic island allocator (plan §11.5, QA-SPIKE-01/02).
--
-- Given an occupancy snapshot and a batch of arrivals it:
--   1. rebalances islands that are already over their kind's capacity by
--      moving the excess to same-kind islands with room (or new instances),
--   2. places arrivals into existing instances under the cap, then into new
--      instances while the creation budget lasts, then into a queue.
-- No player is ever dropped: every snapshot player and every arrival ends up
-- on exactly one island or in the queue. Ties are broken with an Rng fork so
-- the same (snapshot, arrivals, seed) always gives the same plan.
--
-- Player-facing text never carries island or player ids (plan SYS-198): use
-- Allocation.playerMessage, which returns a localization key plus numeric
-- params only.

local Rng = require("../random/Rng")
local Topology = require("./Topology")

local Allocation = {}

type Kind = Topology.Kind
type Rng = Rng.Rng

export type Island = { id: string, kind: Kind, players: { string } }
export type Arrival = { player: string, kind: Kind }
export type Move = { player: string, from: string, to: string }
export type Assignment = { player: string, island: string }
export type QueueEntry = { player: string, kind: Kind, position: number }
export type Options = {
	topology: Topology.Topology?,
	-- How many new instances arrivals may open in this pass (nil = unlimited).
	-- Rebalancing an overfull island may always open instances so the cap holds.
	maxNewInstances: number?,
}
export type Plan = {
	moves: { Move },
	assignments: { Assignment },
	newInstances: { Island },
	queue: { QueueEntry },
	islands: { Island },
}
export type Message = { key: string, params: { [string]: number } }

local function fail(message: string): never
	error("invalid allocation input: " .. message)
end

local function isNonEmptyString(value: any): boolean
	return type(value) == "string" and #value > 0
end

local function copyIslands(snapshot: { Island }): ({ Island }, { [string]: Island })
	if type(snapshot) ~= "table" then
		fail("snapshot must be a list")
	end
	local islands: { Island } = {}
	local byId: { [string]: Island } = {}
	local seenPlayers: { [string]: boolean } = {}
	for _, island in snapshot do
		if type(island) ~= "table" or not isNonEmptyString(island.id) then
			fail("island id")
		end
		if byId[island.id] then
			fail("duplicate island id")
		end
		if not Topology.isKind(island.kind) then
			fail("island kind")
		end
		if type(island.players) ~= "table" then
			fail("island players")
		end
		local players = {}
		for _, player in island.players do
			if not isNonEmptyString(player) then
				fail("player id")
			end
			if seenPlayers[player] then
				fail("player on two islands")
			end
			seenPlayers[player] = true
			table.insert(players, player)
		end
		table.sort(players)
		local copy: Island = { id = island.id, kind = island.kind, players = players }
		table.insert(islands, copy)
		byId[copy.id] = copy
	end
	table.sort(islands, function(a, b)
		return a.id < b.id
	end)
	return islands, byId
end

-- Picks the destination for one player among same-kind islands with room:
-- the fullest island under the cap (keeps instances packed); equal loads are
-- broken by the rng. Returns nil when none has room.
local function pickDestination(islands: { Island }, kind: Kind, cap: number, exclude: Island?, rng: Rng): Island?
	local best: { Island } = {}
	local bestLoad = -1
	for _, island in islands do
		if island.kind == kind and island ~= exclude and #island.players < cap then
			local load = #island.players
			if load > bestLoad then
				best = { island }
				bestLoad = load
			elseif load == bestLoad then
				table.insert(best, island)
			end
		end
	end
	if #best == 0 then
		return nil
	end
	if #best == 1 then
		return best[1]
	end
	return best[rng:nextInteger(1, #best)]
end

-- Fisher-Yates over a sorted copy: which excess players move is seeded.
local function shuffled(list: { string }, rng: Rng): { string }
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = rng:nextInteger(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

function Allocation.allocate(snapshot: { Island }, arrivals: { Arrival }, seed: number, options: Options?): Plan
	local opts: Options = options or {}
	local topology = opts.topology or Topology.new()
	local budget = opts.maxNewInstances
	if budget ~= nil and (type(budget) ~= "number" or budget < 0 or budget ~= math.floor(budget)) then
		fail("maxNewInstances")
	end
	local islands, byId = copyIslands(snapshot)
	if type(arrivals) ~= "table" then
		fail("arrivals must be a list")
	end
	local present: { [string]: boolean } = {}
	for _, island in islands do
		for _, player in island.players do
			present[player] = true
		end
	end
	for _, arrival in arrivals do
		if type(arrival) ~= "table" or not isNonEmptyString(arrival.player) then
			fail("arrival player")
		end
		if not Topology.isKind(arrival.kind) then
			fail("arrival kind")
		end
		if present[arrival.player] then
			fail("arrival already placed")
		end
		present[arrival.player] = true
	end

	local root = Rng.new(seed):fork("island-allocation")
	local rebalanceRng = root:fork("rebalance")
	local arrivalRng = root:fork("arrival")

	local plan: Plan = { moves = {}, assignments = {}, newInstances = {}, queue = {}, islands = islands }
	local created: { [Kind]: number } = {}

	local function openInstance(kind: Kind): Island
		local n = (created[kind] or 0) + 1
		created[kind] = n
		local id = "new:" .. kind .. ":" .. n
		while byId[id] do
			n += 1
			created[kind] = n
			id = "new:" .. kind .. ":" .. n
		end
		local island: Island = { id = id, kind = kind, players = {} }
		table.insert(islands, island)
		table.insert(plan.newInstances, island)
		byId[id] = island
		return island
	end

	-- 1. Rebalance overfull islands (iterate the sorted original list only).
	local originals = table.clone(islands)
	for _, island in originals do
		local cap = Topology.capacity(topology, island.kind)
		local excess = #island.players - cap
		if excess > 0 then
			local order = shuffled(island.players, rebalanceRng)
			local stay: { string } = {}
			for i = 1, cap do
				table.insert(stay, order[i])
			end
			table.sort(stay)
			island.players = stay
			for i = cap + 1, #order do
				local player = order[i]
				local target = pickDestination(islands, island.kind, cap, island, rebalanceRng)
					or openInstance(island.kind)
				table.insert(target.players, player)
				table.insert(plan.moves, { player = player, from = island.id, to = target.id })
			end
		end
	end

	-- 2. Place arrivals in given order (arrival order is the fairness order).
	local opened = 0
	for _, arrival in arrivals do
		local cap = Topology.capacity(topology, arrival.kind)
		local target = pickDestination(islands, arrival.kind, cap, nil, arrivalRng)
		if target == nil and (budget == nil or opened < budget) then
			opened += 1
			target = openInstance(arrival.kind)
		end
		if target then
			table.insert(target.players, arrival.player)
			table.insert(plan.assignments, { player = arrival.player, island = target.id })
		else
			table.insert(plan.queue, { player = arrival.player, kind = arrival.kind, position = #plan.queue + 1 })
		end
	end

	for _, island in islands do
		table.sort(island.players)
	end
	return plan
end

-- Total players placed on islands plus queued; used to prove nobody is lost.
function Allocation.headcount(plan: Plan): number
	local total = #plan.queue
	for _, island in plan.islands do
		total += #island.players
	end
	return total
end

-- Player-facing approximation of a measured queue position. Small positions
-- are exact; larger ones round up to a coarser bucket so the UI never shows a
-- fixed fake number nor false precision.
function Allocation.approximatePosition(position: number): number
	if type(position) ~= "number" or position < 1 or position ~= math.floor(position) then
		error("invalid position")
	end
	if position <= 5 then
		return position
	elseif position <= 50 then
		return math.ceil(position / 5) * 5
	end
	return math.ceil(position / 10) * 10
end

local MESSAGE_KEYS: { [string]: string } = {
	queued = "island.queue.waiting",
	assigned = "island.travel.assigned",
	moved = "island.travel.rebalanced",
	full = "island.error.full",
	invalid_transition = "island.error.invalid_route",
	route_expired = "island.error.route_expired",
	internal = "island.error.generic",
}

-- Returns a localization key and numeric-only params. Unknown codes collapse
-- to the generic error key; ids and raw internal text are never passed through.
-- `admitPerMinute` is the measured admission rate for the queue estimate.
function Allocation.playerMessage(code: string, position: number?, admitPerMinute: number?): Message
	local key = MESSAGE_KEYS[code] or MESSAGE_KEYS.internal
	local params: { [string]: number } = {}
	if code == "queued" and position ~= nil then
		params.approxPosition = Allocation.approximatePosition(position)
		if type(admitPerMinute) == "number" and admitPerMinute > 0 then
			params.approxMinutes = math.max(1, math.ceil(position / admitPerMinute))
		end
	end
	return { key = key, params = params }
end

return Allocation
