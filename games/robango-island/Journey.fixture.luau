--!strict
-- Journey fixture (journey6h.spec): a fresh actor's first hours on the real server wiring, with
-- every next action read from what the real client shows. One Engine hosts the role worlds; each
-- travel closes the role's factory/session and opens the destination's on the same durable
-- backend (the live teleport). The client is the shipped panel section of RobangoIslandClient
-- (PanelHarness, realHud) fed the real Session packets, with ForgeAction bridged to the Session.
-- Time is an explicit clock (`at.value` seconds); nothing reads the wall clock.
local serde = require("@lune/serde")
local task = require("@lune/task")
local roblox: any = require("@lune/roblox")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local SourceConfig = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local Clock = require("../../core/infra/genre/Clock")
local Durable = require("./src/shared/GenreDurable")
local Harness = require("./PanelHarness.fixture")

local M = {}
M.ACTOR = "11734795308"
M.SEED = 1776
M.WALK = 16 -- RoleWorld baseWalkSpeed, studs per second

local function encode(value: any): string
	return serde.encode("json", value)
end

-- A fresh multi-role server host on one durable backend.
function M.new(options: any?): any
	local opts = options or {}
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
	forge.core.domain.island.Topology = require("../../core/domain/island/Topology")
	forge.core.infra = {
		render = forge.core.infra.render,
		genre = { Clock = Clock, Session = Session },
		data = {
			ActorDocumentStore = require("../../core/infra/data/ActorDocumentStore"),
			ClanStoreWallet = require("../../core/infra/data/ClanStoreWallet"),
			CrossServerMarketPersonal = require("../../core/infra/data/CrossServerMarketPersonal"),
		},
	}
	forge.games["robango-island"].src.shared.MarketPorts = require("./src/shared/MarketPorts")
	forge.games["robango-island"].src.shared.TownRuntime = require("./src/shared/TownRuntime")
	forge.core.infra.data.FencedStore = require("../../core/infra/data/FencedStore")
	module.CrossServerMarketExtension = require("../../genres/survival-coop/module/CrossServerMarketExtension")
	module.MarketExtension = require("../../genres/survival-coop/module/MarketExtension")
	local factoryBuilder = engine.load("games/robango-island/src/server/SurvivalFactory.luau", {}, {
		Parent = {
			LateEquipmentPorts = require("./src/server/LateEquipmentPorts"),
			WorldDressing = engine.dressing,
		},
	})
	local provisionBuilder = engine.load("games/robango-island/src/server/SurvivalProvision.luau", {}, nil)
	local at = { value = 1000 }
	local clock = Clock.new(function()
		return at.value
	end)
	local function now(): number
		return math.floor(at.value)
	end
	local backend = Memory.new()
	local source: any = table.clone(SourceConfig)
	source.seed, source.renderRole = M.SEED, engine.role.build
	local host: any = { engine = engine, at = at, clock = clock, backend = backend, source = source }
	local sequence, requestSerial = 0, 0
	host.travels = {} :: { any }
	host.STRANDED = "journey: stranded (leave refused)"
	host.stranded = nil :: any
	host.pendingTravel = nil :: any

	local function personal(actor: string): any
		local port = host.session and host.session.personalTransfer(actor)
		return if port then port.profile().data.envelope.genres["survival-coop"].data else nil
	end
	host.personal = personal
	do
		local records: { [string]: any } = {}
		local dataStore = {
			UpdateAsync = function(_, key, transform)
				local value = transform(records[key])
				if value ~= nil then
					records[key] = value
				end
				return value
			end,
			GetAsync = function(_, key)
				return records[key]
			end,
			ListKeysAsync = function()
				return {
					GetCurrentPage = function()
						return {}
					end,
					IsFinished = true,
				}
			end,
		}
		local memoryStore = {
			GetSortedMap = function()
				return {
					SetAsync = function() end,
					RemoveAsync = function() end,
					GetRangeAsync = function()
						return {}
					end,
				}
			end,
		}
		host.marketStore = require("../../core/infra/data/CrossServerMarketStore").new(dataStore, memoryStore, true)
		local contracts = function(actor: string): any
			if not host.factory then
				return nil
			end
			for _, extension in host.factory.services.survivalExtensions do
				if extension.id == "contracts" then
					return extension.snapshot(actor)
				end
			end
			return nil
		end
		host.marketConfig = require("./src/shared/MarketPorts").config({
			personalTransfer = function(actor)
				return if host.session then host.session.personalTransfer(actor) else nil
			end,
			accountAgeDays = function()
				return 30
			end,
			sessionSeconds = function()
				return 0
			end,
			playedSeconds = function(actor)
				local data = personal(actor)
				local vitals = data and data.vitals
				return if vitals and type(vitals.activeMillis) == "number" then vitals.activeMillis // 1000 else nil
			end,
			tutorialComplete = function(actor)
				local data = contracts(actor)
				return type(data) == "table" and type(data.tutorial) == "table" and data.tutorial.complete == true
			end,
		})
		require("../../genres/survival-coop/module/MarketExtension").configure(host.marketConfig)
	end

	-- The server's world.travel (RobangoIslandServer liveWorld.travel), with the router replaced by
	-- a recorded handoff the journey performs after the command returns.
	local function bindTravel(world: any, role: string)
		world.travel = function(_player: any, destination: string, route: number?, extra: any?)
			local actor = M.ACTOR
			local Topology = require("../../core/domain/island/Topology")
			if destination == "archipelago" then
				-- RobangoIslandServer: the role edge is checked before archipelago.open.
				if role ~= "archipelago" then
					local level = (personal(actor) or {}).progression and personal(actor).progression.level or 1
					local allowed, refused = Topology.validateRoleTransition(role, destination, level)
					if not allowed then
						return false, refused
					end
				end
				local opened = host.factory.archipelago.open(actor, {
					id = "journey-trip-" .. tostring(at.value), -- server: HttpService:GenerateGUID (unique per open)
					index = route or 1,
					seed = require("./src/shared/SeaChart").departureSeed(clock.now(), actor),
					revision = "robango-route-v1",
					ttl = 1800,
					entryBuffer = source.archipelago.entryBufferSeconds,
					party = extra and extra.party,
					departure = extra and extra.departure,
				})
				if not opened.ok and opened.reason ~= "expedition_active" then
					return false, opened.reason
				end
			elseif destination == "next-island" then
				local advanced = host.factory.archipelago.nextIsland(actor)
				if not advanced.ok then
					return false, advanced.reason
				end
				local document = host.factory.expeditionStore.snapshot(actor)
				destination = if document.archipelago.status == "complete" then "home" else "archipelago"
			elseif destination == "home" and role == "archipelago" then
				-- RobangoIslandServer returns the settle result; the voyage home (provision.returnHome)
				-- leaves after the command returns.
				return host.factory.archipelago.recover(actor, "return")
			end
			if destination ~= "next-island" then
				-- IslandBootstrap.travel: the role edge and level gate, then the expedition admission.
				local level = (personal(actor) or {}).progression and personal(actor).progression.level or 1
				local ok, reason = Topology.validateRoleTransition(role, destination, level)
				if not ok then
					return false, reason
				end
				if destination == "archipelago" then
					ok, reason = host.factory.admitExpedition(actor)
					if not ok then
						return false, reason
					end
				end
			end
			host.pendingTravel = { from = role, to = destination, at = at.value }
			return true, nil
		end
	end

	local function close()
		if not host.factory then
			return
		end
		for _, member in host.session.members() do
			local left = host.session.close(member)
			if not left.ok then
				-- IslandBootstrap.travel's prepareHandoff refuses the same way: the teleport never
				-- starts and the player stays on this island. The journey ends here (host.stranded).
				host.session.resumeHandoff(member)
				host.stranded = { at = at.value, reason = left.reason, layout = host.layoutId }
				error(host.STRANDED)
			end
		end
		local closed = host.factory.close()
		assert(closed.ok, "factory close: " .. tostring(closed.reason or closed.error))
		if host.world and host.world.destroy then
			local ok, err = pcall(host.world.destroy)
			assert(ok, "world destroy: " .. tostring(err))
		end
		engine.compact()
		host.factory, host.session, host.world = nil, nil, nil
	end
	host.close = close

	--- Opens role `role` (layout id, "home" or "archipelago") and joins the actor at `spawn`.
	function host.enter(role: string, spawn: any?): any
		-- IslandBootstrap: an archipelago server renders the persisted expedition (templateId, stage, seed).
		if role == "archipelago" and host.factory then
			local document = host.factory.expeditionStore.snapshot(M.ACTOR)
			source.expedition = document and document.archipelago
		end
		close()
		host.dropClient()
		sequence += 1
		local world: any
		local roleName: string
		if role == "home" then
			world = engine.home.live(Content, source, Policy, function()
				return at.value * 1000
			end)
			roleName = "home"
		elseif role == "archipelago" then
			world = engine.archipelago.live(Content, source, Policy, function()
				return at.value * 1000
			end)
			roleName = "archipelago"
		else
			world = engine.role.build(Content, source, Policy, function()
				return at.value * 1000
			end, role, M.SEED)
			roleName = require("./src/shared/SeaChart").roleOf(role)
		end
		world.campMinContributors = 1 -- PlayMode.campMinContributors (solo)
		-- RobangoIslandServer:166-191,221,302: the market account facts and the durable trade store
		-- (an in-memory DataStore / MemoryStore here; the escrow and buyback logic are the real ones).
		world.marketAccount = host.marketConfig.account
		world.marketStore = host.marketStore
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
				return roleName == "home" or roleName == "harbor"
			end,
			flares = false,
			camp = function(actor: string)
				local p = world.nearestStation and world.nearestStation(actor, { "campfire", "fireplace" })
				return if p then { x = p.X, y = p.Y, z = p.Z } else nil
			end,
			name = function(actor: string): string
				return "P" .. actor
			end,
		}
		engine.game:GetService("Workspace"):SetAttribute("ForgeWorldRole", roleName)
		bindTravel(world, roleName)
		local provision = provisionBuilder(
			{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
			source.tribe.config.tribeId,
			{ studio = false, server = "journey-" .. sequence }
		)
		-- RobangoIslandServer provision.returnHome: the router home (role edge, then the handoff).
		provision.returnHome = function(actor: string)
			local Topology = require("../../core/domain/island/Topology")
			local level = (personal(actor) or {}).progression and personal(actor).progression.level or 1
			local ok, reason = Topology.validateRoleTransition(roleName, "home", level)
			if not ok then
				return { ok = false, reason = reason }
			end
			local ready = host.session.prepareHandoff(actor)
			if not ready.ok then
				return { ok = false, reason = ready.reason }
			end
			host.session.resumeHandoff(actor)
			host.pendingTravel = { from = roleName, to = "home", at = at.value }
			return { ok = true }
		end
		local factoryOptions: any = {
			sessionId = "journey-" .. sequence,
			leaseSeconds = 120,
			now = now,
			budget = { encode = encode },
		}
		local factory: any =
			assert(factoryBuilder(Content, source, world, backend, clock, factoryOptions, provision, Policy))
		local services = table.clone(factory.services)
		services.now = clock.now
		services.roll = function()
			return 0
		end
		services.emit = function() end
		services.encode = encode
		local session = Session.new(
			{
				packConfig = require("./src/shared/GenreConfig"),
				contracts = { require("../../genres/survival-coop/module/Contract") },
				durable = Durable,
				controls = {},
				storeName = "journey-personal",
			},
			backend,
			{ sessionId = factoryOptions.sessionId, lockTimeout = 120, retries = 0, now = now },
			services,
			Durable
		)
		factory.bind(session)
		host.world, host.factory, host.session, host.role, host.layoutId =
			world, factory, session, roleName, world.layout and world.layout.id or role
		engine.move(M.ACTOR, spawn or Content.homePolicy.dock)
		-- A teleport lands a new Player: no attribute from the previous place carries over.
		local landed = engine.game:GetService("Players"):GetPlayerByUserId(tonumber(M.ACTOR))
		for _, key in { "ForgeTravelResult", "ForgeOpeningRefusal" } do
			landed.attributes[key] = nil
		end
		-- The fixture Humanoid lacks HealthChanged, which the C6 down hold connects to (OnboardingFood).
		local character = engine.game:GetService("Players"):GetPlayerByUserId(tonumber(M.ACTOR)).Character
		character:FindFirstChildOfClass("Humanoid").HealthChanged = character.AttributeChanged
		local joined = session.join(M.ACTOR)
		assert(joined.ok, "join " .. role .. ": " .. tostring(joined.reason))
		-- The title's Start (TitleFlow.bindWake).
		session.dispatch(M.ACTOR, "survival-coop:vitals-wake", {})
		if world.opening then
			host.bindOpening(world)
		end
		return world
	end

	-- RobangoIslandServer's opening ports (C1), on the live session reads.
	function host.bindOpening(world: any)
		local contracts: any = nil
		for _, extension in host.factory.services.survivalExtensions do
			contracts = if extension.id == "contracts" then extension else contracts
		end
		world.opening.bind({
			tutorial = function(actor)
				local view = contracts.snapshot(actor)
				local tutorial = if type(view) == "table" then view.tutorial else nil
				return if type(tutorial) == "table" then tutorial.index else nil,
					type(tutorial) == "table" and tutorial.complete == true
			end,
			items = function(actor): { [string]: number }?
				local state = personal(actor)
				if not state then
					return nil
				end
				local totals: { [string]: number } = {}
				for _, item: any in state.inventory.bag.items do
					totals[item.catalogId] = (totals[item.catalogId] or 0) + item.quantity
				end
				return totals
			end,
			dodgeAt = function(actor)
				local state = personal(actor)
				local defense = state and state.combat and state.combat.defense
				return if defense then defense.dodgeStart else nil
			end,
			position = function(actor)
				return world.rootPosition(actor)
			end,
			near = function(actor, part)
				return world.nearPart(actor, part)
			end,
			store = host.factory.expeditionStore,
			analytics = function(_actor, step)
				host.onOpeningStep(step)
			end,
			travel = function(_actor)
				return world.travel(nil, "home")
			end,
			spawn = function(fn)
				fn()
			end,
		})
	end
	host.onOpeningStep = function(_step: string) end

	--- One server tick: advance the session, the world heartbeat and the opening director. Deferred
	--- server work (travelAfterCommand's task.defer) runs on the Lune scheduler: yield once.
	host.cost = { tick = 0, ticks = 0, render = 0, renders = 0, command = 0, commands = 0 }
	function host.tick(seconds: number?)
		local started = os.clock()
		at.value += seconds or 1
		host.session.advance(clock.now())
		local beat = os.clock()
		host.cost.advance = (host.cost.advance or 0) + (beat - started)
		engine.game:GetService("RunService").Heartbeat:Fire(seconds or 1)
		host.cost.heartbeat = (host.cost.heartbeat or 0) + (os.clock() - beat)
		if host.world.opening then
			host.world.opening.tick({ M.ACTOR }, at.value * 1000)
		end
		task.wait()
		host.cost.tick += os.clock() - started
		host.cost.ticks += 1
	end

	--- A durable command exactly as the client transport sends it (new request id each call).
	function host.command(action: string, args: { any }): any
		requestSerial += 1
		at.value += 1
		host.session.advance(clock.now())
		local name = if string.sub(action, 1, 13) == "survival-coop" then action else "survival-coop:" .. action
		local request = {
			requestId = "journey-" .. requestSerial,
			sessionEpoch = host.session.commandEpoch(M.ACTOR, name),
			action = name,
			args = args,
		}
		local result = host.session.command(M.ACTOR, request)
		for _ = 1, 4 do
			if result.ok or type(result.data) ~= "table" or result.data.status ~= "pending" then
				break
			end
			host.session.recoverTransfers(M.ACTOR, 16)
			result = host.session.command(M.ACTOR, request)
		end
		return result
	end

	--- The packet RobangoIslandServer pushes (Server.packetFor).
	function host.packet(): any
		local session = host.session
		local epochs: { [string]: number? } = {}
		for _, actionId in Durable.actions do
			epochs[actionId] = session.commandEpoch(M.ACTOR, actionId)
		end
		return {
			snapshots = session.snapshot(M.ACTOR),
			roster = { { id = M.ACTOR, name = "Journey" } },
			revision = at.value,
			durable = { actions = Durable.actions, sessionEpoch = session.commandEpoch(M.ACTOR), epochs = epochs },
		}
	end

	-- The client: the shipped panel section with the real SurvivalHUD; ForgeAction -> this Session.
	local client: any = nil
	-- task.delay work the client queued (hand-craft chain, toasts): run on the sim clock by host.pump.
	host.delayed = {} :: { any }
	--- A teleport is a fresh client: the next host.client() builds a new one for the new place.
	function host.dropClient()
		if client then
			pcall(function()
				client.h.panels.destroy()
			end)
		end
		client = nil
		table.clear(host.delayed)
	end
	--- Runs queued client delays that are due by the sim clock (each re-queued call gets its own due).
	function host.pump()
		for _ = 1, 8 do
			local due = {}
			local kept = {}
			for _, entry in host.delayed do
				entry.due = entry.due or (at.value + entry.seconds)
				if entry.due <= at.value then
					table.insert(due, entry)
				else
					table.insert(kept, entry)
				end
			end
			if #due == 0 then
				return
			end
			table.clear(host.delayed)
			for _, entry in kept do
				table.insert(host.delayed, entry)
			end
			for _, entry in due do
				local ok, err = pcall(entry.fn, table.unpack(entry.args, 1, entry.args.n))
				if not ok and client then
					table.insert(client.h.errors, tostring(err))
				end
			end
		end
	end
	local function invoke(remote: any, verb: any, payload: any): any
		if remote and remote.Name == "ForgeOpeningIntent" then
			if not host.world.opening then
				return false, "UNAVAILABLE"
			end
			return host.world.opening.intent(M.ACTOR, verb)
		end
		if verb == nil then
			return { ok = true, durable = host.packet().durable }
		end
		if verb == "command" then
			at.value += 1
			host.session.advance(clock.now())
			local result = host.session.command(M.ACTOR, payload)
			if host.onCommand then
				host.onCommand(payload, result)
			end
			if result.ok and client then
				client.dirty = true
			end
			return result
		end
		return host.session.dispatch(M.ACTOR, verb, payload)
	end
	host.onCommand = nil :: ((any, any) -> ())?
	function host.client(): any
		if client then
			return client
		end
		-- RobangoIslandClient: the onboarding camp grid starts at ForgeCampOrigin and builds pay from
		-- the bag there (bagBuild); elsewhere the grid is the tribe origin.
		local origin = source.tribe.origin
		local folder = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
		local camp = folder and folder:GetAttribute("ForgeCampOrigin")
		local onboarding = host.layoutId == "rw.onboarding"
		local h = Harness.harness({
			width = opts.width or 800,
			height = opts.height or 360,
			realHud = true,
			locale = opts.locale or "ko-kr",
			invoke = invoke,
			delayed = host.delayed,
			serverNow = function()
				return at.value
			end,
			clock = function()
				return at.value
			end,
			bagBuild = onboarding,
			userId = tonumber(M.ACTOR),
			guidPrefix = "guid-" .. sequence .. "-",
			tagged = function(tag: string): { any }
				local out = {}
				if tag == "ForgeSurvivalStation" and client and client.stations then
					for _, mirror in client.stations do
						table.insert(out, mirror)
					end
				end
				return out
			end,
			solo = true,
			settlementOrigin = if onboarding and camp
				then roblox.Vector3.new(camp.X, camp.Y, camp.Z)
				else roblox.Vector3.new(origin.x, origin.y, origin.z),
		})
		local storage = h.game:GetService("ReplicatedStorage")
		h.workspace.CurrentCamera.CFrame = roblox.CFrame.new(0, 40, 40)
		local intent = h.new("RemoteFunction", "ForgeOpeningIntent")
		intent.Parent = storage
		client = { h = h, dirty = true }
		return client
	end
	--- Pushes the current packet to the client and mirrors the world facts it reads.
	function host.render()
		local started = os.clock()
		local c = host.client()
		local h = c.h
		local root = host.world.rootPosition(M.ACTOR)
		local character = h.player.Character
		if not character then
			character = h.new("Model", "Character")
			local part = h.new("Part", "HumanoidRootPart")
			part.Parent = character
			character.Parent = h.workspace
			h.player.Character = character
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if root then
			hrp.Position = roblox.Vector3.new(root.X, root.Y, root.Z)
			hrp.CFrame = roblox.CFrame.new(hrp.Position)
		end
		local folder = h.workspace:FindFirstChild("ForgeRoleWorld")
		if not folder then
			folder = h.new("Folder", "ForgeRoleWorld")
			folder.Parent = h.workspace
		end
		-- Replication: the server's tagged station parts (SurvivalWorld stations) as client parts,
		-- so SurvivalHUD nearest(kind) sees the workbench the player stands at.
		c.stations = c.stations or {}
		local tags = engine.game:GetService("CollectionService")
		for _, part in tags:GetTagged("ForgeSurvivalStation") do
			local mirror = c.stations[part]
			if not mirror then
				mirror = h.new("Part", "Station")
				mirror.Parent = folder
				c.stations[part] = mirror
			end
			local p, size = part.Position, part.Size
			mirror.Position = roblox.Vector3.new(p.X, p.Y, p.Z)
			mirror.CFrame = roblox.CFrame.new(mirror.Position)
			mirror.Size = if size then roblox.Vector3.new(size.X, size.Y, size.Z) else roblox.Vector3.new(4, 4, 4)
			mirror.Transparency = part.Transparency or 0
			mirror:SetAttribute("ForgeStationKind", part:GetAttribute("ForgeStationKind"))
			mirror:SetAttribute("ForgeStationId", part:GetAttribute("ForgeStationId"))
		end
		folder:SetAttribute("ForgeLayoutId", host.layoutId)
		h.workspace:SetAttribute("ForgeWorldRole", host.role)
		local player = engine.game:GetService("Players"):GetPlayerByUserId(tonumber(M.ACTOR))
		for _, key in { "ForgeTravelResult", "ForgeOpeningRefusal" } do
			h.player:SetAttribute(key, player and player:GetAttribute(key))
		end
		local packetAt = os.clock()
		local packet = host.packet()
		local pushAt = os.clock()
		h.packet(packet)
		host.cost.snapshot = (host.cost.snapshot or 0) + (pushAt - packetAt)
		host.cost.push = (host.cost.push or 0) + (os.clock() - pushAt)
		c.dirty = false
		host.cost.render += os.clock() - started
		host.cost.renders += 1
		return h
	end
	return host
end

return M
