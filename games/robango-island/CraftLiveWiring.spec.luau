--!strict
-- Staging v40 (phone, two servers): after a tap on the craft detail's to-do toggle the HUD sat on
-- "대기 중 - 서버 확인을 기다리는 중" for 60-90 s, every mutation (만들기, 하나 먹기) disabled. The
-- server had committed it: RecipeMarks (a personal extension) answers ok without a stateVersion,
-- so CommandTransport.settle kept the request, and a resend replayed the same answer forever.
-- This drives the real client model (SurvivalHUDModel) with replies from the real onboarding
-- server wiring (RoleWorld, SurvivalFactory, Session), through to a collected hand craft.
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
local FxStub = require("./src/client/FeedbackFx.fixture")

local function boot(backend: any?, at: any?)
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
	local factoryBuilder = engine.load("games/robango-island/src/server/SurvivalFactory.luau", {}, {
		Parent = {
			LateEquipmentPorts = require("./src/server/LateEquipmentPorts"),
			WorldDressing = engine.dressing,
		},
	})
	local provision = engine.load("games/robango-island/src/server/SurvivalProvision.luau", {}, nil)(
		{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
		Source.tribe.config.tribeId,
		{ studio = false, server = "craft-live" }
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

local packets: { any } = {}
local function client(live: any): any
	local session = live.session
	local sequence = 0
	local model = Model.new(ACTOR, function()
		sequence += 1
		return "hud-" .. sequence
	end)
	local function handshake()
		local epochs = {}
		for _, action in Durable.actions do
			epochs[action] = session.commandEpoch(ACTOR, action)
		end
		model.receive({
			durable = { actions = Durable.actions, sessionEpoch = session.commandEpoch(ACTOR), epochs = epochs },
		})
		local packet = { revision = sequence, snapshots = session.snapshot(ACTOR) }
		table.insert(packets, packet)
		model.receive(packet)
	end
	handshake()
	-- SurvivalHUD.send: the RemoteFunction reply goes straight into model.finish.
	-- Every state packet the client saw, in order (L13 feeds them to FeedbackFx).
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

return {
	["a committed to-do toggle settles and leaves the one-click hand craft free on the live wiring"] = function()
		local live = boot()
		local session = live.session
		assert(session.join(ACTOR).ok, "join")
		live.engine.move(ACTOR, Content.homePolicy.dock)
		local model, send = client(live)
		local mark = assert(model.begin("recipe-mark", { "cord", "todo", true }), "toggle sent")
		local marked = send(mark)
		assert(marked.ok and marked.stateVersion == nil, "personal extension commit carries no stateVersion")
		assert(model.pending == nil, "the committed toggle is final, not 'waiting for the server'")
		assert(model.status == "confirmed", "status " .. tostring(model.status))
		assert(model.snapshot.recipeMarks.todo.cord == true, "the toggle reached the snapshot")
		-- 만들기 (자동 수령): reserve -> start -> collect, exactly as SurvivalHUD chains it.
		local hand = {}
		local request = assert(model.begin("craft-reserve", { "cord", "hand" }), "make is enabled again")
		local guard = 0
		while request do
			guard += 1
			assert(guard < 10, "hand chain ends")
			local result = send(request)
			local verb, args, wait = Model.handChain(request, result, hand, Content.recipes)
			request = nil
			if verb then
				live.at.value += wait or 0
				request = assert(model.begin(verb, args :: any), verb .. " begins")
			end
		end
		assert(model.pending == nil and model.status == "confirmed", "craft settled: " .. tostring(model.reason))
		local cords = 0
		for _, item in session.snapshot(ACTOR)["survival-coop"].inventory.bag.items do
			cords += if item.catalogId == "cord" then item.quantity else 0
		end
		assert(cords == 1, "one cord collected, got " .. cords)
		-- L13: the same live snapshots drive the craft-complete pop. The workshop entry of the hand
		-- craft turns Committed in the last packet: one burst, one "+1 Cord" toast, one icon fly.
		local fx = FxStub.new()
		local toasts, flown = {}, {}
		local root = fx.instance("Part", "HumanoidRootPart")
		root.Position = FxStub.vector(0, 3, 0)
		local body = fx.instance("Model", "Character")
		root.Parent = body
		fx.player.Character = body
		local stop = fx.Fx.start({
			assets = {},
			audio = require("./src/shared/RobangoAudioCatalog"),
			profile = function()
				return "low"
			end,
			reduced = function()
				return false
			end,
			hidden = function()
				return false
			end,
			icon = function(item: string)
				table.insert(flown, item)
				return "rbxassetid://icon-" .. item
			end,
			itemName = function(item: string)
				return if item == "cord" then "Cord" else item
			end,
			toastFormat = "+%d %s",
			toast = function(line: string)
				table.insert(toasts, line)
			end,
			toastGui = fx.instance("ScreenGui", "ForgeGatherFan"),
			names = {},
			itemIds = {},
			defaultOutput = function()
				return nil
			end,
			bagPoint = function()
				return { X = 40, Y = 680 }
			end,
		})
		fx.player.UserId = tonumber(ACTOR)
		for _, packet in packets do
			fx.state.OnClientEvent:Fire(packet)
		end
		assert(#toasts == 1 and toasts[1] == "+1 Cord", "one craft toast, got " .. table.concat(toasts, " | "))
		assert(flown[1] == "cord", "the cord icon flies to the bag")
		assert(fx.emitters().gold.emitted > 0, "the craft pop bursts")
		stop()
		-- Eat is not blocked behind a stale request either.
		assert(model.begin("food", { "starter-berry" }), "eat enabled")
		live.factory.close()
	end,
}
