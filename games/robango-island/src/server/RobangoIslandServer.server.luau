--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local Shared = Forge.games["robango-island"].src.shared
local Server = require(Forge.core.infra.genre.Server)
local RuntimeBackend = require(Forge.core.infra.data.RuntimeBackend)
local RuntimeServices = require(Forge.core.infra.data.RuntimeServices)
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local IslandBootstrap = require(Forge.genres["survival-coop"].module.IslandBootstrap)
local Topology = require(Forge.core.domain.island.Topology)
local SeaChart = require(Shared.SeaChart)
local ServerStorage = game:GetService("ServerStorage")
local roleConfig = ServerStorage:FindFirstChild("ForgePlaceRoles")
local roles = if roleConfig and roleConfig:IsA("StringValue") then HttpService:JSONDecode(roleConfig.Value) else nil
local roleEnv = {
	roles = roles,
	placeId = game.PlaceId,
	privateServerId = game.PrivateServerId,
	isStudio = RunService:IsStudio(),
	studioRole = if RunService:IsStudio() then workspace:GetAttribute("ForgeStudioRole") or "onboarding" else nil,
}
local worldRole, routingOnly = IslandBootstrap.select(roleEnv)
workspace:SetAttribute("ForgeWorldRole", worldRole)
workspace:SetAttribute("ForgeTravelMode", if RunService:IsStudio() then "studio-single" else "live")
local Clock = require(Forge.core.infra.genre.Clock)
local clock = Clock.new(function()
	return DateTime.now().UnixTimestampMillis / 1000
end)
local persistenceConfig = require(script.Parent.PersistenceConfig)
local runtimeServices = RuntimeServices.new(persistenceConfig)
local backend = RuntimeBackend.new(persistenceConfig, "SurvivalShared")
local homeReservations = require(Forge.core.infra.island.HomeReservation).new(
	backend,
	{
		sessionId = "home-route:" .. HttpService:GenerateGUID(false),
		leaseSeconds = 120,
		now = function()
			return math.floor(clock.now())
		end,
		budget = {
			encode = function(value)
				return HttpService:JSONEncode(value)
			end,
		},
	},
	if roles then roles.home or 0 else 0,
	function(placeId)
		return game:GetService("TeleportService"):ReserveServerAsync(placeId)
	end
)
if routingOnly then
	-- This server is not an island host. It must never construct SurvivalFactory
	-- or Server.start (which would claim gameplay leases for routing arrivals).
	local function route(player: Player)
		local reservation, reason = homeReservations.resolve(tostring(player.UserId))
		if not reservation then
			warn("HOME_ROUTE:" .. tostring(reason))
			return
		end
		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = reservation.accessCode
		local ok, err = pcall(function()
			game:GetService("TeleportService"):TeleportAsync(reservation.placeId, { player }, options)
		end)
		if not ok then
			warn("HOME_ROUTE:" .. tostring(err))
		end
	end
	local players = game:GetService("Players")
	players.PlayerAdded:Connect(route)
	for _, player in players:GetPlayers() do
		task.spawn(route, player)
	end
	return
end
local content = require(Shared.SurvivalContent)
local source: any = table.clone(require(Shared.SurvivalWorldConfig))
local wildlifePolicy = require(Shared.WildlifePolicy)
-- B1a/D1: each role world loads only its own biome kits (RoleWorld.build -> BiomeKits.load); a
-- server-start preload of all nine kits competed with the role's loads for the first interaction.
if RunService:IsStudio() and workspace:GetAttribute("ForgeStudioLayout") then
	source.expedition = {
		status = "active",
		templateId = workspace:GetAttribute("ForgeStudioTemplate"),
		stage = workspace:GetAttribute("ForgeStudioStage"),
		seed = source.seed or 1776,
	}
