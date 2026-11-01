--!strict
-- p134 C1 dead end 3 (staging v67, phone): the opening sends the player to the ridge camp at Marit
-- (npc.marit, 0,-48) to place a campfire, but the onboarding camp grid started at
-- station.campfire.t1 (-48,-4): every placement there was OUT_OF_BOUNDS, the card read wood 0/4
-- with 9 logs in the bag (builds pay from the camp warehouse), and the opening never advanced.
-- This drives the real onboarding RoleWorld, SurvivalFactory, Session and OpeningDirector (bound
-- with the same ports RobangoIslandServer gives it): a fresh actor reaches the ridge camp with
-- 9 bag logs, places the campfire there from the bag, and plays the rest of the opening (Marit's
-- request, the beacon wood, the windbreak, the beacon, boarding) to the departure.
local serde = require("@lune/serde")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local Clock = require("../../core/infra/genre/Clock")
local Durable = require("./src/shared/GenreDurable")
local Scene = require("./src/shared/OpeningScene")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")

local ACTOR = "11734795308"

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
	local factoryBuilder = engine.load("games/robango-island/src/server/SurvivalFactory.luau", {}, {
		Parent = {
			LateEquipmentPorts = require("./src/server/LateEquipmentPorts"),
			WorldDressing = engine.dressing,
		},
	})
	local provision = engine.load("games/robango-island/src/server/SurvivalProvision.luau", {}, nil)(
		{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
		Source.tribe.config.tribeId,
		{ studio = false, server = "camp-live" }
	)
	local backend = Memory.new()
	local encode = function(value)
		return serde.encode("json", value)
	end
	local options: any = { sessionId = "camp-live", leaseSeconds = 120, now = now, budget = { encode = encode } }
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
		storeName = "camp-live-personal",
	}, backend, { sessionId = "camp-live", lockTimeout = 120, retries = 0, now = now }, services, Durable)
	factory.bind(session)
	assert(session.join(ACTOR).ok, "join")
	-- The opening ports RobangoIslandServer binds (C1), on the same live reads.
	local contracts: any = nil
	for _, extension in factory.services.survivalExtensions do
		contracts = if extension.id == "contracts" then extension else contracts
	end
	local function data(actor: string): any
		local port = session.personalTransfer(actor)
		return if port then port.profile().data.envelope.genres["survival-coop"].data else nil
	end
	local steps: { string } = {}
	local travelled = 0
	world.opening.bind({
		tutorial = function(actor)
			local view = contracts.snapshot(actor)
			local tutorial = if type(view) == "table" then view.tutorial else nil
			return if type(tutorial) == "table" then tutorial.index else nil,
				type(tutorial) == "table" and tutorial.complete == true
		end,
		items = function(actor)
			local state = data(actor)
			local totals: { [string]: number } = {}
			for _, item: any in state.inventory.bag.items do
				totals[item.catalogId] = (totals[item.catalogId] or 0) + item.quantity
			end
			return totals
		end,
		dodgeAt = function()
			return nil
		end,
		position = function(actor)
			return world.rootPosition(actor)
		end,
		near = function(actor, part)
			return world.nearPart(actor, part)
		end,
		store = factory.expeditionStore,
		analytics = function(_, step)
			table.insert(steps, step)
		end,
		travel = function()
			travelled += 1
			return true
		end,
		spawn = function(fn)
			fn()
		end,
	})
	local sequence = 0
	local function command(action: string, args: { any }): any
		sequence += 1
		at.value += 1
		session.advance(clock.now())
		local name = "survival-coop:" .. action
		return session.command(ACTOR, {
			requestId = "camp-live-" .. sequence,
			sessionEpoch = session.commandEpoch(ACTOR, name),
			action = name,
			args = args,
		})
	end
	local function tick()
		at.value += 1
		world.opening.tick({ ACTOR }, at.value * 1000)
	end
	return {
		engine = engine,
		world = world,
		factory = factory,
		session = session,
		command = command,
		tick = tick,
		steps = steps,
		travelled = function()
			return travelled
		end,
		at = at,
	}
end

local function anchor(world: any, id: string): any
	for _, row in world.layout.anchors do
		if row.id == id then
			return row.position
		end
	end
	error("anchor " .. id)
end

