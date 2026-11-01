--!strict
-- D2b R08 (Studio on 08bc5d0): a tapped dodo, parasaurolophus or boar showed the target bar but
-- never lost a point of health, with or without the bone knife; the character stopped walking and
-- a second tap did not retarget. Every swing was refused WEAPON_UNAVAILABLE (the onboarding bone
-- knife had no melee rule), a final refusal that ended the loop without a word to the player.
-- This drives the real client combat loop (CombatHud with TapRouter's creature handler and durable
-- sender) against the real onboarding server wiring (RoleWorld, SurvivalFactory, Session).
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local serde = require("@lune/serde")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local Clock = require("../../core/infra/genre/Clock")
local Durable = require("./src/shared/GenreDurable")
local CommandTransport = require("../../core/infra/genre/CommandTransport")
local _packText = require("./PackText.fixture")
local PackLocale = require("../../genres/survival-coop/module/PackLocale")
local Combat = require("../../genres/survival-coop/module/CombatHud")

local ACTOR = "11734795308"
local DODO, SECOND = "rw.onboarding.dodo.01.1", "rw.onboarding.dodo.01.2"
local FULL = 45000 -- dodo health (content wildlifeDetails)
local MAX_SWINGS = 8 -- a melee weapon-tool strikes 8, so 6 landed swings kill; 2 spare for pacing

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
		{ studio = false, server = "combat-live" }
	)
	local backend = Memory.new()
	local encode = function(value)
		return serde.encode("json", value)
	end
	local options: any = { sessionId = "combat-live", leaseSeconds = 120, now = now, budget = { encode = encode } }
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
		storeName = "combat-live-personal",
	}, backend, { sessionId = "combat-live", lockTimeout = 120, retries = 0, now = now }, services, Durable)
	factory.bind(session)
	assert(session.join(ACTOR).ok, "join")
	return { engine = engine, world = world, factory = factory, session = session, clock = clock, at = at }
end

-- Puts a carried item in the bag without holding it.
local function stash(live: any, itemId: string, catalogId: string, durability: number)
	live.engine.move(ACTOR, Content.homePolicy.dock)
	assert(live.session.personalTransaction(ACTOR, function(raw: any)
		raw.envelope.genres["survival-coop"].data.inventory.bag.items[itemId] = {
			itemId = itemId,
			catalogId = catalogId,
			quantity = 1,
			qualityMilli = 1000,
			durabilityMilli = durability,
			attributes = {},
		}
		return raw
	end))
end

