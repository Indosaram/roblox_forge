--!strict
-- Lease lapse on the live wiring (p134 v37 phone runs: "Forge profile save <uid>: lease lost", then every
-- command answered COMBAT_PENDING and a dead player stayed stuck). The real onboarding RoleWorld,
-- SurvivalFactory and Session run on a fake clock; an idle gap longer than the 120 s lease (a phone
-- that backgrounds for minutes, a long down hold) lets the wildlife and personal fences expire with no
-- other owner. This server still owns both keys, so the next sweep must take them back instead of
-- refusing the actor forever, and the command wrapper must refuse a nil epoch instead of throwing.
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

local function arm(live: any, actor: string)
	assert(live.session.join(actor).ok, "join " .. actor)
	live.engine.move(actor, Content.homePolicy.dock)
	local body = live.engine.game:GetService("Players"):GetPlayerByUserId(tonumber(actor)).Character
	body:FindFirstChildOfClass("Humanoid").HealthChanged = body.AttributeChanged
end

local function sweepClean(session: any, actor: string): string?
	local recovered = session.recoverTransfers(actor, 8)
	if not recovered.ok then
		return tostring(recovered.reason)
	end
	for _, result in recovered.data.results do
		if result.ok == false then
			return tostring(result.reason)
		end
	end
	return nil
end

return {
	["an idle gap past the lease after a vitals hit leaves the actor playable on the live wiring"] = function()
		local live = boot()
		local session = live.session
		arm(live, DOWNED)
		local hit = live.command(DOWNED, "survival-coop:vitals-damage", { 1000 }, true)
		assert(hit.ok, "server damage: " .. tostring(hit.reason))
		-- The phone backgrounds for ten minutes: no heartbeat, no command, both leases lapse.
		live.at.value += 600
		local stuck = sweepClean(session, DOWNED)
		assert(stuck == nil, "recovery sweep after the gap: " .. tostring(stuck))
		assert(session.commandEpoch(DOWNED, "survival-coop:food") ~= nil, "a command epoch is issued again")
		local saved = session.save(DOWNED)
		assert(saved.ok, "profile save after the gap: " .. tostring(saved.reason))
		local again = live.command(DOWNED, "survival-coop:vitals-damage", { 1000 }, true)
		assert(again.ok, "server command after the gap: " .. tostring(again.reason))
		live.factory.close()
	end,
	["a command with no epoch is refused by the wrapper instead of throwing"] = function()
		local live = boot()
		local session = live.session
		arm(live, DOWNED)
		for _, method in { "command", "commandServer" } do
			local ok, result = pcall(session[method], DOWNED, {
				requestId = "no-epoch-" .. method,
				sessionEpoch = nil,
				action = "survival-coop:food",
				args = { "starter-berry" },
			})
			assert(ok, method .. " threw: " .. tostring(result))
			assert(result.ok == false, method .. " refuses a request without an epoch")
		end
		live.factory.close()
	end,
	["a death held down while the phone is backgrounded recovers when it returns"] = function()
		local live = boot()
		local session = live.session
		arm(live, DOWNED)
		local killed = live.command(DOWNED, "survival-coop:vitals-damage", { 100000 }, true)
		assert(killed.ok, "fatal damage: " .. tostring(killed.reason))
		assert(session.snapshot(DOWNED).survivalExtensions.rescue.down == true, "down after the fatal strike")
		-- 270 s on the down screen with the app in the background: the server sees no command and the
		-- heartbeat-driven sweep is starved.
		live.at.value += 270
		local stuck = sweepClean(session, DOWNED)
		assert(stuck == nil, "recovery sweep after the down hold: " .. tostring(stuck))
		local choice = live.command(DOWNED, "survival-coop:rescue-choose", { "camp" })
		assert(
			choice.ok or (choice.reason ~= "COMBAT_PENDING" and choice.reason ~= "lease lost"),
			"down choice after the hold: " .. tostring(choice.reason)
		)
		local saved = session.save(DOWNED)
		assert(saved.ok, "profile save after the hold: " .. tostring(saved.reason))
		live.factory.close()
	end,
}
