--!strict
-- spikesim: QA-SPIKE-01 layer 1 (plan §12, M6). A Lune join-spike simulation:
-- N virtual players arrive at seeded times and are fed, tick by tick, through
-- the pure island Allocation (core/domain/island/Allocation) and a lease-fenced
-- roster per island. Each island is one writer: its roster is a delta on the
-- island's core/infra/island/Lease (FencedStore on a shared in-memory backend),
-- so every admission, move and friend-follow join is a fenced write that can
-- fail (seeded throttling) and must be recovered without losing anyone.
--
-- Time is an injected integer clock in simulated seconds; nothing sleeps and
-- nothing reads wall-clock time. All randomness comes from Rng forks of the
-- recorded seed, so (options, seed) always gives the same report.
--
-- The report carries the wait-latency distribution (p50/p95/max simulated
-- seconds), lost players, overfull islands, split-brain lease acquisitions,
-- and a scan of every player-facing message for internal ids, stack traces
-- and SQL/backend text (SYS-198).

local Rng = require("../../../core/domain/random/Rng")
local Topology = require("../../../core/domain/island/Topology")
local Allocation = require("../../../core/domain/island/Allocation")
local FencedStore = require("../../../core/infra/data/FencedStore")
local Lease = require("../../../core/infra/island/Lease")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")

local M = {}

-- p95 wait target in simulated seconds for N=64 (신규 산정: first estimate for
-- QA-SPIKE-01, to be revisited after the M6 staging sample, plan §12 layer 2).
M.TARGET_P95_SECONDS = 12
M.DEFAULT_PLAYERS = 64
M.DEFAULT_SEED = 1

export type Options = {
	players: number?,
	seed: number?,
	-- Arrivals land uniformly in [0, windowSeconds] (the spike).
	windowSeconds: number?,
	-- The allocator runs once per tick (integer simulated seconds).
	tickSeconds: number?,
	-- New island instances the allocator may open per tick (ReserveServer rate).
	maxNewInstancesPerTick: number?,
	-- Simulated seconds before a freshly opened instance accepts players.
	instanceStartSeconds: number?,
	-- Share of arrivals that follow a friend straight onto an occupied island,
	-- bypassing the allocator (the source of overfull islands).
	directJoinRate: number?,
	-- Chance that one fenced commit is throttled by the backend.
	throttleRate: number?,
	leaseSeconds: number?,
	maxTicks: number?,
	kind: string?,
	capacity: { [string]: number }?,
	-- Injected flag: false drops the allocator's rebalance moves (negative case).
	rebalance: boolean?,
	-- Injected flag: true puts raw backend errors and island ids into the
	-- player-facing error message (negative case for the SYS-198 scan).
	rawErrorMessages: boolean?,
}

export type Message = { key: string, params: { [string]: number }, detail: string? }

export type Report = {
	schemaVersion: number,
	seed: number,
	players: number,
	kind: string,
	capacity: number,
	rebalance: boolean,
	ticks: number,
	islands: number,
	wait: { p50: number, p95: number, max: number, admitted: number },
	targetP95: number,
	lost: number,
	duplicated: number,
	unadmitted: number,
	overfull: number,
	overfullPeak: number,
	splitBrain: number,
	throttled: number,
	directJoins: number,
	moves: number,
	messages: number,
	leaks: number,
	leakReasons: { string },
	ok: boolean,
	failures: { string },
}

local function positiveInt(value: any, default: number, name: string): number
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value < 1 or value ~= math.floor(value) then
		error("invalid spikesim option " .. name)
	end
	return value
end

local function nonNegativeInt(value: any, default: number, name: string): number
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value < 0 or value ~= math.floor(value) then
		error("invalid spikesim option " .. name)
	end
	return value
end

local function rate(value: any, default: number, name: string): number
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value ~= value or value < 0 or value > 1 then
		error("invalid spikesim option " .. name)
	end
	return value
end

local function round3(value: number): number
	return math.floor(value * 1000 + 0.5) / 1000
end

