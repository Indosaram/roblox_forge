--!strict
-- p134 v41 (staging, phone): after a death and a rift respawn every eat was refused UNAVAILABLE
-- and it survived rejoins and new servers. The saved profile held a content-v1 berry-meal job in
-- Reserved state that locked all 3 starter berries (no TTL, no UI to cancel it), plus two cord jobs
-- that took gathered fibre, ran, and were refused UNKNOWN_RECIPE at collect (cord has no
-- recipeDetails row, so material growth refused it) and so kept the fibre locked forever.
-- These drive the real onboarding RoleWorld, SurvivalFactory and Session on that saved shape.
local serde = require("@lune/serde")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local Clock = require("../../core/infra/genre/Clock")
local Durable = require("./src/shared/GenreDurable")

local ACTOR = "11734795308"
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")

local function boot(backend: any?, at: any?, serverId: string?)
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
	forge.core.infra = {
		render = forge.core.infra.render,
		genre = { Clock = Clock, Session = Session },
		data = {
			ActorDocumentStore = require("../../core/infra/data/ActorDocumentStore"),
			ClanStoreWallet = require("../../core/infra/data/ClanStoreWallet"),
		},
	}
	at = at or { value = 1000 }
	local clock = Clock.new(function()
		return at.value
	end)
	local function now(): number
		return math.floor(at.value)
	end
	local world: any = engine.role.build(Content, Source, Policy, function()
		return at.value * 1000
	end, "rw.onboarding", 1776)
	world.rescue = {
		position = function(actor: string)
			local p = world.rootPosition(actor)
			return if p then { x = p.X, y = p.Y, z = p.Z } else nil
		end,
		health = function(actor: string): number?
			local vitals = world.vitals(actor)
			return if vitals then vitals.healthMilli else nil
		end,
		safe = function(): boolean
			return false
		end,
		camp = function(actor: string)
			local p = world.nearestStation(actor, { "campfire", "fireplace" })
			return if p then { x = p.X, y = p.Y, z = p.Z } else nil
		end,
		name = function(actor: string): string
			return "P" .. actor
		end,
	}
	local factoryBuilder = engine.load("games/robango-island/src/server/SurvivalFactory.luau", {}, {
		Parent = {
			LateEquipmentPorts = require("./src/server/LateEquipmentPorts"),
			WorldDressing = engine.dressing,
		},
	})
	local provision = engine.load("games/robango-island/src/server/SurvivalProvision.luau", {}, nil)(
		{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
		Source.tribe.config.tribeId,
		{ studio = false, server = serverId or "craft-live" }
	)
	backend = backend or Memory.new()
	local encode = function(value)
		return serde.encode("json", value)
	end
	local options: any = { sessionId = "craft-live", leaseSeconds = 120, now = now, budget = { encode = encode } }
	local factory: any = assert(factoryBuilder(Content, Source, world, backend, clock, options, provision, Policy))
	local services = table.clone(factory.services)
	services.now = clock.now
	services.roll = function()
		return 0
	end
	services.emit = function() end
	services.encode = encode
	local session = Session.new({
		packConfig = require("./src/shared/GenreConfig"),
		contracts = { require("../../genres/survival-coop/module/Contract") },
		durable = Durable,
		controls = {},
		storeName = "craft-live-personal",
	}, backend, { sessionId = "craft-live", lockTimeout = 120, retries = 0, now = now }, services, Durable)
	factory.bind(session)
	local sequence = 0
	local function command(actor: string, action: string, args: { any }, server: boolean?): any
		sequence += 1
		at.value += 1
		session.advance(clock.now())
		local request = {
			requestId = "craft-live-" .. sequence,
			sessionEpoch = session.commandEpoch(actor, action),
			action = action,
			args = args,
		}
		return if server then session.commandServer(actor, request) else session.command(actor, request)
	end
	local heartbeat = engine.game:GetService("RunService").Heartbeat
	return {
		engine = engine,
		world = world,
		session = session,
		factory = factory,
		command = command,
		at = at,
		heartbeat = function()
			at.value += 1
			heartbeat:Fire()
		end,
	}
end

-- Request ids stay unique across client models (a fresh model per hand chain).
local clientSequence = 0
local function client(live: any): any
	local session = live.session
	local sequence = 0
	local model = Model.new(ACTOR, function()
		sequence += 1
		clientSequence += 1
		return "hud-" .. clientSequence
	end)
	local function handshake()
		local epochs = {}
		for _, action in Durable.actions do
			epochs[action] = session.commandEpoch(ACTOR, action)
		end
		model.receive({
			durable = { actions = Durable.actions, sessionEpoch = session.commandEpoch(ACTOR), epochs = epochs },
		})
		model.receive({ revision = sequence, snapshots = session.snapshot(ACTOR) })
	end
	handshake()
	-- SurvivalHUD.send: the RemoteFunction reply goes straight into model.finish.
	local function send(request: any): any
		live.at.value += 1
		session.advance(live.at.value)
		local result = session.command(ACTOR, request)
		model.finish(true, result)
		handshake()
		return result
	end
	return model, send
end

local Workshop = require("../../genres/survival-coop/module/Workshop")
local Inventory = require("../../core/domain/inventory/Inventory")
local Job = require("../../core/domain/crafting/Job")
local Canonical = require("../../core/domain/survival/Content")

local canonical: any = nil
local function document(): any
	if not canonical then
		local raw = table.clone(Content)
		raw.survival_content, raw.version, raw.capability = raw.version, nil, nil
		canonical = assert(Canonical.canonicalize(raw), "canonical content")
	end
	return canonical
end

-- Stand at the dock; the fixture Humanoid lacks HealthChanged, which the down hold connects to.
local function arrive(live: any)
	live.engine.move(ACTOR, Content.homePolicy.dock)
	local body = live.engine.game:GetService("Players"):GetPlayerByUserId(tonumber(ACTOR)).Character
	body:FindFirstChildOfClass("Humanoid").HealthChanged = body.AttributeChanged
end

local function bag(live: any): any
	return live.session.snapshot(ACTOR)["survival-coop"].inventory.bag
end

local function count(live: any, catalogId: string): (number, number)
	local state = bag(live)
	local total, free = 0, 0
	for id, item in state.items do
		if item.catalogId == catalogId then
			total += item.quantity
			free += Inventory.available(state, id)
		end
	end
	return total, free
end

-- Writes a workshop job straight into the saved profile, as an earlier server left it.
local function plant(
	live: any,
	recipe: string,
	revision: string,
	station: string?,
	requestId: string,
	at: number,
	berries: number?
)
	local ok, why = live.session.personalTransaction(ACTOR, function(raw: any)
		local data = raw.envelope.genres["survival-coop"].data
		if berries then
			-- The saved profile: one starter stack of exactly the 3 berries the meal job holds.
			data.inventory.bag.items["starter-berry"].quantity = berries
		end
		local inventory = Inventory.fromSave(data.inventory.bag, Job.catalog(document()))
		local jobs = Workshop.fromSave(data.workshop, ACTOR, { bag = inventory })
		local candidate = assert(
			Workshop.reserve(
				jobs,
				inventory,
				{ actorId = ACTOR, sessionEpoch = jobs.epoch, requestId = requestId },
				document(),
				revision,
				recipe,
				at,
				{ carriedContainer = "bag", stationId = station, stationKind = station, inReach = true }
			)
		)
		data.inventory.bag = Inventory.save(candidate.inventory)
		data.workshop = Workshop.save(candidate.jobs)
		return raw
	end)
	assert(ok, "plant " .. recipe .. ": " .. tostring(why))
end

local function gather(live: any, node: string, output: string?): any
	local nodes = live.factory.services.survivalGathering.snapshot(ACTOR).nodes
	live.engine.move(ACTOR, nodes[node].position)
	local version = live.factory.services.survivalGathering.snapshot(ACTOR).version
	local result = live.command(ACTOR, "survival-coop:gather", { node, version, output })
	for _ = 1, 3 do
		live.heartbeat()
	end
	return result
end

local function hand(live: any, recipe: string): { any }
	local model, send = client(live)
	local seen = {}
	local chain = {}
	local request = assert(model.begin("craft-reserve", { recipe, "hand" }), "make enabled")
	while request do
		assert(#seen < 10, "hand chain ends")
		local result = send(request)
		table.insert(seen, { action = request.action, ok = result.ok, reason = result.reason })
		local verb, args, wait = Model.handChain(request, result, chain, Content.recipes)
		request = nil
		if verb then
			live.at.value += wait or 0
			request = assert(model.begin(verb, args :: any), verb .. " begins")
		end
	end
	return seen
end

return {
	["the saved v41 shape: an old berry reservation never blocks eating after a new-server join"] = function()
		local backend = Memory.new()
		local at = { value = 1793150000 }
		local first = boot(backend, at, "server-a")
		assert(first.session.join(ACTOR).ok, "join a")
		plant(first, "berry-meal", "content-v1", "campfire", "bb0420b4", math.floor(at.value * 1000), 3)
		-- The stored profile now carries the v41 shape (the live adapter may already ignore it).
		local held = 0
		assert(
			first.session.personalTransaction(ACTOR, function(raw: any)
				for _, quantities in raw.envelope.genres["survival-coop"].data.inventory.bag.reservations do
					held += quantities["starter-berry"] or 0
				end
				return raw
			end),
			"read back"
		)
		assert(held == 3, "the planted job holds every starter berry, " .. held)
		first.factory.close()
		at.value += 3600
		local second = boot(backend, at, "server-b")
		assert(second.session.join(ACTOR).ok, "join b")
		arrive(second)
		local total, free = count(second, "berry")
		assert(free == total and total == 3, "join released the stale berry reservation, free " .. free)
		local eat = second.command(ACTOR, "survival-coop:food", { "starter-berry" })
		assert(eat.ok, "eat after join: " .. tostring(eat.reason))
		second.factory.close()
		-- And the release was saved: a third server sees the same free stack.
		at.value += 60
		local third = boot(backend, at, "server-c")
		assert(third.session.join(ACTOR).ok, "join c")
		total, free = count(third, "berry")
		assert(total == 2 and free == 2, "release persisted, berries " .. total .. "/" .. free)
		third.factory.close()
	end,
	["eating releases a current craft holding the stack"] = function()
		local live = boot()
		assert(live.session.join(ACTOR).ok, "join")
		arrive(live)
		plant(live, "berry-meal", "content-v2", "campfire", "fresh-meal", math.floor(live.at.value * 1000))
		local eat = live.command(ACTOR, "survival-coop:food", { "starter-berry" })
		assert(eat.ok, "eat: " .. tostring(eat.reason))
		local total, free = count(live, "berry")
		assert(total == 2 and free == 2, "the meal job let go of the berries, " .. total .. "/" .. free)
		live.factory.close()
	end,
	["a hand cord from gathered fibre is collected"] = function()
		local live = boot()
		assert(live.session.join(ACTOR).ok, "join")
		arrive(live)
		-- Spend the starter fibre so the cord takes the gathered (material-recorded) stack.
		local spent = live.command(ACTOR, "survival-coop:craft-reserve", { "cord", "hand" })
		assert(spent.ok, "starter reserve")
		for _ = 1, 3 do
			gather(live, "rw.onboarding.fiber", "fiber")
		end
		local before = count(live, "cord")
		local steps = hand(live, "cord")
		local last = steps[#steps]
		assert(last.action == "survival-coop:craft-complete" and last.ok, "collect: " .. tostring(last.reason))
		assert(count(live, "cord") == before + 1, "one cord arrived")
		live.factory.close()
	end,
	-- p134 v43: every crafted cord took its own 'cord x1' slot (5 slots after 5 crafts) and the craft
	-- panel showed 'cord 1'. Each job minted a fresh '<job>:output:1' item and nothing merged it.
	["crafted cords stack into one slot"] = function()
		local live = boot()
		assert(live.session.join(ACTOR).ok, "join")
		arrive(live)
		for round = 1, 3 do
			local steps = hand(live, "cord")
			assert(steps[#steps].ok, "cord " .. round .. ": " .. tostring(steps[#steps].reason))
		end
		local slots = 0
		for _, item in bag(live).items do
			if item.catalogId == "cord" then
				slots += 1
			end
		end
		assert(count(live, "cord") == 3 and slots == 1, count(live, "cord") .. " cords in " .. slots .. " slots")
		assert(Model.held(bag(live), "cord") == 3, "the craft panel counts every cord")
		live.factory.close()
	end,
	["a refused cord start puts the fibre back"] = function()
		local live = boot()
		assert(live.session.join(ACTOR).ok, "join")
		arrive(live)
		local fibre = count(live, "fiber")
		local reserved = live.command(ACTOR, "survival-coop:craft-reserve", { "cord", "hand" })
		assert(reserved.ok, "reserve: " .. tostring(reserved.reason))
		local _, free = count(live, "fiber")
		assert(free == fibre - 3, "reserve holds 3 fibre")
		-- Down between the hand chain's reserve and start (the v41 phone starved there).
		assert(
			live.session.personalTransaction(ACTOR, function(raw: any)
				raw.envelope.genres["survival-coop"].data.vitals.healthMilli = 0
				return raw
			end),
			"down"
		)
		local start = live.command(ACTOR, "survival-coop:craft-start", { reserved.data.jobId })
		assert(not start.ok and start.reason == "NOT_ALIVE", "start refused: " .. tostring(start.reason))
		local total
		total, free = count(live, "fiber")
		assert(total == fibre and free == fibre, "fibre back in the bag, " .. total .. "/" .. free)
		local job = live.session.snapshot(ACTOR)["survival-coop"].workshop.entries[reserved.data.jobId].job
		assert(job.state == "Cancelled", "the refused job is cancelled, " .. job.state)
		live.factory.close()
	end,
	-- p134 v45: every gather took its own slot (11 slots of 'fibre x3' after a few minutes, bag
	-- 20/30). Each gather mints '<grant>:output:1' and the destination credit added it as is.
	["four gathers of one node share one slot"] = function()
		local live = boot()
		assert(live.session.join(ACTOR).ok, "join")
		arrive(live)
		local function slots(): number
			local n = 0
			for _, item in bag(live).items do
				if item.catalogId == "fiber" then
					n += 1
				end
			end
			return n
		end
		local before, fibre = slots(), count(live, "fiber")
		for round = 1, 4 do
			local result = gather(live, "rw.onboarding.fiber", "fiber")
			assert(result.ok, "gather " .. round .. ": " .. tostring(result.reason))
		end
		assert(count(live, "fiber") == fibre + 12, "every gather credited once")
		assert(slots() == before + 1, "4 gathers took " .. (slots() - before) .. " slots")
		live.factory.close()
	end,
	-- The same phone kept 5 'cord x1' slots crafted before the v43 craft restack: join folds them.
	["a legacy bag with five one-cord slots holds one after join"] = function()
		local backend = Memory.new()
		local at = { value = 1793150000 }
		local first = boot(backend, at, "server-a")
		assert(first.session.join(ACTOR).ok, "join a")
		arrive(first)
		local steps = hand(first, "cord")
		assert(steps[#steps].ok, "cord: " .. tostring(steps[#steps].reason))
		assert(
			first.session.personalTransaction(ACTOR, function(raw: any)
				local items = raw.envelope.genres["survival-coop"].data.inventory.bag.items
				local cord: any = nil
				for id, item in items do
					if item.catalogId == "cord" then
						cord = item
						items[id] = nil
					end
				end
				for index = 1, 5 do
					local copy = table.clone(cord)
					copy.attributes = table.clone(cord.attributes)
					copy.itemId, copy.quantity = "w-legacy-" .. index .. ":output:1", 1
					items[copy.itemId] = copy
				end
				return raw
			end),
			"plant legacy cords"
		)
		first.factory.close()
		at.value += 60
		local second = boot(backend, at, "server-b")
		assert(second.session.join(ACTOR).ok, "join b")
		local slots = 0
		for _, item in bag(second).items do
			if item.catalogId == "cord" then
				slots += 1
			end
		end
		assert(count(second, "cord") == 5 and slots == 1, count(second, "cord") .. " cords in " .. slots .. " slots")
		second.factory.close()
		-- The fold was saved with the join: a third server reads one stack.
		at.value += 60
		local third = boot(backend, at, "server-c")
		assert(third.session.join(ACTOR).ok, "join c")
		assert(bag(third).items["w-legacy-1:output:1"].quantity == 5, "fold persisted")
		third.factory.close()
	end,
}