end
-- Taming/mounts: the pack only supplies the policy; the extension registry builds the system.
require(Forge.genres["survival-coop"].module.TamingExtension).configure(require(Shared.TamingConfig))
local Players = game:GetService("Players")
-- Shop: ProcessReceipt is installed once, by MarketplacePort.onReceipt in SurvivalFactory.
local MarketplacePort = require(Forge.core.infra.monetization.MarketplacePort)
local PolicyPort = require(Forge.core.infra.monetization.PolicyPort)
local entitlementFactory: any = nil
local Cosmetics = require(Shared.CosmeticConfig)
local CosmeticVisual = require(Forge.genres["survival-coop"].module.CosmeticVisual)
-- `forge deploy` injects the target environment's product ids (deploy.yml monetization); the
-- catalog's own ids are the staging defaults. An id deploy left at 0 is listed, never prompted.
local monetizationIds = ServerStorage:FindFirstChild("ForgeMonetizationIds")
local catalog = require(Shared.MonetizationIds).apply(
	require(Shared.MonetizationCatalog),
	if monetizationIds and monetizationIds:IsA("StringValue")
		then HttpService:JSONDecode(monetizationIds.Value)
		else nil
)
require(Forge.genres["survival-coop"].module.MonetizationExtension).configure({
	catalog = catalog :: any,
	marketplace = MarketplacePort.roblox(game:GetService("MarketplaceService"), Players, Enum.ProductPurchaseDecision),
	policy = PolicyPort.roblox(game:GetService("PolicyService"), Players),
	hooks = {
		warehouseSlots = function(actor)
			task.defer(function()
				if entitlementFactory then
					entitlementFactory.refreshWarehouse(actor)
				end
			end)
		end,
		-- Every sold cosmetic renders (CosmeticConfig): mount skins on the ride, worn sets on the rider.
		skinSupported = function(skin)
			return CosmeticVisual.supported(Cosmetics, skin)
		end,
		skinSlot = function(skin)
			return CosmeticVisual.slot(Cosmetics, skin)
		end,
	},
})
-- Market: the pack supplies tradeable goods and Players eligibility facts; the genre extension
-- owns the durable escrow and the Coins settlement over the live session (see MarketPorts).
local tutorialSource: any = nil
local joinedAt: { [string]: number } = {}
local liveSession: any = nil
-- The provisioning policy is guarded by the environment: `studio` is true only for a local Studio
-- place with no published experience id, so a published server can never select the permissive path.
-- `server` scopes the per-server camp: a reserved island server keeps its camp across restarts,
-- any other instance (and a Studio play session, whose JobId is empty) gets its own.
local ownedPersistence = game:GetService("ServerStorage"):FindFirstChild("ForgeOwnedPersistenceConfig")
local ownedNamespace = if ownedPersistence then ownedPersistence:GetAttribute("Namespace") else nil
local provision = require(script.Parent.SurvivalProvision)(
	require(script.Parent.SurvivalProvisionConfig),
	source.tribe.config.tribeId,
	{
		studio = RunService:IsStudio() and game.PlaceId == 0,
		server = if game.PrivateServerId ~= ""
			then "private:" .. game.PrivateServerId
			elseif game.JobId ~= "" then "job:" .. game.JobId
			elseif type(ownedNamespace) == "string" and ownedNamespace ~= "" then "owned:" .. ownedNamespace
			else "local:" .. HttpService:GenerateGUID(false),
	}
)
local function trackJoin(player: Player)
	joinedAt[tostring(player.UserId)] = math.floor(clock.now())
end
Players.PlayerAdded:Connect(trackJoin)
for _, player in Players:GetPlayers() do
	trackJoin(player)
end
Players.PlayerRemoving:Connect(function(player)
	joinedAt[tostring(player.UserId)] = nil
end)
local marketConfig = require(Shared.MarketPorts).config({
	accountAgeDays = function(actor)
		local userId = tonumber(actor)
		local player = if userId then Players:GetPlayerByUserId(userId) else nil
		return if player then player.AccountAge else nil
	end,
	sessionSeconds = function(actor, now)
		local since = joinedAt[actor]
		return if since then now - since else nil
	end,
	-- vitals.activeMillis accumulates online time across sessions and is saved with the profile.
	playedSeconds = function(actor)
		local port = if liveSession then liveSession.personalTransfer(actor) else nil
		local data = if port then port.profile().data.envelope.genres["survival-coop"].data else nil
		local vitals = if type(data) == "table" then data.vitals else nil
		return if type(vitals) == "table" and type(vitals.activeMillis) == "number"
			then vitals.activeMillis // 1000
			else nil
	end,
	-- The Contracts extension owns the tutorial; an unavailable snapshot counts as incomplete.
	tutorialComplete = function(actor)
		local data = if tutorialSource then tutorialSource.snapshot(actor) else nil
		return type(data) == "table" and type(data.tutorial) == "table" and data.tutorial.complete == true
	end,
})
require(Forge.genres["survival-coop"].module.MarketExtension).configure(marketConfig)
provision.homeAccessCode = function(actor: string)
	local reservation = homeReservations.resolve(actor)
	return if reservation then reservation.accessCode else nil
