--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local Shared = Forge.games["robango-island"].src.shared
local Server = require(Forge.core.infra.genre.Server)
local RuntimeBackend = require(Forge.core.infra.data.RuntimeBackend)
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local IslandBootstrap = require(Forge.genres["survival-coop"].module.IslandBootstrap)
local ServerStorage = game:GetService("ServerStorage")
local roleConfig = ServerStorage:FindFirstChild("ForgePlaceRoles")
local roles = if roleConfig and roleConfig:IsA("StringValue") then HttpService:JSONDecode(roleConfig.Value) else nil
local roleEnv = {
	roles = roles,
	placeId = game.PlaceId,
	privateServerId = game.PrivateServerId,
	isStudio = RunService:IsStudio(),
	studioRole = "onboarding",
}
local worldRole, routingOnly = IslandBootstrap.select(roleEnv)
workspace:SetAttribute("ForgeWorldRole", worldRole)
workspace:SetAttribute("ForgeTravelMode", if RunService:IsStudio() then "studio-single" else "live")
local Clock = require(Forge.core.infra.genre.Clock)
local clock = Clock.new(function()
	return DateTime.now().UnixTimestampMillis / 1000
end)
local backend = RuntimeBackend.new(require(script.Parent.PersistenceConfig), "SurvivalShared")
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
-- Taming/mounts: the pack only supplies the policy; the extension registry builds the system.
require(Forge.genres["survival-coop"].module.TamingExtension).configure(require(Shared.TamingConfig))
local Players = game:GetService("Players")
-- Shop: the pack catalog (runtime mirror of game.yml `monetization`) over the real engine ports.
-- The extension factory installs MarketplaceService.ProcessReceipt exactly once (via
-- MarketplacePort.onReceipt) when SurvivalFactory builds the extensions below; nothing else in this
-- place assigns ProcessReceipt. No grant hooks yet: see MonetizationCatalog for the open effects.
local MarketplacePort = require(Forge.core.infra.monetization.MarketplacePort)
local PolicyPort = require(Forge.core.infra.monetization.PolicyPort)
require(Forge.genres["survival-coop"].module.MonetizationExtension).configure({
	catalog = require(Shared.MonetizationCatalog) :: any,
	marketplace = MarketplacePort.roblox(game:GetService("MarketplaceService"), Players, Enum.ProductPurchaseDecision),
	policy = PolicyPort.roblox(game:GetService("PolicyService"), Players),
})
-- Market: the pack supplies tradeable goods and Players eligibility facts; the genre extension
-- owns the durable escrow and the Coins settlement over the live session (see MarketPorts).
local tutorialSource: any = nil
local joinedAt: { [string]: number } = {}
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
require(Forge.genres["survival-coop"].module.MarketExtension).configure(require(Shared.MarketPorts).config({
	accountAgeDays = function(actor)
		local userId = tonumber(actor)
		local player = if userId then Players:GetPlayerByUserId(userId) else nil
		return if player then player.AccountAge else nil
	end,
	sessionSeconds = function(actor, now)
		local since = joinedAt[actor]
		return if since then now - since else nil
	end,
	-- The Contracts extension owns the tutorial; an unavailable snapshot counts as incomplete.
	tutorialComplete = function(actor)
		local data = if tutorialSource then tutorialSource.snapshot(actor) else nil
		return type(data) == "table" and type(data.tutorial) == "table" and data.tutorial.complete == true
	end,
}))
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
end, worldRole, RunService:IsStudio())
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
local factory, err = require(script.Parent.SurvivalFactory)(content, source, visitWorld, backend, clock, {
	sessionId = game.JobId .. HttpService:GenerateGUID(false),
	leaseSeconds = 120,
	-- Transfer admission, grant discovery and recovery sweeps read through identity updates every
	-- heartbeat. Without this opt-in each of those became a durable write: a Studio co-op run wrote
	-- the camp record 131 times in 90 s and starved the persistence transport
	-- (COMMIT_FAILED:LOCAL_TRANSPORT_UNAVAILABLE on the next build reserve).
	suppressIdentityUpdates = true,
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
local routing = IslandBootstrap.start({
	roles = roles,
	studioRole = "onboarding",
	prepareHandoff = session.prepareHandoff,
	resumeHandoff = session.resumeHandoff,
	completeHandoff = session.completeHandoff,
	admitExpedition = (factory :: any).admitExpedition,
	facts = function(userId, _destination)
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
	end,
	players = game:GetService("Players"),
	teleportService = game:GetService("TeleportService"),
	memoryStoreService = game:GetService("MemoryStoreService"),
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
liveWorld.travel = function(player: Player, destination: string)
	if destination == "archipelago" then
		local actor = tostring(player.UserId)
		local opened = (factory :: any).archipelago.open(actor, {
			id = HttpService:GenerateGUID(false),
			index = 1,
			seed = 20261018,
			revision = "robango-route-v1",
			ttl = 1800,
			entryBuffer = source.archipelago.entryBufferSeconds,
		})
		if not opened.ok and opened.reason ~= "expedition_active" then
			return false, opened.reason
		end
	elseif destination == "next-island" then
		local advanced = (factory :: any).archipelago.nextIsland(tostring(player.UserId))
		if not advanced.ok then
			return false, advanced.reason
		end
		local document = (factory :: any).expeditionStore.snapshot(tostring(player.UserId))
		destination = if document.archipelago.status == "complete" then "home" else "archipelago"
	elseif destination == "home" and worldRole == "archipelago" then
		return (factory :: any).archipelago.recover(tostring(player.UserId), "return")
	end
	return if routing.travel then routing.travel(player, destination) else false
end
-- END production world interactions.
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