-- Puts a carried item in the bag (the opening's hand-made bone knife) and holds it as a Tool.
local function hold(live: any, catalogId: string, durability: number)
	stash(live, "held-1", catalogId, durability)
	live.engine.equip(live.world, ACTOR, "held-1")
end

local function hp(live: any, id: string): number
	return live.factory.services.survivalWildlife.snapshot(ACTOR)[id].healthMilli
end

-- The phone: CombatHud plus TapRouter's creature handler and durable sender, over a workspace that
-- mirrors the server's published wildlife (ForgeWildlife models and their attributes).
local function client(live: any, tools: { any }?)
	local I = roblox.Instance
	local t = { value = 0 }
	local folder = I.new("Folder")
	folder.Name = "ForgeWildlife"
	local models: { [string]: any } = {}
	for id, npc in live.factory.services.survivalWildlife.snapshot(ACTOR) do
		local model = I.new("Model")
		model.Name = id
		local part = I.new("Part")
		part.Name, part.Position = "HumanoidRootPart", roblox.Vector3.new(npc.home.x, npc.home.y, npc.home.z)
		part.Parent = model
		model:SetAttribute("ForgeWildlifeId", id)
		model:SetAttribute("ForgeWildlifeKind", npc.catalogId)
		model.Parent = folder
		models[id] = model
	end
	local function mirror()
		for id, npc in live.factory.services.survivalWildlife.snapshot(ACTOR) do
			models[id]:SetAttribute("ForgeWildlifeHealthMilli", npc.healthMilli)
			models[id]:SetAttribute("ForgeWildlifeState", npc.mode)
			-- As WildlifeWorld publishes them: the carcass owner and kill clock of a dead body.
			models[id]:SetAttribute("ForgeWildlifeKiller", if npc.healthMilli == 0 then npc.killer else nil)
			models[id]:SetAttribute("ForgeWildlifeKilledAt", if npc.healthMilli == 0 then npc.killedAt else nil)
		end
	end
	mirror()
	local playerGui = I.new("PlayerGui")
	local root = I.new("Part")
	root.Name = "HumanoidRootPart"
	-- The engine Backpack the server projects bag tools into (SurvivalWorld projectTools): one Tool
	-- per usable tool item, labelled with its catalog id. EquipTool holds it on the server too.
	local held: any = nil
	local backpack = {
		tools = {} :: { any },
		GetChildren = function(self)
			return self.tools
		end,
	}
	for _, entry in tools or {} do
		table.insert(backpack.tools, {
			Name = entry.name,
			itemId = entry.itemId,
			IsA = function(_, class)
				return class == "Tool"
			end,
			GetAttribute = function(_, key)
				return if key == "ForgeCatalogId" then entry.catalogId else nil
			end,
		})
	end
	local humanoid = {
		Health = 100,
		MaxHealth = 100,
		EquipTool = function(_, tool)
			held = tool
			live.engine.equip(live.world, ACTOR, tool.itemId)
		end,
	}
	local character = {
		FindFirstChild = function(_, name)
			return if name == "HumanoidRootPart" then root else nil
		end,
		FindFirstChildOfClass = function(_, class)
			return if class == "Humanoid" then humanoid elseif class == "Tool" then held else nil
		end,
	}
	local attributes: { [string]: any } = {}
	local watchers: { [string]: { () -> () } } = {}
	local player = {
		Character = character,
		UserId = tonumber(ACTOR),
		GetAttribute = function(_, key)
			return attributes[key]
		end,
		SetAttribute = function(_, key, value)
			attributes[key] = value
			for _, fn in watchers[key] or {} do
				fn()
			end
		end,
		GetAttributeChangedSignal = function(_, key)
			return {
				Connect = function(_, fn)
					watchers[key] = watchers[key] or {}
					table.insert(watchers[key], fn)
					return { Disconnect = function() end }
				end,
			}
		end,
		WaitForChild = function()
			return playerGui
		end,
		FindFirstChild = function()
			return nil
		end,
		FindFirstChildOfClass = function(_, class)
			return if class == "Backpack" then backpack else nil
		end,
	}
	local function place(position: any)
		root.Position = position
		live.engine.move(ACTOR, { x = position.X, y = position.Y, z = position.Z })
	end
	local beats: { () -> () } = {}
	local stateListeners: { (any) -> () } = {}
	local sent: { any } = {}
	local results: { any } = {}
	local function signal(list: { any }?)
		return {
			Connect = function(_, fn)
				if list then
					table.insert(list, fn)
				end
				return { Disconnect = function() end }
			end,
		}
	end
	local guid = 0
	-- Where every world point lands on screen (the body's screen point for the picker).
	local view = { point = roblox.Vector3.new(400, 200, 0) }
	local services: { [string]: any } = {
		Players = { LocalPlayer = player },
		RunService = { Heartbeat = signal(beats) },
		Workspace = {
			FindFirstChild = function(_, name)
				return if name == "ForgeWildlife" then folder else nil
			end,
			CurrentCamera = {
				WorldToViewportPoint = function()
					return view.point, true
				end,
			},
		},
		ReplicatedStorage = {
			WaitForChild = function(_, name)
				if name == "ForgeAction" then
					return {
						InvokeServer = function(_, kind, request)
							assert(kind == "command", "durable command")
							table.insert(sent, request)
							local result = live.session.command(ACTOR, table.clone(request))
							table.insert(results, { request = request, result = result })
							return result
						end,
					}
				end
				return { OnClientEvent = signal(stateListeners) }
			end,
		},
		HttpService = {
			GenerateGUID = function()
				guid += 1
				return "combat-live-" .. guid
			end,
		},
	}
	local environment: any = {
		game = {
			GetService = function(_, name)
				return assert(services[name], name)
			end,
		},
		os = {
			clock = function()
				return t.value
			end,
		},
		-- A swing runs to its reply at once; a float animation parks at its first frame wait.
		task = {
			spawn = function(fn, ...)
				coroutine.resume(coroutine.create(fn), ...)
			end,
			wait = function()
				coroutine.yield()
			end,
		},
	}
	for key, value in roblox do
		environment[key] = value
	end
	local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), { environment = environment })()
	-- Lune computes no layout (AbsoluteSize); token styling is presentation, the fan's visibility is
	-- what this spec reads.
	local pebbled = 0
	shell.pebble = function()
		pebbled += 1
	end
	environment.require = function(path: string)
		return if path == "./HudShell" then shell else PackLocale
	end
	-- Lune Instances have no events: a button's Activated is a no-op signal (registered once per run).
	pcall(roblox.implementProperty, "TextButton", "Activated", function()
		return signal()
	end)
	local Hud = luau.load(fs.readFile("genres/survival-coop/module/CombatHud.luau"), { environment = environment })()
	local Router = luau.load(fs.readFile("games/robango-island/src/client/TapRouter.luau"), {
		environment = { game = environment.game, Vector3 = roblox.Vector3 },
	})()
	local send: any = nil
	local approaches = 0
	local sea: { x: number? } = {}
	local hud = Hud.start({
		content = Content,
		locale = "en-us",
		send = function(verb, args)
			return send(verb, args)
		end,
		-- The walk: arrive half a stud inside `within` (flat) of the goal, on the server too.
		-- `sea`: x beyond which the world is water; the real approach (TapRouter.moveAshore) refuses it.
		approach = function(goal: any, within: number, arrive: () -> ()): boolean
			if sea.x and goal.X < sea.x then
				return false
			end
			approaches += 1
			local flat = roblox.Vector3.new(root.Position.X - goal.X, 0, root.Position.Z - goal.Z)
			local away = if flat.Magnitude > 0 then flat.Unit else roblox.Vector3.new(1, 0, 0)
			local offset = away * (within - 0.5)
			place(roblox.Vector3.new(goal.X + offset.X, 3, goal.Z + offset.Z))
			arrive()
			return true
		end,
		stop = function() end,
		name = function(id: string)
			return id
		end,
		itemName = function(id: string)
			return id
		end,
		hidden = function()
			return false
		end,
		serverNow = function()
			return live.at.value
		end,
	})
	local tap: any = { handlers = {} }
	function tap.register(kind, fn)
		tap.handlers[kind] = fn
		return function() end
	end
	local _remove
	_remove, send = Router.installActions(tap, CommandTransport, hud, nil, nil)
	local function handshake()
		local epochs = {}
		for _, action in Durable.actions do
			epochs[action] = live.session.commandEpoch(ACTOR, action)
		end
		for _, listener in stateListeners do
			listener({
				durable = {
					actions = Durable.actions,
					sessionEpoch = live.session.commandEpoch(ACTOR),
					epochs = epochs,
				},
			})
		end
	end
	handshake()
	local gui = playerGui:FindFirstChild("ForgeCombatHUD")
	gui.AbsoluteSize, gui.AbsolutePosition = roblox.Vector2.new(1280, 720), roblox.Vector2.zero
	return {
		models = models,
		player = player,
		view = view,
		sent = sent,
		results = results,
		place = place,
		gui = gui,
		humanoid = humanoid,
		held = function(): any
			return held
		end,
		pause = function()
			hud.pause()
		end,
		bar = function(): boolean
			return gui:FindFirstChild("TargetBar").Visible and gui:FindFirstChild("EndCombat").Visible
		end,
		approaches = function(): number
			return approaches
		end,
		sea = sea,
		root = root,
		tap = function(id: string): boolean
			return tap.handlers.creature(models[id]) ~= false
		end,
		hud = hud,
		playerGui = playerGui,
		-- One second (or `seconds`): the server ticks (windups resolve), the world republishes, one
		-- HUD frame runs.
		tick = function(seconds: number?)
			live.at.value += seconds or 1
			t.value += seconds or 1
			live.session.advance(live.clock.now())
			handshake()
			mirror()
			beats[1]()
		end,
		floats = function(): { string }
			local out = {}
			local numbers = playerGui:FindFirstChild("ForgeDamageNumbers")
			for _, board in numbers:GetChildren() do
				if board.Enabled then
					table.insert(out, board.Text.Text)
				end
			end
			return out
		end,
	}
end

-- Swings the server accepted at `id` (confirmed, or accepted and resolving after the windup);
-- cooldown refusals in between are pacing, not swings.
local function swingsAt(phone: any, id: string): number
	local ids: { [string]: boolean } = {}
	local count = 0
	for _, entry in phone.results do
		local request, result = entry.request, entry.result
		local accepted = result.ok or result.reason == "WINDUP"
		if request.action == "survival-coop:attack" and request.args[1] == id and accepted then
			if not ids[request.requestId] then
				ids[request.requestId] = true
				count += 1
			end
		end
	end
	return count