end
-- BEGIN persisted role layout selection. TeleportData is never layout authority.
if worldRole == "archipelago" and not RunService:IsStudio() then
	local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
	local actor = tostring(player.UserId)
	local owner = require(Forge.core.infra.data.ActorDocumentStore).new(backend, {
		sessionId = "layout:" .. HttpService:GenerateGUID(false),
		leaseSeconds = 120,
		now = function()
			return math.floor(clock.now())
		end,
		budget = {
			encode = function(value)
				return HttpService:JSONEncode(value)
			end,
		},
	}, "robango-exp-v1")
	local document, reason = owner.snapshot(actor)
	assert(document and document.archipelago, reason or "PERSISTED_EXPEDITION_REQUIRED")
	source.expedition = document.archipelago
	assert(owner.close().ok, "LAYOUT_OWNER_RELEASE_FAILED")
end
-- END persisted role layout selection.
local world = require(script.Parent.SurvivalWorldBootstrap)(content, source, wildlifePolicy, function()
	return Clock.millis(clock.now())
end, worldRole, RunService:IsStudio() and workspace:GetAttribute("ForgeStudioRole") == nil)
world.marketAccount = marketConfig.account
-- D2 F2: no character before the role's ground under the spawn exists (CharacterAutoLoads is off in
-- default.project.json); a void fall returns to the spawn; a death outside the C6 down flow reloads.
require(script.Parent.SpawnGate).start({
	players = Players,
	heartbeat = RunService.Heartbeat,
	spawn = (world :: any).spawnPart,
	ready = (world :: any).spawnReady,
	alive = function(actor: string): boolean
		local vitals = (world :: any).vitals(actor)
		return vitals == nil or vitals.healthMilli > 0
	end,
	delay = function(seconds: number, fn: () -> ())
		task.delay(seconds, fn)
	end,
})
-- Studio QA: ForgeStudioGallery=true lays out every species (walk, then attack) beside the island.
require(script.Parent.StudioSetup).gallery({
	isStudio = RunService:IsStudio(),
	workspace = workspace,
	content = content,
	rig = require(Forge.genres["survival-coop"].module.DinosaurRig),
	-- The preview island (no ForgeStudioRole) reaches z ~84 on dry land: the pad sits just south of
	-- the shore with a causeway back to it. Role worlds keep the pad far outside their islands.
	center = if workspace:GetAttribute("ForgeStudioRole") == nil
		then Vector3.new(0, 0, 200)
		else Vector3.new(0, 0, 900),
	bridge = if workspace:GetAttribute("ForgeStudioRole") == nil then Vector3.new(0, 0, 70) else nil,
	spawn = task.spawn,
	wait = task.wait,
})
-- Friend visits: Player:IsFriendsWith behind the IslandBootstrap-style availability guard.
local visitWorld: any = world
visitWorld.isFriend = require(Forge.core.infra.island.Friends).source({
	players = game:GetService("Players"),
	isStudio = RunService:IsStudio(),
	placeId = game.PlaceId,
	now = function()
		return DateTime.now().UnixTimestampMillis / 1000
	end,
})
world.runtimeServices = runtimeServices
-- C6 death and rescue (opt-in genre RescueExtension): trusted facts for the down panel. Town
-- (harbor) and home are safe roles with one "Get up" card; camp wakes at the nearest camp fire.
world.rescue = {
	position = function(actor: string)
		local at = world.rootPosition(actor)
		return if at then { x = at.X, y = at.Y, z = at.Z } else nil
	end,
	health = function(actor: string): number?
		local vitals = world.vitals(actor)
		return if vitals then vitals.healthMilli else nil
	end,
	safe = function(): boolean
		return worldRole == "home" or worldRole == "harbor"
	end,
	camp = function(actor: string)
		local at = world.nearestStation(actor, { "campfire", "fireplace" })
		return if at then { x = at.X, y = at.Y, z = at.Z } else nil
	end,
	name = function(actor: string): string
		local player = Players:GetPlayerByUserId(tonumber(actor) or 0)
		return if player then player.DisplayName else actor
	end,
}
-- Survivor avatars (A6): the preset model the archipelago extension saves through.
visitWorld.survivor = require(Shared.SurvivorAvatar)
world.musicRepository = require(Forge.genres["survival-coop"].module.ScoreLibraryStore).new({
	dataStoreService = runtimeServices.dataStoreService,
	storeName = source.persistencePrefix .. "-music-v1",
	rules = content.music,
	maxStoreBytes = 3900000,
	encode = function(value)
		return HttpService:JSONEncode(value)
	end,
	spawn = task.spawn,
})
world.marketStore = require(Forge.core.infra.data.CrossServerMarketStore).new(
	runtimeServices.dataStoreService:GetDataStore(source.persistencePrefix .. "-trade-v1"),
	runtimeServices.memoryStoreService,
	Enum.SortDirection.Ascending
)
world.musicDecode = function(text)
	return HttpService:JSONDecode(text)
