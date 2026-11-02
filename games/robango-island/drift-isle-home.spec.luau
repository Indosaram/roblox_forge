--!strict
-- journey6h 6 h run @304 min (rw.a1.s3): Expedition > Home > Confirm answered HOME_ROUTE_UNAVAILABLE.
-- party-action {home, ""} settles the trip and hands the player to the home router, but it ran the
-- router inside the durable command, where the Session holds the actor: the live handoff
-- (Session.prepareHandoff) refuses COMMAND_PENDING there, as the chart sail did in p134 v65. The
-- trip is settled in the command; the voyage home must leave after it returns.
local serde = require("@lune/serde")
local task = require("@lune/task")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local Clock = require("../../core/infra/genre/Clock")
local Durable = require("./src/shared/GenreDurable")
local Archipelago = require("../../core/domain/island/Archipelago")
local _packText = require("./PackText.fixture")

local ACTOR = "11734795308"

local function server()
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
	-- The sail command reads SeaChart (voyage gate) from the replicated pack.
	forge.games["robango-island"].src.shared.SeaChart = require("./src/shared/SeaChart")
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
	local at = { value = 1000 }
	local clock = Clock.new(function()
		return at.value
	end)
	local function now(): number
		return math.floor(at.value)
	end
	local world: any = engine.role.build(Content, Source, Policy, function()
		return at.value * 1000
	end, "rw.a1.s1", 79)
	local factoryBuilder = engine.load("games/robango-island/src/server/SurvivalFactory.luau", {}, {
		Parent = {
			LateEquipmentPorts = require("./src/server/LateEquipmentPorts"),
			WorldDressing = engine.dressing,
		},
	})
	local provision = engine.load("games/robango-island/src/server/SurvivalProvision.luau", {}, nil)(
		{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
		Source.tribe.config.tribeId,
		{ studio = false, server = "home-live" }
	)
	local backend = Memory.new()
	local encode = function(value)
		return serde.encode("json", value)
	end
	local options: any = { sessionId = "home-live", leaseSeconds = 120, now = now, budget = { encode = encode } }
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
		storeName = "home-live-personal",
	}, backend, { sessionId = "home-live", lockTimeout = 120, retries = 0, now = now }, services, Durable)
	factory.bind(session)
	assert(session.join(ACTOR).ok, "join")
	engine.game:GetService("Workspace"):SetAttribute("ForgeWorldRole", "archipelago")
	return {
		engine = engine,
		world = world,
		factory = factory,
		session = session,
		clock = clock,
		at = at,
		provision = provision,
	}
end

-- RobangoIslandServer: liveWorld.travel settles the trip for "home" on a drift isle, and
-- provision.returnHome runs the router, whose first step is the Session handoff.
local function wire(live: any): { any }
	local handoffs: { any } = {}
	live.world.travel = function(_player, destination)
		assert(destination == "home", "only home is asked")
		return live.factory.archipelago.recover(ACTOR, "return")
	end
	live.provision.returnHome = function(actor: string)
		local ready = live.session.prepareHandoff(actor)
		table.insert(handoffs, { ok = ready.ok, reason = ready.reason })
		if ready.ok then
			live.session.resumeHandoff(actor)
		end
		return { ok = ready.ok, reason = ready.reason }
	end
	return handoffs
end

local function openTrip(live: any)
	local opened = live.factory.expeditionStore.transaction(ACTOR, function(document)
		document.archipelago = Archipelago.open(Content, {
			id = "trip-home",
			index = 1,
			seed = 79,
			revision = "robango-route-v1",
			ttl = 1800,
			entryBuffer = 0,
			actor = ACTOR,
		}, { level = 99, developmentRank = 99, instabilityAccess = 5 }, live.at.value)
		return { ok = document.archipelago ~= nil }
	end)
	assert(opened.ok, "trip opened: " .. tostring(opened.reason))
end

return {
	["Expedition > Home on a drift isle settles the trip and hands the player home after the command"] = function()
		local live = server()
		live.engine.move(ACTOR, { x = 0, y = 4, z = 0 })
		local handoffs = wire(live)
		openTrip(live)
		local result = live.session.command(ACTOR, {
			requestId = "home-1",
			sessionEpoch = live.session.commandEpoch(ACTOR, "survival-coop:party-action"),
			action = "survival-coop:party-action",
			args = { "home", "" },
		})
		assert(result.ok, "home accepted: " .. tostring(result.reason))
		local trip = live.factory.expeditionStore.snapshot(ACTOR).archipelago
		assert(trip.status == "return", "the trip is settled in the command: " .. tostring(trip.status))
		task.wait()
		assert(#handoffs == 1, "one voyage home, got " .. #handoffs)
		assert(handoffs[1].ok, "handoff refused: " .. tostring(handoffs[1].reason))
	end,
}