local function give(live: any, id: string, catalogId: string, quantity: number)
	live.session.personalTransaction(ACTOR, function(raw)
		raw.envelope.genres["survival-coop"].data.inventory.bag.items[id] = {
			itemId = id,
			catalogId = catalogId,
			quantity = quantity,
			qualityMilli = 1000,
			durabilityMilli = if catalogId == "stone-axe" then 100000 else 0,
			attributes = {},
		}
		return raw
	end)
end

local function bagCount(live: any, catalogId: string): number
	local total = 0
	for _, item in live.session.snapshot(ACTOR)["survival-coop"].inventory.bag.items do
		total += if item.catalogId == catalogId then item.quantity else 0
	end
	return total
end

local function step(live: any): string?
	local view = live.world.opening.extension.snapshot(ACTOR)
	return if view and view.active then view.step else nil
end

-- A fresh actor's opening up to the ridge camp: the beats before the camp, completed from the same
-- server facts the live director reads (tutorial state, bag, position).
local function toRidgeCamp(live: any)
	live.engine.move(ACTOR, Content.homePolicy.dock)
	live.tick() -- the director loads the fresh actor
	assert(live.command("tutorial-skip-arrival", {}).ok, "arrival")
	assert(live.world.opening.intent(ACTOR, "cold-open-done"), "cold open")
	-- Beat 1: stakes and the scripted dodges (no wildlife; the dodge passes after MAX_TRIES).
	local state = assert(live.world.opening.state(ACTOR))
	assert(Scene.pull(state, 1, live.at.value * 1000) and Scene.pull(state, 2, live.at.value * 1000), "stakes 1-2")
	for _ = 1, Scene.MAX_TRIES do
		live.at.value += 8
		live.world.opening.tick({ ACTOR }, live.at.value * 1000)
	end
	assert(Scene.pull(state, 3, live.at.value * 1000), "stake 3")
	live.tick()
	assert(live.world.opening.intent(ACTOR, "mirror-dismiss"), "mirror")
	-- Beats 3-4: the first gather (fiber) and the hatchet crafted by hand, through the real commands
	-- (they feed the genre tutorial the campfire step reads); the knife is handed over.
	live.engine.move(ACTOR, { x = 6, y = 5, z = 68 })
	local version = live.factory.services.survivalGathering.snapshot(ACTOR).version
	local gathered = live.command("gather", { "rw.onboarding.fiber", version, "fiber" })
	assert(gathered.ok, "first gather: " .. serde.encode("json", gathered))
	give(live, "opening-knife", "bone-knife", 1)
	give(live, "opening-flint", "flint", 2)
	local axe = live.command("craft-reserve", { "stone-axe", "hand" })
	assert(axe.ok, "hatchet reserve: " .. serde.encode("json", axe))
	assert(live.command("craft-start", { axe.data.jobId }).ok, "hatchet start")
	live.at.value += 5
	local crafted = live.command("craft-complete", { axe.data.jobId })
	assert(crafted.ok, "hatchet: " .. serde.encode("json", crafted))
	local tutorial = live.session.snapshot(ACTOR).survivalExtensions.contracts.tutorial
	assert(tutorial.step == "declare-settlement", "tutorial at the camp step: " .. tostring(tutorial.step))
	-- Beat 5: 9 logs in the bag, walk the ford to Marit.
	give(live, "opening-wood", "wood", 9)
	local ford = anchor(live.world, "opening.ford")
	live.engine.move(ACTOR, { x = ford.x, y = 5, z = ford.z })
	live.tick()
	local marit = anchor(live.world, "npc.marit")
	live.engine.move(ACTOR, { x = marit.x, y = 5, z = marit.z + 6 })
	live.tick()
	assert(step(live) == "campfire", "at the ridge camp the opening asks for the campfire: " .. tostring(step(live)))
end