end
local clanDirectory = require(Forge.core.infra.data.ClanStore).new({
	dataStore = runtimeServices.dataStoreService:GetDataStore(source.persistencePrefix .. "-clans-v1"),
	memoryMap = runtimeServices.memoryStoreService:GetSortedMap("robango-clans-v1"),
	messaging = runtimeServices.messagingService,
	topic = "robango-clans-v1",
	cacheSeconds = 60,
	-- Reads use GetAsync and are reused for 10 s; only mutations run UpdateAsync (p134 v22 D6).
	readSeconds = 10,
	rules = content.clanPolicy,
	maxBytes = 3900000,
	encode = function(value)
		return HttpService:JSONEncode(value)
	end,
	fence = {
		sessionId = "clans:" .. HttpService:GenerateGUID(false),
		leaseSeconds = 120,
		leasedReads = true,
		now = function()
			return math.floor(clock.now())
		end,
	},
})
world.clanDirectory = clanDirectory
local factory, err = require(script.Parent.SurvivalFactory)(content, source, visitWorld, backend, clock, {
	sessionId = game.JobId .. HttpService:GenerateGUID(false),
	leaseSeconds = 120,
	-- Heartbeat identity reads must not become durable writes (131 camp writes in 90 s starved transport).
	suppressIdentityUpdates = true,
	-- Live DataStores take about 1 write per key per 6 s and every UpdateAsync counts, so a
	-- per-heartbeat read-through flooded the queue (p134 v22 D6): serve leased reads locally.
	leasedReads = true,
	-- A player who joins here while a server they left (force-stopped or still closing) holds
	-- their per-actor documents takes those over after 5 s instead of waiting out the 120 s
	-- lease (p134 v40: actions refused for minutes after the HUD appeared). Shared keys (camp,
	-- world sources, clans) never match and keep waiting.
	takeover = require(Forge.core.infra.data.FencedStore).presentActorTakeover({
		now = function()
			return math.floor(DateTime.now().UnixTimestampMillis / 1000)
		end,
		graceSeconds = 5,
		actorOf = function(key)
			local prefix, actor = string.match(key, "^([%w_-]+):(%d+)$")
			local perActor = {
				contracts = true,
				mkt = true,
				mon = true,
				["taming-v1"] = true,
				["robango-exp-v1"] = true,
				home = true,
			}
			return if prefix and perActor[prefix] then actor else nil
		end,
		present = function(actor)
			local userId = tonumber(actor)
			return userId ~= nil and Players:GetPlayerByUserId(userId) ~= nil
		end,
		-- The grace runs once from the player's arrival, not again for each of their documents.
		presentSince = function(actor)
			return joinedAt[actor]
		end,
	}),
	now = function()
		return math.floor(DateTime.now().UnixTimestampMillis / 1000)
	end,
	budget = {
		encode = function(value)
			return HttpService:JSONEncode(value)
		end,
	},
}, provision, wildlifePolicy)
assert(factory, err)
entitlementFactory = factory
-- Every character spawns as its saved game-supplied survivor (worn paid sets dress on top).
visitWorld.survivor.wardrobe({
	players = Players,
	store = (factory :: any).expeditionStore,
	world = visitWorld,
})
for _, extension in (factory.services.survivalExtensions or {}) :: { any } do
	if extension.id == "contracts" then
		tutorialSource = extension
	end
