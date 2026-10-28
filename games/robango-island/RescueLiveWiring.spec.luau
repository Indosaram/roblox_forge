--!strict
-- C6 on a live server (p134 v36: a theropod kill only darkened the screen, then respawned). This
-- builds the real onboarding RoleWorld, the real SurvivalFactory (genre extension registry included)
-- and a real Session, gives the world the same `rescue` port RobangoIslandServer installs, and drives
-- a death through the server path. Every state push reads session.snapshot, so the rescue slice must
-- publish there; the old SurvivalWorld.vitals read session.snapshot from inside it and overflowed.
local serde = require("@lune/serde")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local Clock = require("../../core/infra/genre/Clock")
local Durable = require("./src/shared/GenreDurable")

local DOWNED, RESCUER = "11734795308", "11734795309"

local function boot()
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
	-- The port RobangoIslandServer.server.luau assigns (C6), on the world's own live reads.
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
		{ studio = false, server = "rescue-live" }
	)
	local backend = Memory.new()
	local encode = function(value)
		return serde.encode("json", value)
	end
	local options: any = { sessionId = "rescue-live", leaseSeconds = 120, now = now, budget = { encode = encode } }
	local factory: any = assert(factoryBuilder(Content, Source, world, backend, clock, options, provision, Policy))
	assert(world.downHold, "RescueExtension installed the SurvivalWorld down hold")
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
		storeName = "rescue-live-personal",
	}, backend, { sessionId = "rescue-live", lockTimeout = 120, retries = 0, now = now }, services, Durable)
	factory.bind(session)
	local sequence = 0
	local function command(actor: string, action: string, args: { any }, server: boolean?): any
		sequence += 1
		at.value += 1
		session.advance(clock.now())
		local request = {
			requestId = "rescue-live-" .. sequence,
			sessionEpoch = session.commandEpoch(actor, action),
			action = action,
			args = args,
		}
		return if server then session.commandServer(actor, request) else session.command(actor, request)
	end
	local heartbeat = engine.game:GetService("RunService").Heartbeat
	return {
		engine = engine,
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

return {
	["a server-side death on the live wiring holds the player down and publishes the 3 options"] = function()
		local live = boot()
		local session = live.session
		local spawn = Content.homePolicy.dock
		for _, actor in { DOWNED, RESCUER } do
			assert(session.join(actor).ok, "join " .. actor)
			live.engine.move(actor, spawn)
			-- The fake engine's Humanoid has no HealthChanged signal; SurvivalWorld subscribes to it.
			local body = live.engine.game:GetService("Players"):GetPlayerByUserId(tonumber(actor)).Character
			body:FindFirstChildOfClass("Humanoid").HealthChanged = body.AttributeChanged
		end
		-- Server.push snapshots every member every second; this is the call v36 lost.
		local ok, snapshot = pcall(session.snapshot, DOWNED)
		assert(ok, "session.snapshot on the live wiring: " .. tostring(snapshot))
		local rescue = snapshot.survivalExtensions and snapshot.survivalExtensions.rescue
		assert(rescue and rescue.down == false, "rescue slice published while alive")
		-- The theropod strike path: a server vitals-damage to 0.
		local killed = live.command(DOWNED, "survival-coop:vitals-damage", { 100000 }, true)
		assert(killed.ok, "fatal damage: " .. tostring(killed.reason))
		rescue = session.snapshot(DOWNED).survivalExtensions.rescue
		assert(rescue.down == true, "down after the fatal strike")
		assert(
			#rescue.options == 3
				and rescue.options[1] == "rift"
				and rescue.options[2] == "camp"
				and rescue.options[3] == "rescue",
			"three wild options for the down panel"
		)
		-- The SurvivalWorld heartbeat must hold the undecided actor instead of queueing a respawn.
		for _ = 1, 5 do
			live.heartbeat()
		end
		local vitals = session.snapshot(DOWNED)["survival-coop"].vitals
		assert(vitals.healthMilli == 0, "undecided actor stays down")
		-- A flare reaches the nearby living player.
		local flare = live.command(DOWNED, "survival-coop:rescue-choose", { "rescue" })
		assert(flare.ok, "flare: " .. tostring(flare.reason))
		local seen = session.snapshot(RESCUER).survivalExtensions.rescue
		assert(#seen.flares == 1 and seen.flares[1].id == DOWNED, "rescuer sees the flare")
		assert(seen.flares[1].reachable, "rescuer standing beside it can help")
		local revived = live.command(RESCUER, "survival-coop:rescue-revive", { DOWNED })
		assert(revived.ok, "revive: " .. tostring(revived.reason))
		live.factory.close()
	end,
}
