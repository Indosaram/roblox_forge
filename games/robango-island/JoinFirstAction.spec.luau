--!strict
-- Plan D1: the first action a player takes after joining confirms within 10 s (phone v40: the HUD
-- showed at 9-13 s but every press answered "still connecting" until ~25-30 s). The real role
-- world (RoleWorld), SurvivalFactory, SurvivalProvision (public camp) and Session run under the
-- concurrency the live server has: Server.join's retry loop, the 1 Hz heartbeat (advance + a
-- commandState push polling every action's epoch) and the client's press/handshake loop each run
-- in their own thread, over a backend that enforces what a live DataStore does: about one write
-- per key per 6 s (each UpdateAsync waits for its key's slot) plus a round-trip latency.
local serde = require("@lune/serde")
local task = require("@lune/task")
local process = require("@lune/process")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local Clock = require("../../core/infra/genre/Clock")
local FencedStore = require("../../core/infra/data/FencedStore")
local Durable = require("./src/shared/GenreDurable")

local ACTOR = "11734795308"
local BUDGET = 10
local WRITE_INTERVAL = 6
local LATENCY = 0.1
local STEP = 0.05

-- Virtual time; every server-side clock reads it. A thread waits for a time with `waitUntil`;
-- `pump` jumps the clock to the earliest pending wake and lets every thread run once.
type Time = { value: number, wakes: { number } }

local function waitUntil(at: Time, time: number)
	table.insert(at.wakes, time)
	while at.value < time do
		task.wait()
	end
end

local function pump(at: Time)
	local nextWake = math.huge
	local kept = {}
	for _, time in at.wakes do
		if time > at.value then
			table.insert(kept, time)
			nextWake = math.min(nextWake, time)
		end
	end
	at.wakes = kept
	at.value = if nextWake < math.huge then nextWake else at.value + STEP
	task.wait()
end

-- A live DataStore: each UpdateAsync on a key starts no sooner than WRITE_INTERVAL after the
-- previous one on that key started (queued FIFO), and every call yields for a round-trip.
local build: (any, Time, string, string) -> any

local function throttled(at: Time): any
	local memory = Memory.new()
	local nextSlot: { [string]: number } = {}
	local writes: { [string]: number } = {}
	local backend: any = { writes = writes, halted = false }
	function backend.update(key: string, transform: any): (boolean, any)
		local slot = math.max(at.value, nextSlot[key] or 0)
		nextSlot[key] = slot + WRITE_INTERVAL
		writes[key] = (writes[key] or 0) + 1
		if process.env.FORGE_JOIN_TRACE then
			print(string.format("  write %-40s asked %.2f slot %.2f", key, at.value, slot))
			if process.env.FORGE_JOIN_TRACE == "2" then
				local frames = {}
				for line in string.gmatch(debug.traceback("", 2), "[^\n]+") do
					local file, n = string.match(line, "([%w_]+)[%.luau]*:(%d+)")
					if file and file ~= "JoinFirstAction" and not string.find(line, "task") then
						table.insert(frames, file .. ":" .. n)
					end
				end
				print("    " .. table.concat(frames, " < "))
			end
		end
		waitUntil(at, slot + LATENCY)
		if backend.halted then
			return false, "halted"
		end
		if process.env.FORGE_JOIN_DIFF and string.find(key, process.env.FORGE_JOIN_DIFF, 1, true) then
			local before: any = nil
			local ok, after = memory.update(key, function(old)
				before = old
				return transform(old)
			end)
			local function walk(a: any, b: any, path: string)
				if type(a) ~= "table" or type(b) ~= "table" then
					if a ~= b then
						print("    diff " .. path .. ": " .. tostring(a) .. " -> " .. tostring(b))
					end
					return
				end
				for k, v in a do
					walk(v, b[k], path .. "." .. tostring(k))
				end
				for k, v in b do
					if a[k] == nil then
						walk(nil, v, path .. "." .. tostring(k))
					end
				end
			end
			walk(before and before.data, after and after.data, key)
			return ok, after
		end
		return memory.update(key, transform)
	end
	return backend
end

-- Runs fn in its own thread while virtual time advances, until it returns.
local function drive<T>(at: Time, fn: () -> T): T
	local done, ok, value = false, false, nil :: any
	task.spawn(function()
		ok, value = pcall(fn)
		done = true
	end)
	while not done do
		pump(at)
	end
	if not ok then
		error(value, 0)
	end
	return value :: T
end

local function boot(backend: any, at: Time, server: string, layoutId: string): any
	return drive(at, function()
		return build(backend, at, server, layoutId)
	end)
end

function build(backend: any, at: Time, server: string, layoutId: string): any
	local engine = Engine.new(true)
	local forge = engine.forge
	local module = forge.genres["survival-coop"].module
	for _, name in
		{
			"SurvivalBootstrap",
			"Gathering",
			"ToolTiers",
			"GuideEvents",
			"Wildlife",
			"HomeExtension",
			"ArchipelagoExtension",
			"ExpeditionExtension",
			"ProgressionExtension",
			"ProgressionPorts",
			"Extensions",
			"JournalPorts",
			"JournalObjectiveFeed",
			"JournalExtension",
			"RecipeMarks",
			"CarcassExtension",
			"MultistoreyCommands",
		}
	do
		module[name] = (require :: any)("../../genres/survival-coop/module/" .. name)
	end
	forge.core.domain.home = { HomeContent = require("../../core/domain/home/HomeContent") }
	forge.core.domain.settlement = {
		Settlement = require("../../core/domain/settlement/Settlement"),
		Clan = require("../../core/domain/settlement/Clan"),
	}
	forge.core.domain.inventory = {
		Inventory = require("../../core/domain/inventory/Inventory"),
		ItemCatalog = require("../../core/domain/inventory/ItemCatalog"),
	}
	forge.core.domain.crafting = { Job = require("../../core/domain/crafting/Job") }
	forge.core.domain.command = {
		Journal = require("../../core/domain/command/Journal"),
		Ledger = require("../../core/domain/command/Ledger"),
	}
	forge.core.domain.island.Archipelago = require("../../core/domain/island/Archipelago")
	forge.core.domain.island.Topology = require("../../core/domain/island/Topology")
	forge.games["robango-island"].src.shared.TownRuntime = require("./src/shared/TownRuntime")
	forge.core.infra = {
		render = forge.core.infra.render,
		genre = { Clock = Clock, Session = Session },
		data = {
			ActorDocumentStore = require("../../core/infra/data/ActorDocumentStore"),
			ClanStoreWallet = require("../../core/infra/data/ClanStoreWallet"),
			FencedStore = FencedStore,
		},
	}
	local clock = Clock.new(function()
		return at.value
	end)
	local function now(): number
		return math.floor(at.value)
	end
	local world: any = engine.role.build(Content, Source, Policy, function()
		return at.value * 1000
	end, layoutId, 1776)
	local factoryBuilder = engine.load("games/robango-island/src/server/SurvivalFactory.luau", {}, {
		Parent = {
			LateEquipmentPorts = require("./src/server/LateEquipmentPorts"),
			WorldDressing = engine.dressing,
		},
	})
	local provision = engine.load("games/robango-island/src/server/SurvivalProvision.luau", {}, nil)(
		{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
		Source.tribe.config.tribeId,
		{ studio = false, server = server }
	)
	local encode = function(value)
		return serde.encode("json", value)
	end
	local present: { [string]: boolean } = {}
	local arrivedAt: { [string]: number } = {}
	-- The store options RobangoIslandServer passes.
	local options: any = {
		sessionId = server,
		leaseSeconds = 120,
		suppressIdentityUpdates = true,
		leasedReads = true,
		takeover = FencedStore.presentActorTakeover({
			now = now,
			graceSeconds = 5,
			actorOf = function(key)
				local prefix, actor = string.match(key, "^([%w_-]+):(%d+)$")
				local perActor = {
					contracts = true,
					mkt = true,
					mon = true,
					["taming-v1"] = true,
					["robango-exp-v1"] = true,
					home = true,
				}
				return if prefix and perActor[prefix] then actor else nil
			end,
			present = function(actor)
				return present[actor] == true
			end,
			presentSince = function(actor)
				return arrivedAt[actor]
			end,
		}),
		now = now,
		budget = { encode = encode },
	}
	local factory: any = assert(factoryBuilder(Content, Source, world, backend, clock, options, provision, Policy))
	local services = table.clone(factory.services)
	services.now = clock.now
	services.roll = function()
		return 0
	end
	services.emit = function() end
	services.encode = encode
	-- What Server.start passes.
	local session = Session.new(
		{
			packConfig = require("./src/shared/GenreConfig"),
			contracts = { require("../../genres/survival-coop/module/Contract") },
			durable = Durable,
			controls = {},
			storeName = server .. "-personal",
		},
		backend,
		{
			sessionId = server,
			lockTimeout = 120,
			retries = 0,
			now = now,
			leasedReads = true,
			suppressIdentityUpdates = true,
			takeoverSeconds = 5,
		},
		services,
		Durable
	)
	factory.bind(session)
	return {
		engine = engine,
		session = session,
		factory = factory,
		world = world,
		present = present,
		arrivedAt = arrivedAt,
	}
end

-- Server.start's commandState: the epochs every push and handshake carry.
local function commandState(session: any, actor: string): any
	local epochs = {}
	for _, action in Durable.actions do
		epochs[action] = session.commandEpoch(actor, action)
	end
	return { sessionEpoch = session.commandEpoch(actor), epochs = epochs }
end

-- The role's nodes nearest first, by id (the player walks to one and presses).
local function nodes(live: any): { { id: string, position: any } }
	local list = {}
	for _, part in live.engine.parts do
		local id = if part.GetAttribute then part:GetAttribute("ForgeNodeId") else nil
		if type(id) == "string" then
			table.insert(list, { id = id, position = part.Position })
		end
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	assert(#list > 0, "the role has gather nodes")
	return list
end

-- Joins ACTOR at `at.value` and runs the server's threads and the client's press loop. Returns
-- the seconds from the join to the first confirmed gather (nil: none within `limit`) and a log.
-- `hold` (R01 title screen) keeps the client on the title for that many seconds after the join:
-- the server join and heartbeat run meanwhile and the time is counted from the Start tap.
local function measure(live: any, at: Time, limit: number, layoutId: string, hold: number?): (number?, { string })
	local session = live.session
	local log: { string } = {}
	local joinedAt = at.value
	local started = at.value + (hold or 0)
	local function note(text: string)
		table.insert(log, string.format("%6.2f %s", at.value - started, text))
		if process.env.FORGE_JOIN_TRACE then
			print(log[#log], os.clock())
		end
	end
	local function sleep(seconds: number)
		waitUntil(at, at.value + seconds)
	end
	live.present[ACTOR] = true
	live.arrivedAt[ACTOR] = math.floor(at.value)
	local confirmed, running = nil :: number?, true
	-- Server.join: retry a refused join while the player stays.
	task.spawn(function()
		while running do
			local result = session.join(ACTOR)
			if result.ok then
				note("join done" .. (if result.notificationError then " (" .. result.notificationError .. ")" else ""))
				return
			end
			note("join refused: " .. tostring(result.reason))
			sleep(2)
		end
	end)
	-- The handshake (and every push) serves a player once Session lists them as a member, which
	-- happens inside join, before any work the join wrapper does after it.
	local function member(): boolean
		return table.find(session.members(), ACTOR) ~= nil
	end
	-- Server heartbeat: one tick at a time at 1 Hz (advance + push); a tick still running absorbs
	-- the frames that elapse meanwhile.
	task.spawn(function()
		while running do
			sleep(1)
			if member() then
				session.advance(at.value)
				commandState(session, ACTOR)
			end
		end
	end)
	-- The client: a press every second once the HUD is up; without an epoch the press refreshes
	-- the handshake and is refused (GatheringClient.activate).
	-- Onboarding: the first tutorial step, a bare-hand gather. Town has no nodes: a recipe to-do
	-- toggle (a personal-extension command, available everywhere).
	local ACTION = if layoutId == "rw.onboarding" then "survival-coop:gather" else "survival-coop:recipe-mark"
	task.spawn(function()
		local list: { any }? = nil
		local index = 0
		local node: string? = nil
		local sequence = 0
		if hold then
			sleep(hold)
			note("title Start tapped")
		end
		while running and confirmed == nil do
			if member() then
				if list == nil and ACTION == "survival-coop:gather" then
					list = nodes(live)
				end
				if node == nil and list then
					-- A node this player can work bare-handed: refusals that are about the node, not
					-- the connection, move on to the next one.
					index += 1
					local entry = assert((list :: any)[index], "a gatherable node")
					node = entry.id
					live.engine.move(ACTOR, { x = entry.position.X, y = entry.position.Y + 3, z = entry.position.Z })
				end
				local epoch = commandState(session, ACTOR).epochs[ACTION]
				if epoch == nil then
					note("press refused: no epoch (still connecting)")
				else
					sequence += 1
					local args: { any } = if list
						then { node, live.factory.services.survivalGathering.snapshot(ACTOR).version }
						else { Content.recipes[1].id, "todo", true }
					local request =
						{ requestId = "press-" .. sequence, sessionEpoch = epoch, action = ACTION, args = args }
					local result = session.command(ACTOR, request)
					for _ = 1, 4 do
						if
							result.ok == false
							and result.reason == nil
							and result.data
							and result.data.status == "pending"
						then
							result = session.command(ACTOR, request)
						else
							break
						end
					end
					if result.ok then
						confirmed = at.value - started
						note("press confirmed")
						return
					end
					note("press refused: " .. tostring(result.reason))
					if
						result.reason == "TOOL_UNAVAILABLE"
						or result.reason == "LEVEL_LOCKED"
						or result.reason == "SKILL_LOCKED"
						or result.reason == "NODE_UNREACHABLE"
						or result.reason == "NODE_DEPLETED"
						or result.reason == "STALE_VERSION"
					then
						node = nil
						continue
					end
				end
			end
			sleep(1)
		end
	end)
	while confirmed == nil and at.value - joinedAt <= limit + (hold or 0) do
		pump(at)
	end
	running = false
	return confirmed, log
end

-- A previous server held the player and was force-stopped (no close): its leases stay live and
-- its last writes still occupy the per-key slots.
local function forceStopped(at: Time, old: any)
	old.present[ACTOR] = true
	old.arrivedAt[ACTOR] = math.floor(at.value)
	drive(at, function()
		assert(old.session.join(ACTOR).ok, "old server join")
		waitUntil(at, at.value + 10)
		assert(old.session.save(ACTOR).ok, "old server saves")
		return true
	end)
	at.value += 3
	old.factory.close = function() end
end

local function run(layoutId: string, stale: boolean, hold: number?): (number?, { string })
	local at: Time = { value = 1000, wakes = {} }
	if process.env.FORGE_JOIN_TRACE then
		print("boot", layoutId, os.clock())
	end
	local backend = throttled(at)
	local old = if stale then boot(backend, at, "old-server", layoutId) else nil
	local live = boot(backend, at, "new-server", layoutId)
	if old then
		forceStopped(at, old)
	end
	if process.env.FORGE_JOIN_TRACE then
		print("booted", os.clock())
	end
	local seconds, log = measure(live, at, 60, layoutId, hold)
	-- Every thread still parked on a write returns; the run ends with the spec.
	backend.halted = true
	for _ = 1, 50 do
		pump(at)
	end
	if process.env.FORGE_JOIN_TRACE then
		print(layoutId, if stale then "stale" else "fresh", seconds)
		print(table.concat(log, "\n"))
	end
	return seconds, log
end

local function check(layoutId: string, stale: boolean, hold: number?)
	local seconds, log = run(layoutId, stale, hold)
	assert(
		seconds ~= nil and seconds <= BUDGET,
		"time to first confirmed action: " .. tostring(seconds) .. "\n" .. table.concat(log, "\n")
	)
end

return {
	["onboarding: a fresh join confirms its first action within the D1 budget"] = function()
		check("rw.onboarding", false)
	end,
	["onboarding: a rejoin after a force-stop confirms its first action within the D1 budget"] = function()
		check("rw.onboarding", true)
	end,
	["town: a fresh join confirms its first action within the D1 budget"] = function()
		check("rw.town", false)
	end,
	["town: a rejoin after a force-stop confirms its first action within the D1 budget"] = function()
		check("rw.town", true)
	end,
	-- R01: the title waits for the player by design, so D1 counts from the Start tap. A tap the
	-- moment the title appears (2 s, the loading screen's earliest close) and a slow one (20 s,
	-- past every join retry and lease takeover) both confirm within the budget of the tap.
	["onboarding: with the title held, the first action confirms within D1 of the Start tap"] = function()
		check("rw.onboarding", false, 2)
		check("rw.onboarding", true, 20)
	end,
	["town: with the title held, the first action confirms within D1 of the Start tap"] = function()
		check("rw.town", true, 2)
		check("rw.town", false, 20)
	end,
}