return {
	["a fresh actor at the ridge camp with 9 bag logs places the campfire and the opening reaches departure"] = function()
		local live = boot()
		toRidgeCamp(live)
		-- The camp grid is where the opening sent the player: Marit's camp is on (or beside) it.
		local origin = live.world.roleSource.tribe.origin
		local camp = live.session.snapshot(ACTOR).survivalSettlement
		local config = camp.settlement.config
		local marit = anchor(live.world, "npc.marit")
		local stand = { x = marit.x, z = marit.z + 6 }
		local definition: any
		for _, row in Content.structures do
			definition = if row.id == "campfire" then row else definition
		end
		-- The HUD's first cell: the footprint under the player.
		local cx, cz = Model.startCell(stand.x, stand.z, origin.x, origin.z, config, definition)
		local cellX, cellZ = origin.x + (cx + 1) * config.cellStuds, origin.z + (cz + 1) * config.cellStuds
		assert(
			math.abs(cellX - stand.x) <= config.cellStuds * 2 and math.abs(cellZ - stand.z) <= config.cellStuds * 2,
			string.format("the campfire cell (%d,%d) is under the player at Marit's camp", cellX, cellZ)
		)
		-- The build card counts the bag: 9 logs cover wood 4 although the warehouse is empty.
		local costs, bagUsed = Model.buildCosts(
			camp.warehouse,
			Model.bag(live.session.snapshot(ACTOR)["survival-coop"]),
			definition.cost,
			true
		)
		assert(bagUsed and costs[1].available >= costs[1].needed and costs[1].fromBag == 4, "card: bag covers 4 wood")
		-- Reserve and place exactly as the HUD sends them (warehouse version from the snapshot).
		local reserved = live.command("settlement-reserve", {
			"campfire",
			cx,
			cz,
			0,
			camp.settlement.version,
			camp.warehouse.version,
			camp.settlement.membershipRevision,
		})
		assert(reserved.ok, "campfire reserve at the ridge camp: " .. serde.encode("json", reserved))
		assert(bagCount(live, "wood") == 5, "4 of the 9 bag logs paid the campfire")
		camp = live.session.snapshot(ACTOR).survivalSettlement
		local placed = live.command(
			"settlement-place",
			{ reserved.data.reservationId, camp.settlement.version, camp.warehouse.version }
		)
		assert(placed.ok, "campfire placed: " .. serde.encode("json", placed))
		live.tick()
		assert(step(live) == "accept", "campfire step completes: " .. tostring(step(live)))
		-- Marit stands at the ridge camp with a talk prompt that opens her contracts.
		local figure = assert(live.world.anchorParts["npc.marit"], "Marit's part at the ridge camp")
		local prompt = figure:FindFirstChildOfClass("ProximityPrompt")
		assert(prompt and prompt:GetAttribute("ForgePanel") == "contracts", "Marit opens the contracts board")
		local offers = live.session.snapshot(ACTOR).survivalExtensions.contracts.offers
		local contract = assert(offers[1], "a first-day contract on offer").id
		assert(live.command("contract-accept", { contract }).ok, "Marit's request accepted")
		live.tick()
		assert(step(live) == "deliver", "deliver step: " .. tostring(step(live)))
		-- Deliver what the contract asks for (3 wood for the beacon is the first-day pick).
		for _, item in offers[1].deliver do
			if bagCount(live, item.item) < item.quantity then
				give(live, "deliver-" .. item.item, item.item, item.quantity)
			end
		end
		local delivered = live.command("contract-deliver", { contract })
		assert(delivered.ok, "delivered: " .. serde.encode("json", delivered))
		live.tick()
		assert(step(live) == "windbreak", "windbreak step: " .. tostring(step(live)))
		-- Beat 7: one fiber to the camp windbreak (the camp panel's Put materials in).
		give(live, "windbreak-fiber", "fiber", 1)
		local campState = live.session.snapshot(ACTOR).survivalExtensions.camp
		local given = live.command("camp-contribute", { "windbreak", "windbreak-fiber", 1, campState.version })
		assert(given.ok, "windbreak fiber: " .. serde.encode("json", given))
		live.tick()
		assert(step(live) == "beacon", "beacon step: " .. tostring(step(live)))
		local beacon = anchor(live.world, "opening.beacon")
		live.engine.move(ACTOR, { x = beacon.x + 3, y = 5, z = beacon.z })
		live.engine.interact(ACTOR, "Pole")
		live.tick()
		assert(step(live) == "board", "board step: " .. tostring(step(live)))
		live.at.value += Scene.BOAT_MILLIS // 1000 + 1
		local boarded, why = live.world.opening.intent(ACTOR, "board")
		assert(boarded, "boarding: " .. tostring(why))
		assert(live.travelled() == 1, "the Gannet departs (onboarding -> home travel)")
		assert(step(live) == nil, "the opening is finished")
		for _, id in { "campfire", "accept", "deliver", "windbreak", "beacon", "board" } do
			assert(table.find(live.steps, id), "opening_step " .. id .. ": " .. table.concat(live.steps, ","))
		end
	end,
}
