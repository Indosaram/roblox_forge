--!strict
-- C2h (plan C2 Accept, G7): on the real onboarding RoleWorld, SurvivalFactory and Session every
-- gather node type offers >= 3 outputs and each pick grants exactly that output; the last charge
-- swaps the node to its depleted mesh and the fan offers nothing (the prompt path then shows the
-- server's regrow time); after respawnSeconds the full mesh is back and the node gathers again.
-- Before C2h a stone pile offered 2 outputs (stone 3 / fieldstone 1) and the client fan opened on a
-- depleted node, offering outputs the server refused.
local serde = require("@lune/serde")
local roblox: any = require("@lune/roblox")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local Clock = require("../../core/infra/genre/Clock")
local Durable = require("./src/shared/GenreDurable")
local Gathering = require("../../genres/survival-coop/module/Gathering")
local GatherOffer = require("./src/client/GatherOffer")

local ACTOR = "11734795308"

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
	-- Fake node MeshPart templates (named like the uploaded rows) so the real dress path runs.
	local NodeMeshes = forge.games["robango-island"].src.shared.NodeMeshes
	local templates = {}
	for _, row in NodeMeshes.ROWS do
		for _, name in { row.full, row.depleted } do
			local mesh = engine.newInstance("MeshPart")
			mesh.Name, mesh.Size = name, roblox.Vector3.new(4, 3, 4)
			templates[name] = mesh
		end
	end
	NodeMeshes.setTemplates(templates)
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

-- Stand at the dock; the fixture Humanoid lacks HealthChanged, which the down hold connects to.
local function arrive(live: any)
	live.engine.move(ACTOR, Content.homePolicy.dock)
	local body = live.engine.game:GetService("Players"):GetPlayerByUserId(tonumber(ACTOR)).Character
	body:FindFirstChildOfClass("Humanoid").HealthChanged = body.AttributeChanged
end

local function count(live: any, catalogId: string): number
	local total = 0
	for _, item in live.session.snapshot(ACTOR)["survival-coop"].inventory.bag.items do
		if item.catalogId == catalogId then
			total += item.quantity
		end
	end
	return total
end

local function nodePart(live: any, id: string): any
	for _, part in live.engine.game:GetService("CollectionService"):GetTagged("ForgeSurvivalNode") do
		if part:GetAttribute("ForgeNodeId") == id then
			return part
		end
	end
	error("no node part " .. id)
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

-- What the client fan offers for a published node part (the RobangoIslandClient wiring).
local function fan(part: any): { any }
	return (
		GatherOffer.offered(part, function(kind: string, id: string)
			local offered, level = Gathering.offered(Content, kind, id)
			return offered, level
		end)
	)
end

local function mesh(part: any, name: string): any
	return assert(part:FindFirstChild(name), part.Name .. " has no " .. name)
end

local function shown(part: any): string
	local full, depleted = mesh(part, "ForgeNodeMeshFull"), mesh(part, "ForgeNodeMeshDepleted")
	assert(full.Transparency + depleted.Transparency == 1, "exactly one state mesh shows")
	return if full.Transparency == 0 then "full" else "depleted"
end

return {
	-- Three node types (stone pile, bracken, bone heap), each output picked once on the live server.
	["each offered output of three node types is picked and granted on the live onboarding server"] = function()
		local live = boot()
		assert(live.session.join(ACTOR).ok, "join")
		arrive(live)
		for _, id in { "rw.onboarding.stone", "rw.onboarding.fiber", "rw.onboarding.carcass" } do
			local part = nodePart(live, id)
			local offered = fan(part)
			assert(#offered >= 3, id .. " fan offers " .. #offered)
			for _, output in offered do
				local before = count(live, output.item)
				local result = gather(live, id, output.item)
				assert(result.ok, id .. " pick " .. output.item .. ": " .. tostring(result.reason))
				assert(
					count(live, output.item) == before + output.quantity,
					id .. " pick " .. output.item .. " granted " .. (count(live, output.item) - before)
				)
			end
		end
		live.factory.close()
	end,
	["the last charge swaps the depleted mesh, the fan offers nothing, and the node regrows"] = function()
		local live = boot()
		assert(live.session.join(ACTOR).ok, "join")
		arrive(live)
		-- The corn seed pod holds 2 charges (stock 2) and regrows after 120 s.
		local id = "rw.onboarding.extra-2"
		local part = nodePart(live, id)
		assert(shown(part) == "full" and part.Transparency == 1, "a fresh node shows its full mesh")
		assert(#fan(part) >= 3, "a fresh node opens the fan")
		for round = 1, 2 do
			local result = gather(live, id, "fiber")
			assert(result.ok, "gather " .. round .. ": " .. tostring(result.reason))
		end
		assert(part:GetAttribute("ForgeNodeDepleted") == true, "the last charge publishes depleted")
		assert(shown(part) == "depleted", "the depleted mesh replaces the full one")
		assert(#fan(part) == 0, "a depleted node offers no outputs")
		local refused = gather(live, id, "fiber")
		assert(not refused.ok and refused.reason == "NODE_DEPLETED", "server refuses: " .. tostring(refused.reason))
		-- An open fan closes on the swap.
		local closed = false
		local picker = {
			node = function()
				return part
			end,
			close = function()
				closed = true
			end,
		}
		assert(GatherOffer.step(picker) and closed, "the open fan closes once its node is depleted")
		-- Regrow: 120 s of server ticks (the 1 Hz advance runs the recovery sweep).
		local respawn = 0
		for _, layout in Content.layouts do
			for _, resource in layout.resourceNodes or {} do
				if resource.id == id then
					respawn = resource.respawnSeconds
				end
			end
		end
		assert(respawn > 0, "authored respawn")
		for _ = 1, respawn + 5 do
			live.at.value += 1
			live.session.advance(live.at.value)
			live.heartbeat()
		end
		assert(part:GetAttribute("ForgeNodeDepleted") == false, "the node regrows")
		assert(shown(part) == "full", "the full mesh is back")
		assert(#fan(part) >= 3, "the regrown node opens the fan again")
		local again = gather(live, id, "corn-seed")
		assert(again.ok, "gather after regrow: " .. tostring(again.reason))
		live.factory.close()
	end,
}