-- Nearest-rank percentile over an ascending list.
function M.percentile(sorted: { number }, p: number): number
	if #sorted == 0 then
		return 0
	end
	local rank = math.max(1, math.ceil(p * #sorted))
	return sorted[math.min(rank, #sorted)]
end

-- Internal-text patterns that must never reach a player (SYS-198).
local FORBIDDEN_PATTERNS: { { pattern: string, reason: string } } = {
	{ pattern = "[Ss][Qq][Ll]", reason = "sql" },
	{ pattern = "[Dd]eadlock", reason = "deadlock" },
	{ pattern = "[Tt]raceback", reason = "stack" },
	{ pattern = "[Ss]tack", reason = "stack" },
	{ pattern = "%.luau?:%d+", reason = "stack" },
	{ pattern = "[Tt]hrottled", reason = "backend" },
	{ pattern = "[Ll]ease lost", reason = "backend" },
	{ pattern = "[Ll]ocked", reason = "backend" },
}

local function messageText(message: Message): string
	local parts = { message.key }
	local names = {}
	for name in message.params do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		table.insert(parts, name .. "=" .. tostring(message.params[name]))
	end
	if message.detail ~= nil then
		table.insert(parts, message.detail)
	end
	return table.concat(parts, " ")
end

-- Scans player-facing messages for internal ids (any player or island id
-- known to the run) and internal error text. Returns the leak count and the
-- sorted distinct reasons; the offending text itself is never echoed.
function M.scanMessages(messages: { Message }, internalIds: { string }): (number, { string })
	local leaks = 0
	local reasons: { [string]: boolean } = {}
	for _, message in messages do
		local text = messageText(message)
		local leaked = false
		for _, id in internalIds do
			if string.find(text, id, 1, true) then
				leaked = true
				reasons.internal_id = true
				break
			end
		end
		for _, rule in FORBIDDEN_PATTERNS do
			if string.find(text, rule.pattern) then
				leaked = true
				reasons[rule.reason] = true
			end
		end
		if leaked then
			leaks += 1
		end
	end
	local list = {}
	for reason in reasons do
		table.insert(list, reason)
	end
	table.sort(list)
	return leaks, list
end

type PlayerState = {
	id: string,
	arrivalMs: number,
	direct: boolean,
	friend: number?,
	arrived: boolean,
	waitSeconds: number?,
}

type Server = {
	store: FencedStore.Store,
	lease: Lease.Lease,
	handle: Lease.Handle,
}

-- The roster is the payload of the island's latest "roster" delta.
local function rosterOf(profile: FencedStore.Profile): { string }
	local list: { string } = {}
	local deltas = profile.data.deltas
	if type(deltas) == "table" and #deltas > 0 then
		local players = deltas[#deltas].payload.players
		for _, player in players do
			table.insert(list, player)
		end
	end
	table.sort(list)
	return list
end

local function setOf(list: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, item in list do
		set[item] = true
	end
	return set
end

local function sameList(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for index = 1, #a do
		if a[index] ~= b[index] then
			return false
		end
	end
	return true
end

function M.run(options: Options?): Report
	local opts: Options = options or {}
	local playerCount = positiveInt(opts.players, M.DEFAULT_PLAYERS, "players")
	local seed = nonNegativeInt(opts.seed, M.DEFAULT_SEED, "seed")
	local windowSeconds = nonNegativeInt(opts.windowSeconds, 10, "windowSeconds")
	local tickSeconds = positiveInt(opts.tickSeconds, 1, "tickSeconds")
	local budget = nonNegativeInt(opts.maxNewInstancesPerTick, 2, "maxNewInstancesPerTick")
	local startSeconds = nonNegativeInt(opts.instanceStartSeconds, 2, "instanceStartSeconds")
	local directRate = rate(opts.directJoinRate, 0.25, "directJoinRate")
	local throttleRate = rate(opts.throttleRate, 0.05, "throttleRate")
	local leaseSeconds = positiveInt(opts.leaseSeconds, 60, "leaseSeconds")
	local maxTicks = positiveInt(opts.maxTicks, 600, "maxTicks")
	local kind = opts.kind or "landing"
	if not Topology.isKind(kind) then
		error("invalid spikesim option kind")
	end
	local rebalance = opts.rebalance ~= false
	local rawErrors = opts.rawErrorMessages == true
	local topology = Topology.new(opts.capacity)
	local cap = Topology.capacity(topology, kind)

	local root = Rng.new(seed):fork("spikesim")
	local arrivalRng = root:fork("arrival")
	local directRng = root:fork("direct")
	local throttleRng = root:fork("throttle")

	-- Arrivals, sorted by time (ties by id) so arrival order is deterministic.
	local players: { PlayerState } = {}
	for index = 1, playerCount do
		local direct = index > 1 and directRng:nextNumber() < directRate
		table.insert(players, {
			id = string.format("player-%04d", index),
			arrivalMs = arrivalRng:nextInteger(0, windowSeconds * 1000),
			direct = direct,
			friend = if direct then directRng:nextInteger(1, index - 1) else nil,
			arrived = false,
			waitSeconds = nil,
		})
	end
	local byId: { [string]: PlayerState } = {}
	for _, player in players do
		byId[player.id] = player
	end
	local ordered = table.clone(players)
	table.sort(ordered, function(a, b)
		if a.arrivalMs ~= b.arrivalMs then
			return a.arrivalMs < b.arrivalMs
		end
		return a.id < b.id
	end)

	local now = 0
	local backend = MemoryBackend.new()
	local servers: { [string]: Server } = {}
	local islandIds: { string } = {}
	local knownIds: { [string]: boolean } = {}
	local queue: { string } = {}
	local messages: { Message } = {}
	local throttled, splitBrain, directJoins, moveCount = 0, 0, 0, 0
	local overfullPeak = 0
	local admittedCount = 0
	local firstArrivalMs: number? = nil
	local readyAt: { [string]: number } = {}

	local function clock(): number
		return now
	end

	-- Only call right before a commit that is certain to reach the backend.
	local function maybeThrottle()
		if throttleRate > 0 and throttleRng:nextNumber() < throttleRate then
			backend.failNext(1)
			throttled += 1
		end
	end

	local function playerMessage(code: string, position: number?, perMinute: number?): Message
		local base = Allocation.playerMessage(code, position, perMinute)
		return { key = base.key, params = base.params }
	end

	local function failureMessage(reason: string?, islandId: string): Message
		local message = playerMessage("internal")
		if rawErrors then
			message.detail = tostring(reason) .. " on " .. islandId
		end
		return message
	end

	-- Lease island ids are [%w_-]+; allocator ids look like "new:landing:3".
	local function leaseId(islandId: string): string
		return (string.gsub(islandId, "[^%w_%-]", "-"))
	end

	local deltaSeq = 0

	local function commit(islandId: string, roster: { string }): (boolean, string?)
		local server = servers[islandId]
		maybeThrottle()
		deltaSeq += 1
		local nextHandle, err = server.lease:write(server.handle, {
			id = "d" .. deltaSeq,
			op = "roster",
			payload = { players = table.clone(roster) },
		})
		if nextHandle == nil then
			return false, err
		end
		server.handle = nextHandle
		return true, nil
	end

	local function open(islandId: string, roster: { string }): (boolean, string?)
		local store = FencedStore.new(backend, {
			sessionId = "srv-" .. islandId,
			leaseSeconds = leaseSeconds,
			now = clock,
		})
		local lease = Lease.new({ store = store, serverId = "srv-" .. islandId })
		maybeThrottle()
		local handle, err = lease:acquire(leaseId(islandId))
		if handle == nil then
			return false, err
		end
		servers[islandId] = { store = store, lease = lease, handle = handle }
		table.insert(islandIds, islandId)
		readyAt[islandId] = now + startSeconds
		-- A second server racing for the same island must be fenced out.
		local rogueStore = FencedStore.new(backend, {
			sessionId = "rogue-" .. islandId,
			leaseSeconds = leaseSeconds,
			now = clock,
		})
		local rogue = Lease.new({ store = rogueStore, serverId = "rogue-" .. islandId })
		if rogue:acquire(leaseId(islandId)) ~= nil then
			splitBrain += 1
		end
		return commit(islandId, roster)
	end

	local function rosters(): { [string]: { string } }
		local out: { [string]: { string } } = {}
		for _, id in islandIds do
			out[id] = rosterOf(servers[id].handle.profile)
		end
		return out
	end

	local function overfullCount(): number
		local count = 0
		for _, roster in rosters() do
			if #roster > cap then
				count += 1
			end
		end
		return count
	end

	local function admit(player: PlayerState, extraSeconds: number)
		if player.waitSeconds == nil then
			player.waitSeconds = math.max(0, now + extraSeconds - player.arrivalMs / 1000)
			admittedCount += 1
		end
	end

	local nextArrival = 1
	local ticks = 0
	while ticks < maxTicks do
		ticks += 1
		now = ticks * tickSeconds
		local tickMs = now * 1000

		-- 1. Arrivals during this tick. Friend-follow joins go straight onto the
		-- friend's island through its lease, ignoring capacity.
		local fresh: { string } = {}
		while nextArrival <= #ordered and ordered[nextArrival].arrivalMs < tickMs do
			local player = ordered[nextArrival]
			nextArrival += 1
			player.arrived = true
			if firstArrivalMs == nil then
				firstArrivalMs = player.arrivalMs
			end
			local placed = false
			if player.direct and player.friend ~= nil then
				local friend = players[player.friend :: number].id
				for _, islandId in islandIds do
					local roster = rosterOf(servers[islandId].handle.profile)
					if table.find(roster, friend) then
						table.insert(roster, player.id)
						table.sort(roster)
						local ok, err = commit(islandId, roster)
						if ok then
							placed = true
							directJoins += 1
							admit(player, 0)
							table.insert(messages, playerMessage("assigned"))
						else
							table.insert(messages, failureMessage(err, islandId))
						end
						break
					end
				end
			end
			if not placed then
				table.insert(fresh, player.id)
			end
		end

		-- 2. One allocator pass over the committed rosters plus the queue.
		local truth = rosters()
		local snapshot: { Allocation.Island } = {}
		for _, id in islandIds do
			table.insert(snapshot, { id = id, kind = kind, players = truth[id] })
		end
		local arrivals: { Allocation.Arrival } = {}
		for _, id in queue do
			table.insert(arrivals, { player = id, kind = kind })
		end
		for _, id in fresh do
			table.insert(arrivals, { player = id, kind = kind })
		end
		local plan = Allocation.allocate(snapshot, arrivals, seed + ticks, {
			topology = topology,
			maxNewInstances = budget,
		})
		for _, island in plan.islands do
			knownIds[island.id] = true
		end

		-- 3. Target rosters. Without rebalance the moves are dropped and only
		-- the arrival assignments are applied on top of the committed rosters.
		local target: { [string]: { string } } = {}
		local planOrder: { string } = {}
		if rebalance then
			for _, island in plan.islands do
				target[island.id] = table.clone(island.players)
				table.insert(planOrder, island.id)
			end
		else
			for _, id in islandIds do
				target[id] = table.clone(truth[id])
				table.insert(planOrder, id)
			end
			for _, assignment in plan.assignments do
				if target[assignment.island] == nil then
					target[assignment.island] = {}
					table.insert(planOrder, assignment.island)
				end
				table.insert(target[assignment.island], assignment.player)
			end
			for _, id in planOrder do
				table.sort(target[id])
			end
		end
		local moves = if rebalance then plan.moves else {}
		local moveFrom: { [string]: string } = {}
		for _, move in moves do
			moveFrom[move.player] = move.from
		end

		-- 4a. Removals first, so a moved player is never on two islands.
		local stuck: { [string]: boolean } = {}
		for _, id in islandIds do
			local keep = setOf(target[id] or {})
			local reduced: { string } = {}
			local removed: { string } = {}
			for _, player in truth[id] do
				if keep[player] then
					table.insert(reduced, player)
				else
					table.insert(removed, player)
				end
			end
			if #removed > 0 then
				local ok, err = commit(id, reduced)
				if not ok then
					for _, player in removed do
						stuck[player] = true
					end
					table.insert(messages, failureMessage(err, id))
				end
			end
		end

		-- 4b. Additions: a move lands only if its removal committed; a player
		-- whose removal failed stays on its source island.
			for _, id in planOrder do
			local desired: { string } = {}
			for _, player in target[id] do
				if not (stuck[player] and moveFrom[player] ~= id) then
					table.insert(desired, player)
				end
			end
			for player in stuck do
				if moveFrom[player] == id then
					table.insert(desired, player)
				end
			end
			table.sort(desired)
			if servers[id] == nil then
				if #desired > 0 then
					local ok, err = open(id, desired)
					if not ok then
						table.insert(messages, failureMessage(err, id))
					end
				end
			elseif not sameList(desired, rosterOf(servers[id].handle.profile)) then
				local ok, err = commit(id, desired)
				if not ok then
					table.insert(messages, failureMessage(err, id))
				end
			else
				local renewed = servers[id].lease:renew(servers[id].handle)
				if renewed ~= nil then
					servers[id].handle = renewed
				end
			end
		end

		-- 5. Reconcile against what actually committed: everyone arrived and not
		-- on a committed roster is (re)queued in arrival order, never dropped.
		local after = rosters()
		local present: { [string]: string } = {}
		for _, id in islandIds do
			for _, player in after[id] do
				present[player] = id
			end
		end
		for _, move in moves do
			if present[move.player] == move.to then
				moveCount += 1
				table.insert(messages, playerMessage("moved"))
			end
		end
		queue = {}
		for _, player in ordered do
			if player.arrived then
				local island = present[player.id]
				if island == nil then
					table.insert(queue, player.id)
				elseif player.waitSeconds == nil then
					admit(player, math.max(0, (readyAt[island] or 0) - now))
					table.insert(messages, playerMessage("assigned"))
				end
			end
		end
		local elapsedSeconds = now - (firstArrivalMs or 0) / 1000
		local perMinute = if elapsedSeconds > 0 then admittedCount * 60 / elapsedSeconds else nil
		for position in queue do
			table.insert(messages, playerMessage("queued", position, perMinute))
		end

		local overfull = overfullCount()
		overfullPeak = math.max(overfullPeak, overfull)
		if nextArrival > #ordered and #queue == 0 and (overfull == 0 or not rebalance) then
			break
		end
	end

	-- Audit: read every roster back through its lease and reconcile.
	local seen: { [string]: number } = {}
	local finalOverfull = 0
	for _, id in islandIds do
		local server = servers[id]
		local refreshed, err = server.store:refresh(server.handle.profile)
		local profile = refreshed
		if refreshed == nil then
			error("spikesim audit read failed: " .. tostring(err))
		end
		local roster = rosterOf(profile)
		if #roster > cap then
			finalOverfull += 1
		end
		for _, player in roster do
			seen[player] = (seen[player] or 0) + 1
		end
	end
	for _, player in queue do
		seen[player] = (seen[player] or 0) + 1
	end
	local lost, duplicated, unadmitted = 0, 0, 0
	local waits: { number } = {}
	for _, player in players do
		local count = seen[player.id] or 0
		if count == 0 then
			lost += 1
		elseif count > 1 then
			duplicated += 1
		end
		if player.waitSeconds == nil then
			unadmitted += 1
		else
			table.insert(waits, player.waitSeconds :: number)
		end
	end
	table.sort(waits)

	local internalIds: { string } = {}
	for _, player in players do
		table.insert(internalIds, player.id)
	end
	for id in knownIds do
		table.insert(internalIds, id)
	end
	table.sort(internalIds)
	local leaks, leakReasons = M.scanMessages(messages, internalIds)

	local p95 = round3(M.percentile(waits, 0.95))
	local failures: { string } = {}
	if p95 > M.TARGET_P95_SECONDS then
		table.insert(failures, "p95")
	end
	if lost > 0 then
		table.insert(failures, "lost")
	end
	if duplicated > 0 then
		table.insert(failures, "duplicated")
	end
	if unadmitted > 0 then
		table.insert(failures, "unadmitted")
	end
	if finalOverfull > 0 then
		table.insert(failures, "overfull")
	end
	if splitBrain > 0 then
		table.insert(failures, "splitBrain")
	end
	if leaks > 0 then
		table.insert(failures, "leaks")
	end

	return {
		schemaVersion = 1,
		seed = seed,
		players = playerCount,
		kind = kind,
		capacity = cap,
		rebalance = rebalance,
		ticks = ticks,
		islands = #islandIds,
		wait = {
			p50 = round3(M.percentile(waits, 0.5)),
			p95 = p95,
			max = round3(M.percentile(waits, 1)),
			admitted = #waits,
		},
		targetP95 = M.TARGET_P95_SECONDS,
		lost = lost,
		duplicated = duplicated,
		unadmitted = unadmitted,
		overfull = finalOverfull,
		overfullPeak = overfullPeak,
		splitBrain = splitBrain,
		throttled = throttled,
		directJoins = directJoins,
		moves = moveCount,
		messages = #messages,
		leaks = leaks,
		leakReasons = leakReasons,
		ok = #failures == 0,
		failures = failures,
	}
end

return M