end

-- Distinct attack requests the phone sent at `id` (a retry keeps its id).
local function requestsAt(phone: any, id: string): number
	local ids: { [string]: boolean } = {}
	local count = 0
	for _, request in phone.sent do
		if request.action == "survival-coop:attack" and request.args[1] == id and not ids[request.requestId] then
			ids[request.requestId] = true
			count += 1
		end
	end
	return count
end

-- R09 starter capture: the durable sender of the phone (the PetRing sends through the same transport).
local commands = 0
local function command(live: any, action: string, args: { any }): any
	local session = live.session
	commands += 1
	return session.command(ACTOR, {
		requestId = "tame-" .. commands,
		sessionEpoch = session.commandEpoch(ACTOR, action) or 0,
		action = action,
		args = args,
	})
end

local function companions(live: any): any
	return live.session.personalTransfer(ACTOR).profile().data.envelope.genres["survival-coop"].data.companions
end

-- The guide reward path: the first-axe guide's starter bola lands in the bag via the reward outbox.
local function rewardBola(live: any)
	local axe: any = nil
	for _, guide in Content.guides do
		axe = if guide.id == "rw.g02.first-axe" then guide else axe
	end
	local bola = false
	for _, stack in axe.rewards.items do
		bola = bola or stack.item == Content.progressionPolicy.companion.starterTool
	end
	assert(bola, "the first-axe guide rewards the starter bola")
	stash(live, "guide:rw.g02.first-axe:2:1", "capture-bola", 100000)
end

local function fight(phone: any, live: any, id: string, seconds: number)
	for _ = 1, seconds do
		phone.tick()
		if hp(live, id) == 0 then
			phone.tick()
			return
		end
	end
end