end
local session = Server.start({
	backend = backend,
	clock = clock,
	starterWorld = false,
	lifecycle = { bind = factory.bind, close = factory.close },
	services = factory.services,
	durable = require(Shared.GenreDurable),
	packConfig = require(Shared.GenreConfig),
	spec = require(Shared.GenreSpec),
	contracts = require(Shared.GenreRuntime),
	controls = require(Shared.GenreUI),
	hooks = require(script.Parent.GenreHooks),
	storeName = "robango-island-genre-v1",
})
liveSession = session
if RunService:IsStudio() then -- QA: ForgeQASeedDamaged=<id>
	local I, c =
		require(Forge.core.domain.inventory.Inventory), require(Forge.core.domain.crafting.Job).catalog(content :: any)
	workspace:GetAttributeChangedSignal("ForgeQASeedDamaged"):Connect(function()
		local id = workspace:GetAttribute("ForgeQASeedDamaged")
		for _, p in if id then Players:GetPlayers() else {} do
			session.personalTransaction(tostring(p.UserId), function(raw)
				local inv, item = raw.envelope.genres["survival-coop"].data.inventory, { quantity = 1, attributes = {} }
				local b = I.fromSave(inv.bag, c)
				item.itemId, item.catalogId, item.qualityMilli, item.durabilityMilli = "qa" .. b.version, id, 1000, 1
				inv.bag = I.save((assert(I.add(b, c, item, b.version))))
				return raw
			end)
		end
	end)
end
if RunService:IsStudio() then -- QA: ForgeQASeedProgress="<level>:<rank>[:<guideId>]"
	workspace:GetAttributeChangedSignal("ForgeQASeedProgress"):Connect(function()
		local l, r, id = string.match(tostring(workspace:GetAttribute("ForgeQASeedProgress")), "^(%d+):(%d+):?(.*)$")
		local G, P, at = (content :: any).guides, (content :: any).progressionPolicy.tree, nil
		for i, g in G do
			at = if g.id == id then i else at
		end
		if not l or id ~= "" and not at then
			return
		end
		local g, T = if at then G[at].gates else {}, require(Forge.core.domain.progression.SkillTree)
		local lv = math.min(P.maxLevel, math.max(tonumber(l) :: number, g.characterLevel or 1))
		for _, p in Players:GetPlayers() do
			session.personalTransaction(tostring(p.UserId), function(raw)
				local d = raw.envelope.genres["survival-coop"].data
				local s = d.progression or T.new(content, P)
				d.progression = if s.level < lv then T.level(s, P, lv) else s
				return raw
			end);
			(factory :: any).expeditionStore.transaction(tostring(p.UserId), function(doc)
				local d = doc.development or { points = 0, definitions = {}, instabilityAccess = 1 }
				d.points = math.max(d.points, 100 * math.max(tonumber(r) :: number, g.developmentRank or 0))
				for i = 1, (at or 1) - 1 do
					d.definitions[G[i].id] = true
				end
				doc.development = d
				return { ok = true }
			end)
		end
	end)
end
-- Recover durable listing barriers even when no seller is online. The extension
-- wrapper serializes this worker with market commands and Session fences value.
local tradeRecovery: any = nil
for _, extension in (factory.services.survivalExtensions or {}) :: { any } do
	if extension.id == "market" then
		tradeRecovery = extension
	end
end
local tradeRunning, tradeElapsed = false, 30
local tradeWorker = RunService.Heartbeat:Connect(function(delta)
	tradeElapsed += delta
	if not tradeRecovery or tradeRunning or tradeElapsed < 30 then
		return
	end
	tradeRunning, tradeElapsed = true, 0
	task.spawn(function()
		local ok, failure = pcall(tradeRecovery.recover, "")
		tradeRunning = false
		if not ok then
			warn("TRADE_RECOVERY:" .. tostring(failure))
		end
	end)
end)
script.Destroying:Connect(function()
	tradeWorker:Disconnect()
end)
local function routingFacts(userId, _destination)
	local port = session.personalTransfer(tostring(userId))
	local envelope = if port then port.profile().data.envelope else nil
	local data = envelope and envelope.genres["survival-coop"].data
	local document = (factory :: any).expeditionStore.snapshot(tostring(userId))
	return if data
		then {
			level = if data.progression then data.progression.level else 1,
			expedition = if document then document.archipelago else nil,
			homeAccessCode = if provision.homeAccessCode then provision.homeAccessCode(tostring(userId)) else nil,
		}
		else nil
