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
	local player = {
		Character = character,
		UserId = tonumber(ACTOR),
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
	local services: { [string]: any } = {
		Players = { LocalPlayer = player },
		RunService = { Heartbeat = signal(beats) },
		Workspace = {
			FindFirstChild = function(_, name)
				return if name == "ForgeWildlife" then folder else nil
			end,
			CurrentCamera = {
				WorldToViewportPoint = function()
					return roblox.Vector3.new(400, 200, 0), true
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
	local hud = Hud.start({
		content = Content,
		locale = "en-us",
		send = function(verb, args)
			return send(verb, args)
		end,
		-- The walk: arrive half a stud inside `within` (flat) of the goal, on the server too.
		approach = function(goal: any, within: number, arrive: () -> ())
			approaches += 1
			local flat = roblox.Vector3.new(root.Position.X - goal.X, 0, root.Position.Z - goal.Z)
			local away = if flat.Magnitude > 0 then flat.Unit else roblox.Vector3.new(1, 0, 0)
			local offset = away * (within - 0.5)
			place(roblox.Vector3.new(goal.X + offset.X, 3, goal.Z + offset.Z))
			arrive()
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
		tap = function(id: string): boolean
			return tap.handlers.creature(models[id]) ~= false
		end,
		-- One second: the server ticks (windups resolve), the world republishes, one HUD frame runs.
		tick = function()
			live.at.value += 1
			t.value += 1
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
	["an unarmed swing says why instead of failing silently"] = function()
		local live = server()
		local phone = client(live)
		local dodo = phone.models[DODO].HumanoidRootPart.Position
		phone.place(roblox.Vector3.new(dodo.X + 3, 3, dodo.Z))
		assert(phone.tap(DODO), "engage")
		for _ = 1, 4 do
			phone.tick()
		end
		local line = Combat.text("en-us", "attack.WEAPON_UNAVAILABLE")
		assert(line ~= "attack.WEAPON_UNAVAILABLE", "the refusal has pack copy")
		assert(table.find(phone.floats(), line), "the refusal shows over the target")
		assert(requestsAt(phone, DODO) == 1, "a final refusal stops the loop")
		assert(hp(live, DODO) == FULL, "no damage without a weapon")
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
