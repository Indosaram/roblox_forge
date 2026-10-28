--!strict
-- p134 v43 (staging, phone): three starvation deaths in about an hour. A fresh character starts
-- full (100), but every rift respawn set fullness to 50: empty after 15 min, dead about 8 min
-- later, so a player who had not found food yet (the gather button did nothing, issue 1) died every
-- ~23 min. These scripted first-30-minute runs drive the real onboarding RoleWorld, SurvivalFactory,
-- RescueExtension and Session (the RescueLiveWiring harness) on the shipped content and vitals.
local serde = require("@lune/serde")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local Clock = require("../../core/infra/genre/Clock")
local Durable = require("./src/shared/GenreDurable")

local DOWNED = "11734795308"

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

local MINUTE = 60
local STEP = 5

local function arrive(live: any, actor: string)
	live.engine.move(actor, Content.homePolicy.dock)
	-- The fixture Humanoid lacks HealthChanged, which the down hold connects to.
	local character = live.engine.game:GetService("Players"):GetPlayerByUserId(tonumber(actor)).Character
	character:FindFirstChildOfClass("Humanoid").HealthChanged = character.AttributeChanged
end

local function vitals(live: any): any
	return live.session.snapshot(DOWNED)["survival-coop"].vitals
end

local function berryId(live: any): string?
	for id, item in live.session.snapshot(DOWNED)["survival-coop"].inventory.bag.items do
		if item.catalogId == "berry" then
			return id
		end
	end
	return nil
end

-- Plays `seconds` of onboarding time in STEP-second heartbeats. With `eat`, the player eats a
-- berry whenever the HUD says hungry, gathering the onboarding berry bush when the bag has none.
-- Returns the lowest health seen.
local gathers = 0
local function play(live: any, seconds: number, eat: boolean): number
	local lowest = vitals(live).healthMilli
	for _ = 1, seconds // STEP do
		live.at.value += STEP - 1
		-- The server Heartbeat advances the session (vitals ticks) and then the world.
		live.session.advance(live.at.value + 1)
		live.heartbeat()
		local state = vitals(live)
		lowest = math.min(lowest, state.healthMilli)
		if eat and state.hungerMilli < 30000 then
			if not berryId(live) then
				local nodes = live.factory.services.survivalGathering.snapshot(DOWNED)
				live.engine.move(DOWNED, nodes.nodes["rw.onboarding.berry"].position)
				-- One frozen request, replayed through the durable transfer as GatheringClient.drive does.
				gathers += 1
				local request = {
					requestId = "food-gather-" .. gathers,
					sessionEpoch = live.session.commandEpoch(DOWNED, "survival-coop:gather"),
					action = "survival-coop:gather",
					args = { "rw.onboarding.berry", nodes.version, "berry" },
				}
				local got = live.session.command(DOWNED, request)
				for _ = 1, 4 do
					if got.ok or type(got.data) ~= "table" or got.data.status ~= "pending" then
						break
					end
					got = live.session.command(DOWNED, request)
				end
				assert(
					got.ok,
					"berry gather: " .. tostring(got.reason) .. " " .. tostring(got.data and got.data.status)
				)
				live.heartbeat()
			end
			local id = assert(berryId(live), "a berry to eat")
			local fed = live.command(DOWNED, "survival-coop:food", { id })
			assert(fed.ok, "eat: " .. tostring(fed.reason))
		end
	end
	return lowest
end

return {
	["a new character eating when prompted never loses health to hunger in its first 30 minutes"] = function()
		local live = boot()
		assert(live.session.join(DOWNED).ok, "join")
		arrive(live, DOWNED)
		local start = vitals(live)
		assert(start.hungerMilli == 100000 and start.healthMilli == 100000, "a new character starts full")
		local lowest = play(live, 30 * MINUTE, true)
		assert(lowest == 100000, "health fell to " .. lowest .. " in the first 30 minutes")
		live.factory.close()
	end,
	["after a rift respawn the character has 30 minutes before hunger hurts"] = function()
		local live = boot()
		assert(live.session.join(DOWNED).ok, "join")
		arrive(live, DOWNED)
		assert(live.command(DOWNED, "survival-coop:vitals-damage", { 100000 }, true).ok, "down")
		local rift = live.command(DOWNED, "survival-coop:rescue-choose", { "rift" })
		assert(rift.ok, "rift: " .. tostring(rift.reason))
		for _ = 1, 10 do
			live.heartbeat()
			if vitals(live).healthMilli > 0 then
				break
			end
		end
		local woke = vitals(live)
		print(string.format("respawn fullness %d health %d", woke.hungerMilli // 1000, woke.healthMilli // 1000))
		assert(woke.healthMilli > 0, "respawned through the rift")
		-- Worst case: the death left no food in the bag and the player has not found the bush yet.
		local lowest = play(live, 30 * MINUTE - 2 * STEP, false)
		assert(
			lowest == woke.healthMilli,
			string.format(
				"respawned at fullness %d; health fell to %d within 30 minutes",
				woke.hungerMilli // 1000,
				lowest
			)
		)
		live.factory.close()
	end,
}