end
local routing = IslandBootstrap.start({
	roles = roles,
	studioRole = "onboarding",
	prepareHandoff = session.prepareHandoff,
	resumeHandoff = session.resumeHandoff,
	completeHandoff = session.completeHandoff,
	admitExpedition = (factory :: any).admitExpedition,
	facts = routingFacts,
	players = game:GetService("Players"),
	teleportService = game:GetService("TeleportService"),
	memoryStoreService = runtimeServices.memoryStoreService,
	backend = backend,
	placeId = game.PlaceId,
	jobId = game.JobId,
	privateServerId = game.PrivateServerId,
	isStudio = RunService:IsStudio(),
	now = function()
		return math.floor(DateTime.now().UnixTimestampMillis / 1000)
	end,
	log = function(message)
		warn(message)
	end,
	enum = Enum,
	encode = function(value)
		return HttpService:JSONEncode(value)
	end,
	newTeleportOptions = function()
		return Instance.new("TeleportOptions")
	end,
	sleep = function(seconds)
		task.wait(seconds)
	end,
	spawn = function(fn)
		task.spawn(fn)
	end,
	delay = function(seconds, fn)
		task.delay(seconds, fn)
	end,
	every = function(seconds, fn)
		local running = true
		task.spawn(function()
			while running do
				task.wait(seconds)
				if running then
					fn()
				end
			end
		end)
		return function()
			running = false
		end
	end,
	-- Localized key only; the client resolves it from locale/strings.csv.
	notify = function(player, key)
		player:SetAttribute("IslandNoticeKey", key)
	end,
})
-- BEGIN production world interactions.
local liveWorld: any = world
liveWorld.travel = function(player: Player, destination: string, route: number?, extra: any?)
	local token: string? = nil
	if destination == "archipelago" then
		local actor = tostring(player.UserId)
		local opened = (factory :: any).archipelago.open(actor, {
			id = HttpService:GenerateGUID(false),
			index = route or 1,
			-- C7: a recorded departure seed from the explicit clock (Expedition.open forks it per route).
			seed = SeaChart.departureSeed(clock.now(), actor),
			revision = "robango-route-v1",
			ttl = 1800,
			entryBuffer = source.archipelago.entryBufferSeconds,
			party = extra and extra.party,
			departure = extra and extra.departure,
			sharedBy = extra and extra.sharedBy,
		})
		if not opened.ok and opened.reason ~= "expedition_active" then
			return false, opened.reason
		end
		local document = (factory :: any).expeditionStore.snapshot(actor)
		local trip = if document then document.archipelago else nil
		token = if trip and trip.party then trip.party.token .. ":" .. trip.stage else nil
	elseif destination == "next-island" then
		local advanced = (factory :: any).archipelago.nextIsland(tostring(player.UserId))
		if not advanced.ok then
			return false, advanced.reason
		end
		local document = (factory :: any).expeditionStore.snapshot(tostring(player.UserId))
		destination = if document.archipelago.status == "complete" then "home" else "archipelago"
		local party = document.archipelago.party
		token = if party then party.token .. ":" .. document.archipelago.stage else nil
	elseif destination == "home" and worldRole == "archipelago" then
		return (factory :: any).archipelago.recover(tostring(player.UserId), "return")
	end
	if not routing.travel then
		local facts = routingFacts(player.UserId, destination)
		local ok, reason = Topology.validateRoleTransition(worldRole, destination, facts and facts.level or 1)
		return false,
			if ok or destination == "next-island" or destination == "archipelago" then "studio_no_teleport" else reason
	end
	return routing.travel(player, destination, token)
end
-- C7 drift isles (G25): when an active drift isle's window ends, its layout regenerates from a
-- new recorded seed (SeaChart.driftReset) and the actor re-enters the archipelago, whose server
-- renders the persisted seed. In Studio there is no teleport; the reset is still recorded.
if worldRole == "archipelago" then
	local elapsed = 0
	local resetting: { [string]: boolean } = {}
	local driftWorker = RunService.Heartbeat:Connect(function(delta)
		elapsed += delta
		if elapsed < 5 then
			return
		end
		elapsed = 0
		local now = math.floor(clock.now())
		for _, player in Players:GetPlayers() do
			local actor = tostring(player.UserId)
			local document = if resetting[actor] then nil else (factory :: any).expeditionStore.snapshot(actor)
			local trip = document and document.archipelago
			if trip and trip.status == "active" and now >= trip.expiresAt then
				resetting[actor] = true
				task.spawn(function()
					local reset = (factory :: any).expeditionStore.transaction(actor, function(current)
						local state = current.archipelago
						local result: any = { ok = false, reason = "missing_expedition" }
						if state then
							local ok, reason = SeaChart.driftReset(state, now, SeaChart.TTL)
							result = { ok = ok, reason = reason, data = { seed = state.seed, party = state.party } }
						end
						return result
					end)
					if reset.ok then
						warn("ForgeDriftReset " .. actor .. " seed " .. tostring(reset.data.seed))
						-- Same "<outcome>|<serial>" channel as dock results; the new seed keeps it unique.
						player:SetAttribute("ForgeTravelResult", "drift_reset|" .. tostring(reset.data.seed))
						local party = reset.data.party
						if routing.travel and player.Parent then
							routing.travel(
								player,
								"archipelago",
								if party then party.token .. ":drift:" .. tostring(reset.data.seed) else nil
							)
						end
					end
					resetting[actor] = nil
				end)
			end
		end
	end)
	script.Destroying:Connect(function()
		driftWorker:Disconnect()
	end)