return {
	-- D2 phone R08 (v63-v67): no target bar, damage number or engaged border showed in any frame; the
	-- engaged cue was four faint (0.12) coral corners. A tap opens the bar at once, every landed hit
	-- floats "-N" over the target, and a full-edge red border shows while engaged and fades after.
	["a creature tap opens the target bar at once, each hit floats a number, and a red edge border shows while engaged"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		phone.gui.AbsoluteSize = roblox.Vector2.new(2400, 1080)
		local model = phone.models[DODO]
		local dodo = model.HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 15, 3, dodo.Z))
		assert(not phone.bar(), "no bar before the tap")
		assert(phone.tap(DODO), "the creature tap engages")
		-- Before any frame, swing or server reply: the bar names the target and reads full health.
		assert(phone.bar(), "the tap itself opens the target bar and step-back pill")
		local bar = phone.gui:FindFirstChild("TargetBar")
		assert(string.find(bar:FindFirstChild("Name").Text, "dodo", 1, true), "the bar names the dodo")
		assert(bar.Track.Fill.Size.X.Scale == 1, "an unhurt dodo reads full")
		assert(bar.Track.Health.Text == string.format("%d / %d", FULL // 1000, FULL // 1000), bar.Track.Health.Text)
		-- The border: its own inset-ignoring gui of four full-length bands.
		local edge = phone.playerGui:FindFirstChild("ForgeCombatEdge")
		assert(edge and edge.IgnoreGuiInset, "an edge border gui that reaches the physical screen edge")
		local border = edge:FindFirstChild("EngagedBorder")
		assert(border:GetAttribute("ForgeTapThrough"), "the border never swallows a world tap")
		-- Enabled number boards over the dodo, by text (the harness parks each float on its first frame).
		local function over(): { [string]: number }
			local counts: { [string]: number } = {}
			for _, board in phone.playerGui:FindFirstChild("ForgeDamageNumbers"):GetChildren() do
				if board.Enabled and board.Adornee == model.HumanoidRootPart then
					counts[board.Text.Text] = (counts[board.Text.Text] or 0) + 1
				end
			end
			return counts
		end
		local health = FULL
		local hits = 0
		for _ = 1, 40 do
			local shown = over()
			phone.tick()
			local now = hp(live, DODO)
			if now < health then
				local want = Combat.damageText(Combat.hit(health, now) :: number)
				assert(string.sub(want, 1, 1) == "-", "a damage number reads as a loss")
				assert((over()[want] or 0) == (shown[want] or 0) + 1, "the hit floated " .. want .. " over the dodo")
				hits += 1
				health = now
			end
			if now == 0 then
				break
			end
			if hits == 1 then
				-- Mid-fight on a 2400x1080 phone: a visible red band along every edge.
				assert(border.Visible, "the border shows while engaged")
				assert(border:GetAttribute("ForgeGlow") >= 0.3, "strong enough to read on a phone")
				local names = {}
				for _, band in border:GetChildren() do
					names[band.Name] = true
					local across = band.Name == "Top" or band.Name == "Bottom"
					local long = if across then band.Size.X else band.Size.Y
					local deep = if across then band.Size.Y else band.Size.X
					assert(long.Scale == 1, band.Name .. " spans the full edge")
					assert(deep.Offset >= 100, band.Name .. " band depth " .. deep.Offset .. " px")
					assert(band.BackgroundColor3.R > 0.6 and band.BackgroundColor3.G < 0.3, band.Name .. " is red")
				end
				assert(names.Top and names.Bottom and names.Left and names.Right, "all four edges")
			end
		end
		assert(hits >= 2, "several landed hits each floated a number, got " .. hits)
		live.factory.close()
	end,
	["the engaged border fades out after the player steps back"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local dodo = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 3, 3, dodo.Z))
		assert(phone.tap(DODO), "engage")
		phone.tick()
		local border = phone.playerGui:FindFirstChild("ForgeCombatEdge"):FindFirstChild("EngagedBorder")
		assert(border.Visible, "engaged: border up")
		phone.hud.disengage()
		phone.tick(0.2)
		assert(not phone.bar(), "stepped back: no bar")
		assert(border.Visible and border:GetAttribute("ForgeGlow") > 0, "the border fades rather than snaps off")
		phone.tick(1)
		assert(not border.Visible, "faded out after disengage")
		live.factory.close()
	end,
	["a tapped dodo is walked up to and struck until it dies, holding the opening bone knife"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local dodo = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 15, 3, dodo.Z))
		assert(phone.tap(DODO), "the creature tap engages")
		fight(phone, live, DODO, 40)
		assert(phone.approaches() >= 1, "the character walked to the dodo")
		assert(hp(live, DODO) == 0, "the dodo died on the server, health " .. hp(live, DODO))
		local swings = swingsAt(phone, DODO)
		assert(swings <= MAX_SWINGS, "dodo died within " .. MAX_SWINGS .. " swings, took " .. swings)
		local bar = phone.gui:FindFirstChild("TargetBar")
		assert(bar.Track.Fill.Size.X.Scale == 0, "the target bar reads the kill")
		-- Kill -> carcass: the fan offers the dodo's outputs over the body.
		assert(phone.gui:FindFirstChild("CarcassFan").Visible, "the carcass fan opens over the body")
		live.factory.close()
	end,
	-- p134 v53: a dodo died ~100 studs from the player and no carcass picker ever showed; nothing
	-- reached the bag. The extension's wildlife port dropped killer/killedAt, so every carcass-take
	-- was refused NOT_DEAD, a dead body was not tappable (the tap walked only), and the fan was the
	-- only way in: opened once on the engaged kill, gone after 120 s or a Leave, never reopenable.
	["a knifed dodo leaves a marked carcass that persists and harvests into the bag from afar"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local model = phone.models[DODO]
		local died = model.HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(died.X + 15, 3, died.Z))
		assert(phone.tap(DODO), "engage")
		fight(phone, live, DODO, 40)
		assert(hp(live, DODO) == 0, "the dodo died, health " .. hp(live, DODO))
		local npc = live.factory.services.survivalWildlife.snapshot(ACTOR)[DODO]
		assert(npc.killer == ACTOR and type(npc.killedAt) == "number", "the server recorded the kill")
		-- The kill is announced and the body is marked where it fell.
		local toast = phone.gui:FindFirstChild("KillToast")
		assert(toast.Visible and toast.Text == string.format(Combat.text("en-us", "kill_toast"), "dodo"), toast.Text)
		local marks = phone.playerGui:FindFirstChild("ForgeCarcassMarks")
		local board = marks:FindFirstChild("CarcassMark")
		assert(board and board.Adornee == model.HumanoidRootPart, "a name mark over the body")
		-- p134 v55: drawn over terrain and water at any play-camera distance.
		assert(board.AlwaysOnTop and board.MaxDistance >= 120, "the mark shows through water from afar")
		assert(board.Label.Text == string.format(Combat.text("en-us", "carcass_mark"), "dodo"), board.Label.Text)
		assert(marks:FindFirstChild("CarcassRing"), "a ground ring at the body")
		-- It persists: four minutes on (the fan closed long ago), body, mark and kill are all still there.
		for _ = 1, 12 do
			phone.tick(20)
		end
		assert(not phone.gui:FindFirstChild("CarcassFan").Visible, "the kill-time fan closed by itself")
		assert(not toast.Visible, "the toast faded")
		assert(model.Parent and model.HumanoidRootPart.Position == died, "the body stays where it died")
		assert(hp(live, DODO) == 0 and marks:FindFirstChild("CarcassMark"), "still a marked carcass")
		-- A tap on the body from ~100 studs walks there and opens the harvest picker on arrival.
		phone.place(roblox.Vector3.new(died.X + 100, 3, died.Z))
		local walks = phone.approaches()
		assert(phone.tap(DODO), "the far carcass tap is handled")
		assert(phone.approaches() == walks + 1, "the character walked to the carcass")
		assert(phone.hud.picking() == model, "the picker opened on arrival")
		phone.tick()
		assert(phone.gui:FindFirstChild("CarcassFan").Visible, "the harvest fan shows over the body")
		local before = {}
		for _, item in live.session.snapshot(ACTOR)["survival-coop"].inventory.bag.items do
			before[item.catalogId] = (before[item.catalogId] or 0) + item.quantity
		end
		local outputs = Combat.offer(Content, "dodo", {})
		assert(#outputs == 2, "dodo offers meat and feathers")
		for _ = 1, #outputs do
			phone.hud.pick(1)
			phone.tick()
		end
		local after = {}
		for _, item in live.session.snapshot(ACTOR)["survival-coop"].inventory.bag.items do
			after[item.catalogId] = (after[item.catalogId] or 0) + item.quantity
		end
		for _, output in outputs do
			assert(
				(after[output.item] or 0) - (before[output.item] or 0) == output.quantity,
				output.item .. " landed in the bag: " .. tostring(after[output.item])
			)
		end
		assert(phone.hud.picking() == nil, "an emptied carcass closes the picker")
		assert(not marks:FindFirstChild("CarcassMark"), "and loses its mark")
		assert(not phone.tap(DODO), "an emptied carcass is no longer a tap target")
		live.factory.close()
	end,
	-- p134 v55 (SM-N981N): the body lay low on screen and the picker's 'Leave it' pill sat on the
	-- Roblox Backpack hotbar; the tap selected the bola slot and the picker stayed open.
	["the harvest picker stays above the hotbar band and hides the hotbar while open"] = function()
		local Flow = (require :: any)("./src/first/TitleFlow")
		-- HudKit needs the engine to load; its hotbar reserve is read from source.
		local reserve =
			tonumber(string.match(fs.readFile("core/ui-kit/genre/HudKit.luau"), "M%.HOTBAR_RESERVE = (%d+)"))
		assert(reserve and Combat.FAN_HOTBAR_RESERVE >= reserve, "the picker keeps the hotbar band clear")
		local Kit = { HOTBAR_RESERVE = reserve :: number }
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		phone.player:SetAttribute("ForgeTitleDone", true)
		local shown: { boolean } = {}
		Flow.bindBackpack(phone.player, function(on: boolean)
			table.insert(shown, on)
		end)
		assert(shown[#shown] == true, "hotbar shown in play")
		local dodo = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 3, 3, dodo.Z))
		assert(phone.tap(DODO), "engage")
		fight(phone, live, DODO, 40)
		assert(hp(live, DODO) == 0, "killed")
		local fan = phone.gui:FindFirstChild("CarcassFan")
		for _, size in { { 800, 360 }, { 1280, 720 } } do
			local w, h = size[1], size[2]
			phone.gui.AbsoluteSize = roblox.Vector2.new(w, h)
			-- The body sits right where the hotbar is: bottom centre of the screen.
			phone.view.point = roblox.Vector3.new(w / 2, h - 30, 10)
			phone.tick(0)
			assert(fan.Visible, "picker open at " .. w)
			local band = h - Kit.HOTBAR_RESERVE
			local leave = fan:FindFirstChild("Leave")
			assert(
				leave.Position.Y.Offset + leave.Size.Y.Offset <= band,
				string.format(
					"Leave pill bottom %d clears the hotbar band %d at %dx%d",
					leave.Position.Y.Offset + leave.Size.Y.Offset,
					band,
					w,
					h
				)
			)
			for _, token in fan:GetChildren() do
				if token.Name == "Output" and token.Visible then
					local bottom = token.Position.Y.Offset + token.Size.Y.Offset / 2
					local top = token.Position.Y.Offset - token.Size.Y.Offset / 2
					assert(bottom <= band and top >= 0, "output token on screen above the hotbar at " .. w)
				end
			end
			assert(phone.player:GetAttribute(Combat.PICKER_ATTRIBUTE) == true, "picker flag set")
			assert(shown[#shown] == false, "the hotbar hides while the picker shows at " .. w)
		end
		-- The picker closes by itself after two minutes; the hotbar comes back.
		phone.tick(121)
		assert(not fan.Visible, "picker closed")
		assert(phone.player:GetAttribute(Combat.PICKER_ATTRIBUTE) == nil, "picker flag cleared")
		assert(shown[#shown] == true, "the hotbar is back once the picker closes")
		live.factory.close()
	end,
	-- p134 v53/v55 (SM-N981N): by the ford herd the knife's attack and taps beside a dodo picked the
	-- Lv 20 parasaurolophus (325 HP) first. Automatic picks (attack button, fingertip pick) skip a
	-- creature far above the player; a tapped creature still engages whatever its level.
	["automatic targeting skips the Lv 20 parasaurolophus for a fresh player; a direct tap still engages it"] = function()
		local Model = (require :: any)("../../genres/survival-coop/module/SurvivalHUDModel")
		local live = server()
		local level = live.session.snapshot(ACTOR)["survival-coop"].progression.level
		assert(level < 10, "a fresh player is below the onboarding herd's level, got " .. tostring(level))
		local phone = client(live)
		local para: string? = nil
		for id, model in phone.models do
			if model:GetAttribute("ForgeWildlifeKind") == "parasaurolophus" then
				para = id
			end
		end
		assert(para, "the ford herd is on the onboarding island")
		local paraId = para :: string
		local p = phone.models[paraId].HumanoidRootPart.Position
		local candidates = {
			{ kind = "parasaurolophus", distance = 2, target = paraId },
			{ kind = "dodo", distance = 7, target = DODO },
		}
		assert(Model.autoTarget(Content, candidates, level) == DODO, "the dodo, not the nearer Lv 20")
		assert(Model.autoTarget(Content, { candidates[1] }, level) == nil, "a lone Lv 20 is no automatic target")
		assert(Model.autoTarget(Content, { candidates[1] }, 20) == paraId, "a Lv 20 player may auto-target it")
		assert(Model.autoEligible(Content, "boar", level), "every Lv 10 onboarding species stays eligible")
		-- The runtime pickers read it: the attack button, the context buttons and the tap pick.
		local hudSource = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(
			select(2, string.gsub(hudSource, "Model%.auto", "")) >= 2,
			"SurvivalHUD attack + buttons filter by level"
		)
		local wiring = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(wiring, "hudModel.autoEligible(content", 1, true), "the tap router's pick filters by level")
		-- p134 v58: the attack button sent one raw swing per press (picked at 8 studs, the knife
		-- reaches 5), refused OUT_OF_RANGE/COOLDOWN as 'Action refused'. It engages the loop instead.
		assert(string.find(hudSource, "options.engage(picked.model)", 1, true), "the attack button engages")
		assert(string.find(wiring, "engageCreature = combatHud.engage", 1, true), "wired to the combat loop")
		-- A direct tap on the parasaurolophus is the player's choice: it engages.
		phone.place(roblox.Vector3.new(p.X + 3, 3, p.Z))
		assert(phone.tap(paraId), "a tapped Lv 20 engages")
		phone.tick()
		assert(phone.bar(), "the bar shows the tapped target")
		live.factory.close()
	end,
	-- p134 v55: the first dodo took ~30 min to find: a killed creature never came back, so the
	-- onboarding trio by the path thinned out for good. After its carcass window it is back at home.
	["a killed onboarding dodo respawns at home, whole, a few minutes after its carcass window"] = function()
		local Runtime = (require :: any)("../../genres/survival-coop/module/WildlifeRuntime")
		local Carcass = (require :: any)("../../genres/survival-coop/module/CarcassExtension")
		assert(Runtime.RESPAWN_SECONDS > Carcass.LIFETIME_SECONDS, "the body is harvestable for its whole window")
		assert(Runtime.RESPAWN_SECONDS <= 600, "back within a few minutes")
		-- The wildlife store is durable per provision: a body saved dead before kills respawned (or
		-- before killedAt existed) comes back on the next sweep instead of staying dead for good.
		assert(Runtime.respawnDue({ healthMilli = 0 } :: any, 0), "a legacy body with no kill clock respawns")
		assert(not Runtime.respawnDue({ healthMilli = 0, killedAt = 0, captureId = "c" } :: any, 1e9), "not a tame")
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local dodo = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 3, 3, dodo.Z))
		assert(phone.tap(DODO), "engage")
		fight(phone, live, DODO, 40)
		assert(hp(live, DODO) == 0, "killed")
		local killedAt = live.factory.services.survivalWildlife.snapshot(ACTOR)[DODO].killedAt
		phone.pause()
		phone.place(roblox.Vector3.new(dodo.X + 120, 3, dodo.Z))
		-- Still a carcass inside its window.
		while live.at.value < killedAt + Carcass.LIFETIME_SECONDS - 5 do
			phone.tick(5)
		end
		assert(hp(live, DODO) == 0, "a body inside its harvest window stays a body")
		for _ = 1, math.ceil((Runtime.RESPAWN_SECONDS - Carcass.LIFETIME_SECONDS + 30) / 10) do
			phone.tick(10)
		end
		local npc = live.factory.services.survivalWildlife.snapshot(ACTOR)[DODO]
		assert(npc.healthMilli == FULL, "the dodo is back with full health, got " .. npc.healthMilli)
		assert(npc.killer == nil and npc.killedAt == nil and npc.mode ~= "dead", "a fresh creature")
		assert(phone.models[DODO]:GetAttribute("ForgeWildlifeKiller") == nil, "no carcass mark is left")
		-- And it can be hunted again.
		phone.place(roblox.Vector3.new(npc.home.x + 3, 3, npc.home.z))
		assert(phone.tap(DODO), "the respawned dodo engages")
		fight(phone, live, DODO, 40)
		assert(hp(live, DODO) == 0, "and dies again")
		live.factory.close()
	end,
	["a carcass mark expires with the server harvest window"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local died = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(died.X + 3, 3, died.Z))
		assert(phone.tap(DODO), "engage")
		fight(phone, live, DODO, 40)
		assert(hp(live, DODO) == 0, "killed")
		local marks = phone.playerGui:FindFirstChild("ForgeCarcassMarks")
		assert(marks:FindFirstChild("CarcassMark"), "marked")
		for _ = 1, 16 do
			phone.tick(20)
		end
		assert(not marks:FindFirstChild("CarcassMark"), "spoiled after the harvest window: no mark")
		assert(not phone.tap(DODO), "and no walk to a body the server would refuse")
		live.factory.close()
	end,
	-- p134 v51: walking the onboarding camp, the tester found nothing huntable in reach (the taps hit
	-- Tumble, a client-only companion, and a scenery rock). A dodo herd grazes beside the main path
	-- on the camp leg, and a tap from the camp workbench hunts it with the bone knife.
	["a dodo grazes beside the camp leg of the start path and a tap from camp hunts it"] = function()
		local layout: any = nil
		for _, entry in Content.layouts do
			if entry.id == "rw.onboarding" then
				layout = entry
			end
		end
		local path: any = nil
		for _, entry in layout.paths do
			if entry.id == "rw.onboarding.main" then
				path = entry
			end
		end
		local function segment(px: number, pz: number, a: any, b: any): number
			local dx, dz = b.x - a.x, b.z - a.z
			local t = math.clamp(((px - a.x) * dx + (pz - a.z) * dz) / (dx * dx + dz * dz), 0, 1)
			return math.sqrt((px - a.x - t * dx) ^ 2 + (pz - a.z - t * dz) ^ 2)
		end
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local bench: any = nil
		for _, anchor in layout.anchors do
			if anchor.id == "station.workbench.t1" then
				bench = anchor.position
			end
		end
		local target: string? = nil
		for id, model in phone.models do
			local p = model.HumanoidRootPart.Position
			local kind = model:GetAttribute("ForgeWildlifeKind")
			local near = math.huge
			for index = 1, #path.points - 1 do
				near = math.min(near, segment(p.X, p.Z, path.points[index], path.points[index + 1]))
			end
			local camp = math.sqrt((p.X - bench.x) ^ 2 + (p.Z - bench.z) ^ 2)
			if kind == "dodo" and near <= path.width and camp <= 45 and not target then
				target = id
			end
		end
		assert(target, "a dodo grazes within the path width of the main path and 45 studs of the workbench")
		local id = target :: string
		phone.place(roblox.Vector3.new(bench.x, 3, bench.z))
		assert(phone.tap(id), "the creature tap engages")
		fight(phone, live, id, 60)
		assert(phone.approaches() >= 1, "the character walked to the dodo")
		assert(hp(live, id) == 0, "the camp dodo died on the server, health " .. hp(live, id))
		assert(swingsAt(phone, id) <= MAX_SWINGS, "within " .. MAX_SWINGS .. " swings")
		live.factory.close()
	end,
	-- p134 v58/v59 (SM-N981N): attack presses on a fleeing dodo did no damage (v58 'Action refused',
	-- v59 46 silent swings at 45/45). The server's 0.6 s windup resolved melee from where the swing
	-- began; the chased dodo was always past the knife's 5 studs from there. Drives the phone's
	-- loop and the real onboarding command path, the dodo and the player both moving on in the windup.
	["a dodo fleeing through the windup still takes the blow from a player who keeps up"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local home = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(home.X + 3, 3, home.Z))
		assert(phone.tap(DODO), "engage")
		phone.tick(0)
		local accepted = phone.results[#phone.results]
		assert(accepted and accepted.result.reason == "WINDUP", "the swing was accepted into its windup")
		-- It bolts 6 studs; the player keeps up, 3 studs behind it the whole time.
		local fled = { x = home.X - 6, y = home.Y, z = home.Z }
		live.engine.wildlifeAt(DODO, fled)
		phone.place(roblox.Vector3.new(fled.x + 3, 3, fled.z))
		phone.tick()
		assert(hp(live, DODO) < FULL, "the fleeing dodo took the blow, health " .. hp(live, DODO))
		live.engine.wildlifeAt(DODO, nil)
		live.factory.close()
	end,
	-- p134 v58/v59: no rig speed was set, so a dodo (content run 10) fled at the engine default 16,
	-- the player's own pace, and a chase never closed in. The live world paces each species.
	-- p134 v58: a refused attack read 'Action refused / refresh and review your supplies' (the
	-- hud.unknown fallback): no attack refusal had its own HUD line.
	["every final attack refusal has its own HUD line, and an accepted windup is no refusal"] = function()
		local Hud = (require :: any)("../../genres/survival-coop/module/SurvivalHUDLocale")
		local Model = (require :: any)("../../genres/survival-coop/module/SurvivalHUDModel")
		local fallback = Hud.refusal("ko-kr", "NO_SUCH_REASON")
		for _, reason in
			{
				"COOLDOWN",
				"RECOVERY",
				"OUT_OF_RANGE",
				"NOT_FACING",
				"BLOCKED",
				"ALREADY_DEAD",
				"UNKNOWN_TARGET",
				"NOT_ALIVE",
				"MOUNTED",
				"ALREADY_CAPTURED",
				"WEAPON_UNAVAILABLE",
			}
		do
			for _, locale in { "en-us", "ko-kr" } do
				assert(Hud.refusal(locale, reason) ~= Hud.refusal(locale, "NO_SUCH_REASON"), reason .. " " .. locale)
			end
		end
		assert(fallback ~= "", "fallback exists")
		assert(Model.TRANSIENT.WINDUP, "a swing in its windup is pending, not 'Action refused'")
		local state = Model.new(ACTOR, function()
			return "r1"
		end)
		state.durable = { actions = { "survival-coop:attack" }, sessionEpoch = 0 }
		assert(state.begin("attack", { DODO }), "begin")
		state.finish(true, { ok = false, reason = "WINDUP", data = { status = "pending" } })
		assert(state.status == "pending" and state.reason == nil, "windup shows as pending, got " .. state.status)
		assert(Combat.text("ko-kr", "attack.MISS") ~= "attack.MISS", "a miss has copy")
		assert(Combat.text("ko-kr", "attack.FLED") ~= "attack.FLED", "a given-up chase has copy")
	end,
	["creatures walk and run at their authored speeds, slower than the player"] = function()
		local fs2 = require("@lune/fs")
		local luau2 = require("@lune/luau")
		local World = luau2.load(fs2.readFile("genres/survival-coop/module/WildlifeWorld.luau"), {
			environment = {
				require = function()
					return {}
				end,
				game = {
					GetService = function()
						return {}
					end,
				},
			},
		})()
		local dodo: any = nil
		for _, detail in (Content :: any).wildlifeDetails do
			if detail.id == "dodo" then
				dodo = detail
			end
		end
		assert(dodo and dodo.runSpeed < 16, "the dodo runs slower than a player walks")
		local row = { id = "dodo", walkSpeed = dodo.walkSpeed, runSpeed = dodo.runSpeed }
		assert(World.pace(row, "flee") == dodo.runSpeed, "a fleeing dodo runs at its runSpeed")
		assert(World.pace(row, "roam") == dodo.walkSpeed, "a roaming dodo walks")
		assert(World.pace({ id = "x" }, "flee") == nil, "a row without speeds keeps the engine default")
		-- The live registration reads the details row (content.wildlife has no speeds).
		local source = fs2.readFile("genres/survival-coop/module/WildlifeWorld.luau")
		assert(string.find(source, "humanoid.WalkSpeed = pace", 1, true), "the pace drives the rig")
	end,
	-- Studio D2 (x -423, X282 Y388) and p134 v58/v59 (-172,-378; X -760): the loop chased a fleeing
	-- dodo into the sea. The approach stops at the shore and the chase ends with a line on screen.
	["a dodo fleeing out over the water is not chased into the sea"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local home = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(home.X + 20, 3, home.Z))
		phone.sea.x = home.X - 10
		-- It is already out over the water when the fight starts.
		phone.models[DODO].HumanoidRootPart.Position = roblox.Vector3.new(home.X - 30, home.Y, home.Z)
		assert(phone.tap(DODO), "engage")
		phone.tick()
		assert(phone.approaches() == 0, "no walk toward a target in the sea")
		assert(phone.root.Position.X > phone.sea.x, "the player is still ashore")
		assert(not phone.bar(), "the chase ended")
		assert(table.find(phone.floats(), Combat.text("en-us", "attack.FLED")), "it says the dodo got away")
		-- And the auto loop leash: a chase that keeps going ends past CHASE_STUDS.
		assert(Combat.CHASE_STUDS <= 60, "the leash is short")
		-- The phone's approach is the shore-stopping walk (TapRouter.moveAshore over TapRouter.shore).
		local wiring = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(wiring, "tapInput.moveAshore(goal, within, arrive)", 1, true), "approach stops ashore")
		live.factory.close()
	end,
	["tapping a second creature retargets the loop and it dies too"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local first = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(first.X + 15, 3, first.Z))
		assert(phone.tap(DODO), "first engage")
		for _ = 1, 20 do
			phone.tick()
			if hp(live, DODO) < FULL then
				break
			end
		end
		local wounded = hp(live, DODO)
		assert(wounded < FULL, "the first dodo was hit")
		assert(phone.tap(SECOND), "second engage")
		fight(phone, live, SECOND, 40)
		assert(hp(live, SECOND) == 0, "the second dodo died, health " .. hp(live, SECOND))
		assert(hp(live, DODO) > 0, "the first dodo was left alive after the retarget")
		assert(
			string.find(phone.gui.TargetBar:FindFirstChild("Name").Text, "dodo", 1, true) ~= nil,
			"the bar names the target"
		)
		live.factory.close()
	end,
	-- Studio D2 / p134 v60: an empty-handed player's swings were refused WEAPON_UNAVAILABLE and
	-- nothing showed. Bare hands punch (Durango): small hits that land, no item, no wear.
	["an empty-handed player punches a dodo for low damage on the real command path"] = function()
		local live = server()
		local phone = client(live)
		local dodo = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 3, 3, dodo.Z))
		assert(phone.tap(DODO), "engage")
		for _ = 1, 6 do
			phone.tick()
		end
		local lost = FULL - hp(live, DODO)
		assert(lost > 0, "a bare-hand punch landed, health " .. hp(live, DODO))
		for _, entry in phone.results do
			assert(entry.result.reason ~= "WEAPON_UNAVAILABLE", "no weapon refusal for bare hands")
		end
		local punch = live.world.roleWildlife.catalog.unarmed
		local club = live.world.roleWildlife.catalog.weapons["starter-club"]
		assert(punch and punch.damageMilli < club.damageMilli, "a punch hits softer than the starter club")
		assert(swingsAt(phone, DODO) >= 1 and requestsAt(phone, DODO) >= 1, "swings were sent and accepted")
		live.factory.close()
	end,
	-- p134 v50: a fresh player with the bone knife in the bag but nothing in hand. The loop's first
	-- swing is refused WEAPON_UNAVAILABLE and it raises a Backpack tool once; the old code took the
	-- first Tool child, which can be the capture bola, so the retry was refused too and the fight
	-- ended without a hit. It must raise the knife and kill the dodo.
	["an empty-handed player is armed with the bone knife, not the bola, and the dodo dies"] = function()
		local live = server()
		stash(live, "bola-1", "capture-bola", 100000)
		stash(live, "knife-1", "bone-knife", 60000)
		local phone = client(live, {
			{ name = "A bola", itemId = "bola-1", catalogId = "capture-bola" },
			{ name = "B knife", itemId = "knife-1", catalogId = "bone-knife" },
		})
		local dodo = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 15, 3, dodo.Z))
		assert(phone.tap(DODO), "engage")
		fight(phone, live, DODO, 40)
		assert(phone.held() and phone.held().itemId == "knife-1", "the knife was raised")
		assert(hp(live, DODO) == 0, "the dodo died on the server, health " .. hp(live, DODO))
		live.factory.close()
	end,
	-- p134 v50: after the player was downed, the step-back pill stayed up ~10 min over the action
	-- buttons until it was tapped. Old code kept the bar while the target lived, whatever the player.
	["the combat bar clears when the player is downed mid-fight"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local dodo = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 3, 3, dodo.Z))
		assert(phone.tap(DODO), "engage")
		phone.tick()
		assert(phone.bar(), "the bar shows while fighting")
		assert(hp(live, DODO) > 0, "the target is still alive")
		phone.humanoid.Health = 0
		phone.tick()
		assert(not phone.bar(), "downed: the target bar and step-back pill are gone")
		phone.humanoid.Health = 100
		for _ = 1, 3 do
			phone.tick()
		end
		assert(not phone.bar(), "it does not come back after the respawn")
		live.factory.close()
	end,
	-- R09 (D2c): a fresh profile could not tame anything (melee_2 + survival_3 + club + rope, all far
	-- past the opening). Robango redesign: a small basic creature is weakened with the opening knife,
	-- stands winded at a quarter health, and the guide's starter bola captures it at level 1.
	["a level 1 player weakens a dodo with the knife, the loop holds, and the starter bola captures it"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		rewardBola(live)
		local phone = client(live)
		local dodo = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 15, 3, dodo.Z))
		-- The PetRing hook: downed (<= 25%) tameable creature and a capture tool in the bag.
		local spared = 0
		phone.hud.setSpare(function(model: any): boolean
			local health = model:GetAttribute("ForgeWildlifeHealthMilli")
			local yes = type(health) == "number" and health > 0 and health <= FULL // 4
			spared += if yes then 1 else 0
			return yes
		end)
		assert(phone.tap(DODO), "engage")
		fight(phone, live, DODO, 40)
		local health = hp(live, DODO)
		assert(health > 0 and health <= FULL // 4, "the loop held at the capture threshold, health " .. health)
		assert(spared >= 1, "the spare hook was asked")
		-- (The winded stand-still is Wildlife.step's rule: Wildlife.spec; this harness runs no behavior.)
		for _ = 1, 5 do
			phone.tick()
		end
		assert(hp(live, DODO) == health, "no more swings while held")
		-- PetRing.spare reads this count: the starter bola is a capture tool in the published snapshot.
		local function tools(): any
			return live.session.snapshot(ACTOR).survivalExtensions.taming.captureTools
		end
		assert(tools() == 1, "the snapshot counts the bola as a capture tool: " .. tostring(tools()))
		-- Capture: PetRing sends tame-hit then tame-capture with the bola; no skills, no club, no rope.
		local hit = command(live, "survival-coop:tame-hit", { DODO })
		assert(hit.ok, "stun: " .. tostring(hit.reason))
		local caught = command(live, "survival-coop:tame-capture", { DODO })
		assert(caught.ok, "capture: " .. tostring(caught.reason))
		local bag = live.session.snapshot(ACTOR)["survival-coop"].inventory.bag.items
		local bola = bag["guide:rw.g02.first-axe:2:1"]
		assert(bola and bola.durabilityMilli == 75000, "the bola wore one throw, not consumed")
		local pets = companions(live).pets
		if caught.data.captured then
			assert(pets[DODO] and pets[DODO].phase == "Captured", "the dodo is mine")
			local wild = live.factory.services.survivalWildlife.snapshot(ACTOR)[DODO]
			assert(wild.captureId ~= nil and wild.capturedUntil > live.at.value * 1000, "out of the world")
			-- The first-capture guide step counts the real capture and pays its feed.
			local development = live.factory.expeditionStore.snapshot(ACTOR).development
			assert(development.definitions["rw.g31.first-capture"], "first-capture guide completed")
			local feed = 0
			for _, item in live.session.snapshot(ACTOR)["survival-coop"].inventory.bag.items do
				feed += if item.catalogId == "herbivore-feed" then item.quantity else 0
			end
			assert(feed == 3, "the guide paid 3 feed, got " .. feed)
			-- Pen, three feeds, five minutes, claim, deploy: the dodo is out with the player.
			for _, verb in { "place", "train", "feed", "feed", "feed" } do
				local r = command(live, "survival-coop:companion-action", { verb, DODO })
				assert(r.ok, verb .. ": " .. tostring(r.reason))
				live.at.value += 1
			end
			for _ = 1, 31 do
				live.at.value += 10
				live.session.advance(live.clock.now())
			end
			for _, verb in { "claim", "deploy" } do
				local r = command(live, "survival-coop:companion-action", { verb, DODO })
				assert(r.ok, verb .. ": " .. tostring(r.reason))
			end
			local pet = companions(live).pets[DODO]
			assert(pet.phase == "Deployed", "summoned: " .. pet.phase)
		else
			assert(pets[DODO] == nil, "an escape leaves no pet")
		end
		live.factory.close()
	end,
	["the starter bola refuses a healthy dodo and anything bigger still needs the skilled path"] = function()
		local live = server()
		rewardBola(live)
		local dodo = live.factory.services.survivalWildlife.snapshot(ACTOR)[DODO].home
		live.engine.move(ACTOR, { x = dodo.x + 2, y = dodo.y, z = dodo.z })
		local full = command(live, "survival-coop:tame-hit", { DODO })
		assert(not full.ok and full.reason == "WEAKEN_FIRST", "a whole dodo: " .. tostring(full.reason))
		local bigger = nil
		for id, npc in live.factory.services.survivalWildlife.snapshot(ACTOR) do
			for _, row in Content.wildlifeDetails do
				if row.id == npc.catalogId and row.captureClass ~= "never" and row.health > 60 then
					bigger = bigger or id
				end
			end
		end
		assert(bigger, "an onboarding creature bigger than the starter tier")
		local home = live.factory.services.survivalWildlife.snapshot(ACTOR)[bigger].home
		live.engine.move(ACTOR, { x = home.x + 2, y = home.y, z = home.z })
		local refused = command(live, "survival-coop:tame-hit", { bigger })
		assert(not refused.ok and refused.reason == "SUBDUE_GATED", "bigger: " .. tostring(refused.reason))
		live.factory.close()
	end,
	["the combat bar clears when the player walks away from a paused fight"] = function()
		local live = server()
		hold(live, "bone-knife", 60000)
		local phone = client(live)
		local dodo = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 3, 3, dodo.Z))
		assert(phone.tap(DODO), "engage")
		phone.tick()
		assert(phone.bar(), "engaged")
		phone.pause() -- a ground tap: the player walks off on purpose
		phone.place(roblox.Vector3.new(dodo.X + 20, 3, dodo.Z))
		phone.tick()
		assert(phone.bar(), "still near: the bar stays so the fight can resume")
		phone.place(roblox.Vector3.new(dodo.X + 120, 3, dodo.Z))
		phone.tick()
		assert(not phone.bar(), "out of range: the bar is gone and the action buttons are back")
		live.factory.close()
	end,
}
