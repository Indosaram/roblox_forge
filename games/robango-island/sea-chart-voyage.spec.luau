--!strict
-- p134 v65 (staging, phone): every sea chart voyage was refused ~1 s after the loading screen showed
-- ('You can't travel right now'), from onboarding and from home, while the onboarding dock prompt
-- travelled. The chart sails through a durable command (survival-coop:mission-action "sail"), and
-- the Session holds the actor busy while an extension command runs, so the teleport router's
-- handoff (Session.prepareHandoff) answered COMMAND_PENDING. This drives the real onboarding
-- RoleWorld, SurvivalFactory and Session: the voyage must leave after the command returns.
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
local _packText = require("./PackText.fixture")
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")

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
	end, "rw.onboarding", 1776)
	local factoryBuilder = engine.load("games/robango-island/src/server/SurvivalFactory.luau", {}, {
		Parent = {
			LateEquipmentPorts = require("./src/server/LateEquipmentPorts"),
			WorldDressing = engine.dressing,
		},
	})
	local provision = engine.load("games/robango-island/src/server/SurvivalProvision.luau", {}, nil)(
		{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
		Source.tribe.config.tribeId,
		{ studio = false, server = "sail-live" }
	)
	local backend = Memory.new()
	local encode = function(value)
		return serde.encode("json", value)
	end
	local options: any = { sessionId = "sail-live", leaseSeconds = 120, now = now, budget = { encode = encode } }
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
		storeName = "sail-live-personal",
	}, backend, { sessionId = "sail-live", lockTimeout = 120, retries = 0, now = now }, services, Durable)
	factory.bind(session)
	assert(session.join(ACTOR).ok, "join")
	return { engine = engine, world = world, factory = factory, session = session, clock = clock, at = at }
end

local function sail(live: any, destination: string): any
	return live.session.command(ACTOR, {
		requestId = "sail-" .. destination,
		sessionEpoch = live.session.commandEpoch(ACTOR),
		action = "survival-coop:mission-action",
		args = { "sail", destination },
	})
end

return {
	["sea chart voyage hands the actor off after the sail command returns (no COMMAND_PENDING)"] = function()
		local live = server()
		live.engine.move(ACTOR, Content.homePolicy.dock)
		live.world.sailPoint = function()
			return "dock"
		end
		-- The live router (IslandBootstrap.travel) prepares the Session handoff before TeleportAsync.
		local handoffs: { any } = {}
		live.world.travel = function(_player, destination)
			local ready = live.session.prepareHandoff(ACTOR)
			table.insert(handoffs, { destination = destination, ok = ready.ok, reason = ready.reason })
			if ready.ok then
				live.session.resumeHandoff(ACTOR)
			end
			return ready.ok, ready.reason
		end
		local result = sail(live, "harbor")
		assert(result.ok, "sail command accepted: " .. tostring(result.reason))
		task.wait()
		assert(#handoffs == 1 and handoffs[1].destination == "harbor", "one voyage to the harbor")
		assert(handoffs[1].ok, "handoff refused: " .. tostring(handoffs[1].reason))
	end,
	["a voyage refused after the sail command is published to the player with its own text"] = function()
		local live = server()
		live.engine.move(ACTOR, Content.homePolicy.dock)
		live.world.sailPoint = function()
			return "dock"
		end
		live.world.travel = function()
			return false, "teleport_failed"
		end
		assert(sail(live, "harbor").ok, "command answers")
		task.wait()
		local player = live.engine.game:GetService("Players"):GetPlayerByUserId(tonumber(ACTOR))
		local shown = player:GetAttribute("ForgeTravelResult")
		assert(type(shown) == "string" and string.match(shown, "^teleport_failed|"), "published: " .. tostring(shown))
	end,
	["every router and handoff refusal reason has its own en and ko text"] = function()
		local fallback = { en = Panels.travelText("en-us", "?"), ko = Panels.travelText("ko-kr", "?") }
		for _, reason in
			{
				"COMMAND_PENDING",
				"teleport_failed",
				"handoff_refused",
				"missing_actor_facts",
				"unconfigured_destination",
				"unknown_target_role",
				"missing_home_reservation",
				"party_reservation_failed",
				"travel_failed",
				"travel_unavailable",
				"travel_refused",
			}
		do
			assert(Panels.travelText("en-us", reason) ~= fallback.en, "en text for " .. reason)
			assert(Panels.travelText("ko-kr", reason) ~= fallback.ko, "ko text for " .. reason)
		end
	end,
}