end
-- END production world interactions.
if RunService:IsStudio() and worldRole == "archipelago" and source.expedition then
	-- Studio layout: seed the durable expedition through the real departure API.
	local function depart(player: Player)
		local actor, port: any = tostring(player.UserId), nil
		while player.Parent and not port do
			task.wait(1)
			port = session.personalTransfer(actor)
		end
		-- A fresh Studio profile misses the selected stage's gates: seed level, grade, route access.
		local stage = tonumber(source.expedition.stage) or 1
		local need = require(script.Parent.StudioSetup).stageGates(content, source.expedition.templateId, stage)
		local raised = port
			and port.personal:update(port.profile(), function(view)
				local data = view.envelope.genres["survival-coop"].data
				local tree = require(Forge.core.domain.progression.SkillTree)
				local policy = (content :: any).progressionPolicy.tree
				local state = data.progression or tree.new(content, policy)
				data.progression = tree.level(state, policy, math.max(need.level, state.level))
				return view
			end)
		if raised then
			port.install(raised)
		end
		(factory :: any).expeditionStore.transaction(actor, function(document)
			document.development = document.development or { points = 0, definitions = {}, instabilityAccess = 1 }
			document.development.points = math.max(document.development.points, need.rank * 100)
			document.development.instabilityAccess = math.max(document.development.instabilityAccess, need.index)
			return { ok = true }
		end)
		local options = {
			id = HttpService:GenerateGUID(false),
			index = need.index,
			seed = source.expedition.seed,
			revision = "robango-route-v1",
			ttl = 1800,
			entryBuffer = source.archipelago.entryBufferSeconds,
			actor = tostring(player.UserId),
		}
		local opened = (factory :: any).archipelago.open(actor, options)
		if not opened.ok and opened.reason ~= "expedition_active" then
			warn("STUDIO_EXPEDITION:" .. tostring(opened.reason))
		elseif opened.ok and stage > 1 then
			-- Stand on the selected stage: the earlier stages' objectives count as done.
			(factory :: any).expeditionStore.transaction(actor, function(document)
				document.archipelago.stage = stage
				for id in need.completed do
					document.archipelago.completed[id] = true
				end
				return { ok = true }
			end)
		end
	end
	Players.PlayerAdded:Connect(depart)
	for _, player in Players:GetPlayers() do
		task.spawn(depart, player)
	end
end
provision.returnHome = function(actor: string)
	local player = Players:GetPlayerByUserId(tonumber(actor) or 0)
	if not player or not routing.travel then
		return { ok = false, reason = "HOME_ROUTE_UNAVAILABLE" }
	end
	local ok, reason = routing.travel(player, "home")
	return { ok = ok, reason = reason }
end
-- Only server code may request travel. A gameplay interaction must resolve the
-- destination role here; there is deliberately no client-controlled teleport remote.
if routing.travel then
	local travel = Instance.new("BindableFunction")
	travel.Name = "ForgeTravel"
	travel.OnInvoke = routing.travel
	travel.Parent = ServerStorage
end
-- C1 opening (onboarding role): server-owned beat steps. Boarding the Gannet resolves the
-- existing onboarding -> home transfer on the server; the client only sends checked intents.
local opening: any = (world :: any).opening
if opening then
	local AnalyticsService = game:GetService("AnalyticsService")
	local contracts: any = nil
	for _, extension in (factory.services.survivalExtensions or {}) :: { any } do
		contracts = if extension.id == "contracts" then extension else contracts
	end
	local function data(actor: string): any
		local port = session.personalTransfer(actor)
		return if port then port.profile().data.envelope.genres["survival-coop"].data else nil
	end
	local function rootOf(actor: string): BasePart?
		local player = Players:GetPlayerByUserId(tonumber(actor) or 0)
		local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		return if root and root:IsA("BasePart") then root else nil
	end
	opening.bind({
		tutorial = function(actor)
			local view = if contracts then contracts.snapshot(actor) else nil
			local tutorial = if type(view) == "table" then view.tutorial else nil
			return if type(tutorial) == "table" then tutorial.index else nil,
				type(tutorial) == "table" and tutorial.complete == true
		end,
		items = function(actor): { [string]: number }?
			local state = data(actor)
			if not state or not state.inventory then
				return nil
			end
			local totals: { [string]: number } = {}
			for _, item: any in state.inventory.bag.items do
				totals[item.catalogId] = (totals[item.catalogId] or 0) + item.quantity
			end
			return totals
		end,
		dodgeAt = function(actor)
			local state = data(actor)
			local defense = state and state.combat and state.combat.defense
			return if defense then defense.dodgeStart else nil
		end,
		position = function(actor)
			local root = rootOf(actor)
			return if root then root.Position else nil
		end,
		near = function(actor, part)
			return world.nearPart(actor, part)
		end,
		store = (factory :: any).expeditionStore,
		analytics = function(actor: string, step: string, index: number, beat: number)
			print("ForgeOpening " .. actor .. " opening_step " .. step)
			local player = Players:GetPlayerByUserId(tonumber(actor) or 0)
			if player then
				pcall(function()
					AnalyticsService:LogCustomEvent(player, "opening_step", index, {
						[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = step,
						[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = "beat " .. beat,
					})
				end)
			end
		end,
		travel = function(actor)
			local player = Players:GetPlayerByUserId(tonumber(actor) or 0)
			if not player then
				return false, "PLAYER_GONE"
			end
			return liveWorld.travel(player, "home")
		end,
	})
	local intent = Instance.new("RemoteFunction")
	intent.Name = "ForgeOpeningIntent"
	intent.OnServerInvoke = function(player: Player, kind: any)
		if type(kind) ~= "string" or #kind > 32 then
			return false, "INVALID_INTENT"
		end
		return opening.intent(tostring(player.UserId), kind)
	end
	intent.Parent = game:GetService("ReplicatedStorage")
	local elapsed = 0
	local openingTick = RunService.Heartbeat:Connect(function(delta)
		elapsed += delta
		if elapsed < 0.25 then
			return
		end
		elapsed = 0
		local ok, failure = pcall(opening.tick, session.members(), Clock.millis(clock.now()))
		if not ok then
			warn("OPENING_TICK:" .. tostring(failure))
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		opening.leave(tostring(player.UserId))
	end)
	script.Destroying:Connect(function()
		openingTick:Disconnect()
	end)
end

-- G22 social presence: live per-island population (MemoryStore) and clan tags over heads.
local presence = require(script.Parent.SocialPresence).start({
	map = runtimeServices.memoryStoreService:GetSortedMap(require(script.Parent.SocialPresence).MAP),
	enum = Enum,
	players = Players,
	workspace = workspace,
	role = worldRole,
	route = if source.expedition then tonumber(source.expedition.index) else nil,
	jobId = if game.JobId ~= "" then game.JobId else "studio",
	encode = function(value)
		return HttpService:JSONEncode(value)
	end,
	log = function(message)
		warn(message)
	end,
	membership = function(actor)
		return (clanDirectory.membership(actor))
	end,
	filter = function(text, userId)
		return game:GetService("TextService")
			:FilterStringAsync(text, userId, Enum.TextFilterContext.PublicChat)
			:GetNonChatStringForBroadcastAsync()
	end,
	every = function(seconds: number, fn: () -> ())
		-- Heartbeat accumulator like the trade worker: one tick at a time, the first right away.
		local running, elapsed = false, seconds
		local connection = RunService.Heartbeat:Connect(function(delta)
			elapsed += delta
			if running or elapsed < seconds then
				return
			end
			running, elapsed = true, 0
			task.spawn(function()
				local ok: boolean, failure: any = pcall(fn)
				running = false
				if not ok then
					warn("PRESENCE_TICK:" .. tostring(failure))
				end
			end)
		end)
		return function()
			connection:Disconnect()
		end
	end,
})
Players.PlayerAdded:Connect(function(player)
	presence.publish()
	presence.tagPlayer(player)
end)
Players.PlayerRemoving:Connect(function()
	task.defer(presence.publish)
end)
game:BindToClose(presence.stop)
-- Route cards read the summed population of each archipelago route (ExpeditionExtension).
visitWorld.population = function(listing: string): number?
	local counts = presence.counts
	return if counts then counts[listing] or 0 else nil
end
