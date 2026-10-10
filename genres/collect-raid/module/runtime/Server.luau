--!strict
-- Server: authoritative collect-raid server runtime (persistence, teams,
-- siege, merge, quests, monetization). Generic across packs: every id,
-- price, team name, and user-facing string comes from `opts`.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ServerStorage = game:GetService("ServerStorage")
local Teams = game:GetService("Teams")
local MarketplaceService = game:GetService("MarketplaceService")
local PolicyService = game:GetService("PolicyService")
local AnalyticsService = game:GetService("AnalyticsService")

local Loop = require("./Loop")
local RaidTarget = require("./RaidTarget")
local LiveopsEvent = require("./LiveopsEvent")
local CollectRaid = require("../CollectRaid")
local ProfileSchema = require("../../../../core/domain/state/ProfileSchema")
local ProfileStore = require("../../../../core/infra/data/ProfileStore")
local MemoryBackend = require("../../../../core/infra/data/MemoryBackend")
local DataStoreBackend = require("../../../../core/infra/data/DataStoreBackend")
local Receipts = require("../../../../core/infra/monetization/Receipts")
local Events = require("../../../../core/infra/analytics/Events")
local RateLimiter = require("../../../../core/anticheat/RateLimiter")
local Validate = require("../../../../core/anticheat/Validate")
local Schedule = require("../../../../core/infra/liveops/Schedule")
local Broadcast = require("../../../../core/infra/liveops/Broadcast")

export type MergeFamily = { id: string, displayName: string, rules: { any } }

export type CatalogGrant = Loop.Grant

export type CatalogProduct = { key: string, price: number, grant: CatalogGrant, [string]: any }
export type CatalogGamepass = { key: string, id: number, price: number, [string]: any }

-- Pack monetization data (see the pack's Catalog.luau); kept separate from
-- Loop.Config because it is Robux-only and never touched by the genre logic
-- that decides odds or grants random rewards.
export type Catalog = {
	productById: { [number]: CatalogProduct },
	productByKey: { [string]: CatalogProduct },
	gamepassById: { [number]: CatalogGamepass },
	gamepasses: { CatalogGamepass },
	[string]: any,
}

export type Remotes = {
	BuyEgg: RemoteFunction,
	HatchEgg: RemoteFunction,
	StateChanged: RemoteEvent,
	Raid: RemoteFunction,
	Merge: RemoteFunction,
	ClaimQuest: RemoteFunction,
	SiegeState: RemoteEvent,
	Notify: RemoteEvent,
	StoreOpen: RemoteEvent,
	TutorialState: RemoteEvent,
	RaidReplay: RemoteEvent,
}

-- World hooks the server needs, matching the shape of a per-pack World module
-- (a thin wrapper over the genre's WorldBuilder; see World.luau).
export type World = {
	build: () -> Folder,
	spawn: (team: string) -> SpawnLocation?,
	incubator: (team: string, index: number) -> Model?,
	vault: (team: string) -> Model?,
}

-- User-facing copy. The genre never hardcodes display strings; the pack
-- supplies them (optionally routed through its own locale lookup).
export type Messages = {
	profileLocked: string,
	profileLoadFailed: string,
	serverBoostActive: string,
	rareHatchLocal: (playerName: string, displayName: string) -> string,
	rareHatchGlobal: (playerName: string, displayName: string) -> string,
	wrongTeamIncubator: (teamName: string) -> string,
	hatchFailed: (reason: string) -> string,
	raidOwnVault: string,
	raidFailed: (reason: string) -> string,
	incubatorActionText: string,
	incubatorObjectText: (index: number) -> string,
	vaultActionText: string,
	vaultObjectText: (teamName: string) -> string,
}

export type Options = {
	config: Loop.Config & { anticheat: RateLimiter.Config, liveops: { events: { Schedule.EventSpec }, flags: any } },
	catalog: Catalog,
	world: World,
	remotes: Remotes,
	messages: Messages,
	teams: { string },
	teamColors: { [string]: BrickColor },
	rareRarities: { [string]: boolean },
	storeName: string,
	debugName: string,
	logPrefix: string,
	incubatorsPerTeam: number,
}

local Server = {}

function Server.start(opts: Options): ()
	local Config = opts.config
	local Catalog = opts.catalog
	local World = opts.world
	local Remotes = opts.remotes
	local Messages = opts.messages
	local TEAM_NAMES = opts.teams
	local TEAM_COLORS = opts.teamColors
	local logPrefix = "[" .. opts.logPrefix .. "] "

	local BuyEgg = Remotes.BuyEgg
	local HatchEgg = Remotes.HatchEgg
	local StateChanged = Remotes.StateChanged
	local Raid = Remotes.Raid
	local MergeRemote = Remotes.Merge
	local ClaimQuest = Remotes.ClaimQuest
	local SiegeState = Remotes.SiegeState
	local Notify = Remotes.Notify
	local StoreOpen = Remotes.StoreOpen
	local TutorialState = Remotes.TutorialState
	local RaidReplayRemote = Remotes.RaidReplay

	-- Per-player remote rate limits; each call site supplies os.clock() as now.
	local limiter = RateLimiter.new(Config.anticheat)

	-- LiveOps schedule; coin multiplier applies to production ticks while an event is active.
	-- Starts from the pack's static Config.liveops.events and grows at runtime
	-- when a `forge liveops push` broadcast lands (see pushedLiveopsEvents below),
	-- so a pushed event actually reaches the coin multiplier the Heartbeat tick
	-- already reads via liveSchedule:multiplier("coins", now).
	local liveSchedule = Schedule.new(Config.liveops.events)
	local pushedLiveopsEvents: { Schedule.EventSpec } = {}
	local nextPushedLiveopsEventId = 1

	-- Applies a `kind = "event"` LiveOps broadcast (the envelope `forge liveops
	-- push` sends; see cli/forge/lib/planner.luau renderLiveopsYml and
	-- cli/forge/commands/liveops.luau) to the runtime coin multiplier by adding
	-- a new event to liveSchedule with the pushed multiplier/duration. Matches
	-- the data shape `{ multiplier: number, durationSeconds: number }` that
	-- `renderLiveopsYml`'s starter `double-coins` event publishes.
	local function applyLiveopsEvent(data: { [string]: any }): ()
		local multiplier, durationSeconds = LiveopsEvent.validate(data)
		if multiplier == nil or durationSeconds == nil then
			return
		end
		local now = os.time()
		local eventId = string.format("liveops-push-%d", nextPushedLiveopsEventId)
		nextPushedLiveopsEventId += 1
		table.insert(pushedLiveopsEvents, {
			id = eventId,
			startsAt = now,
			endsAt = now + durationSeconds,
			multipliers = { coins = multiplier },
		})

		local mergedEvents: { Schedule.EventSpec } = {}
		for _, event in Config.liveops.events do
			table.insert(mergedEvents, event)
		end
		for _, event in pushedLiveopsEvents do
			table.insert(mergedEvents, event)
		end
		liveSchedule = Schedule.new(mergedEvents)
	end

	-- Cross-server LiveOps broadcast: announce rare hatches to peer servers and
	-- re-broadcast theirs to local players. MessagingService can be unavailable in
	-- Studio, so setup is wrapped in pcall inside task.spawn (SubscribeAsync can yield
	-- forever) and the instance stays nil until it succeeds.
	local broadcastServerId = if game.JobId ~= "" then game.JobId else "studio"
	local broadcast: Broadcast.Broadcast? = nil
	task.spawn(function()
		local setupOk, instance = pcall(function()
			local created = Broadcast.new(
				Broadcast.messagingServiceTransport(game:GetService("MessagingService")),
				broadcastServerId
			)
			created:on("rareHatch", function(data: { [string]: any })
				-- data.creature is the wire creatureId, not display text: resolve it to the
				-- same displayName the local toast uses, so remote servers never show a
				-- raw id like "solar-titan".
				local creatureConfig = Config.creatures[tostring(data.creature)]
				local creatureDisplayName = if creatureConfig ~= nil
					then creatureConfig.displayName
					else tostring(data.creature)
				Notify:FireAllClients(Messages.rareHatchGlobal(tostring(data.player), creatureDisplayName))
			end)
			-- `forge liveops push` announces kind = "event" (see renderLiveopsYml); a
			-- server with no handler for a kind just drops it and increments
			-- Broadcast.dropped (see Broadcast._receive), so a live push otherwise
			-- never reaches the coin multiplier. Applying it here also means a push
			-- received by one server propagates to every peer server subscribed to
			-- the same topic, matching how rareHatch already fans out.
			created:on("event", applyLiveopsEvent)
			return created
		end)
		if setupOk then
			broadcast = instance :: Broadcast.Broadcast
		end
	end)

	local SAVE_INTERVAL_SECONDS = 60

	-- Only Studio may fall back to memory. Live servers always use durable
	-- storage; transient failures go through ProfileStore retries and fail closed.
	local function dataStoreUsable(): boolean
		return pcall(function()
			local probe = DataStoreService:GetDataStore(opts.storeName)
			probe:GetAsync("__collect_raid_probe__")
		end)
	end

	local backend: MemoryBackend.Backend
	if not RunService:IsStudio() or dataStoreUsable() then
		backend = DataStoreBackend.new(opts.storeName)
		print(logPrefix .. "persistence backend: datastore")
	else
		backend = MemoryBackend.new()
		print(logPrefix .. "persistence backend: memory")
	end

	local sessionId = if game.JobId ~= "" then game.JobId else string.format("studio-%d", os.time())
	local store = ProfileStore.new(backend, {
		sessionId = sessionId,
		-- Must stay >= 2x SAVE_INTERVAL_SECONDS: the lock's `at` is refreshed on every
		-- autosave, so a live session keeps renewing its lease every SAVE_INTERVAL_SECONDS.
		-- A shorter-than-2x timeout would let a second server treat a session as stale
		-- between two autosaves and steal the lock mid-session; 2x leaves one full
		-- autosave interval of slack for that renewal to land.
		lockTimeout = 2 * SAVE_INTERVAL_SECONDS,
		retries = 3,
		-- Retries must actually back off. The library's own default is a no-op so that
		-- it stays runnable under Lune (no `task` global there), so production has to
		-- inject the delay. `attempt` is the 1-indexed attempt that just failed, so the
		-- delays are 1s, 2s, 4s, capped at 16s. Without this, a DataStore throttle
		-- would have all four attempts fired back to back, which burns request budget
		-- and never gives the throttle a chance to clear.
		wait = function(attempt: number): ()
			task.wait(math.min(2 ^ (attempt - 1), 16))
		end,
		now = function(): number
			return os.time()
		end,
	})

	local function migrate(raw: any): { [string]: any }
		return ProfileSchema.migrate(raw, Config.profile.version, Config.profile.defaults, {})
	end

	local function profileKey(player: Player): string
		return "player_" .. tostring(player.UserId)
	end

	-- Teams and vaults.
	local function ensureTeams(): ()
		for _, teamName in TEAM_NAMES do
			if Teams:FindFirstChild(teamName) == nil then
				local team = Instance.new("Team")
				team.Name = teamName
				team.AutoAssignable = false
				team.TeamColor = TEAM_COLORS[teamName]
				team.Parent = Teams
			end
		end
	end

	ensureTeams()
	World.build()

	local function rivalOf(teamName: string): string?
		return RaidTarget.resolve(TEAM_NAMES, teamName, nil)
	end

	local function assignTeam(player: Player): ()
		local counts: { [string]: number } = {}
		local teamInstances: { [string]: Team } = {}
		for _, teamName in TEAM_NAMES do
			local team = Teams:FindFirstChild(teamName) :: Team?
			if team == nil then
				return
			end
			teamInstances[teamName] = team
			counts[teamName] = 0
		end
		for _, other in Players:GetPlayers() do
			local otherTeam = other.Team
			if otherTeam ~= nil and counts[otherTeam.Name] ~= nil then
				counts[otherTeam.Name] += 1
			end
		end

		local chosen = TEAM_NAMES[1]
		for _, teamName in TEAM_NAMES do
			if counts[teamName] < counts[chosen] then
				chosen = teamName
			end
		end
		player.Team = teamInstances[chosen]
		local spawnLocation = World.spawn(chosen)
		if spawnLocation ~= nil then
			player.RespawnLocation = spawnLocation
		end
		player:LoadCharacterAsync()
	end

	-- Siege schedule: idle at start, first window opens one period after boot.
	local serverStart = os.time()
	local siegeForcedUntil = 0
	-- While forceSiege is active the core schedule is evaluated at raw + offset so
	-- its phase reads active; the offset only applies until the forced window ends.
	local siegeForcedOffset = 0
	-- Server-wide luck-boost window (product grant). This alters the *free* hatch
	-- roll's odds (affectsFreeHatchOnly in the monetization planner): hatching
	-- always spends free currency, so no Robux purchase buys a random item or a
	-- better chance at one. Every StateChanged snapshot below passes the current
	-- multiplier so the disclosed odds panel always matches the odds actually rolled.
	local serverBoostUntil = 0
	-- Applied to WeightedRoll via Loop.hatch/Loop.snapshot while the boost is active:
	-- the pool's first (common) entry keeps its base weight and every other entry's
	-- weight is multiplied by this factor (see Loop.luau and WeightedRoll.boost).
	local SERVER_LUCK_MULTIPLIER = 2

	local function activeLuckMultiplier(now: number): number?
		if now < serverBoostUntil then
			return SERVER_LUCK_MULTIPLIER
		end
		return nil
	end

	local function siegeElapsed(): number
		local raw = os.time() - serverStart
		if raw < siegeForcedUntil then
			return raw + siegeForcedOffset
		end
		return raw
	end

	local playerStates: { [Player]: Loop.PlayerState } = {}
	local profiles: { [Player]: ProfileStore.Profile } = {}
	local rng = Random.new()
	local siegeJoined: { [Player]: string } = {}

	-- QA-only mirror of the most recently joined player's live state, read by
	-- Open Cloud Luau Execution (`execute_luau` steps in qa-scenarios/*.yml) and
	-- by the Studio MCP playtest subagent. Both run privileged server-side Luau,
	-- never client code, so exposing it unconditionally (not Studio-gated) never
	-- reaches an untrusted client; smoke scenarios run against a published,
	-- non-Studio place where RunService:IsStudio() is false.
	local qaPlayer: Player? = nil
	local qaLastRaidMoved = 0
	local qaLastCoinSnapshot = 0

	local function qaState(): Loop.PlayerState?
		if qaPlayer == nil then
			return nil
		end
		return playerStates[qaPlayer]
	end

	-- Analytics: one emitter whose sink logs to AnalyticsService and stdout.
	local analytics = Events.new(function(name: string, fields: Events.Fields)
		print(logPrefix .. "analytics " .. name)
		local source = fields.player
		if typeof(source) == "Instance" and source:IsA("Player") then
			pcall(function()
				AnalyticsService:LogCustomEvent(source, name, 1)
			end)
		end
	end)

	local function track(player: Player, name: string, fields: Events.Fields?): ()
		local payload: Events.Fields = fields or {}
		payload.player = player
		analytics:emit(name, payload)
	end

	-- Raids run synchronously, so the acting player is visible to the OnRaid hook
	-- through this context while collect-raid moves creatures between team vaults.
	local raidActor: { player: Player, state: Loop.PlayerState, windowId: string }? = nil

	-- Forward reference: OnSiegePhase below needs to call back into collectRaid,
	-- but the hooks table is built before CollectRaid.new returns the instance
	-- that will invoke it.
	local collectRaidRef: CollectRaid.CollectRaid? = nil

	local hooks: CollectRaid.Hooks = {
		OnRaid = function(context)
			local actor = raidActor
			if actor == nil or context.moved <= 0 then
				return
			end
			Loop.recordQuest(actor.state, "raid", 1)
			track(actor.player, "raid_success", { raidId = actor.windowId })
			print(
				string.format(
					logPrefix .. "%s raided %d creature(s) from %s",
					actor.player.Name,
					context.moved,
					context.defender
				)
			)
		end,
		-- Auto Lock deposits a hatch non-raidable while the siege is idle so it
		-- cannot be raided before the next window opens; once that window
		-- actually opens the lock has served its purpose (the pass promises
		-- protection "before a siege", not forever), so every team's vault is
		-- released back to normal raidable rules at the idle -> active edge.
		OnSiegePhase = function(context)
			if context.phase ~= "active" or collectRaidRef == nil then
				return
			end
			for _, teamName in TEAM_NAMES do
				collectRaidRef:releaseLocked(teamName)
			end
		end,
	}

	local collectRaid = CollectRaid.new({ teams = TEAM_NAMES, siege = Config.siege }, hooks)
	collectRaidRef = collectRaid

	local function currentSiege(): (string, number)
		return collectRaid:phase(siegeElapsed())
	end

	local function broadcastSiege(): ()
		local phase, secondsLeft = currentSiege()
		SiegeState:FireAllClients({
			phase = phase,
			secondsLeft = secondsLeft,
			luckUntil = serverBoostUntil,
			vaultCounts = collectRaid:counts(),
		})
	end

	local function siegeWindowId(): string
		local elapsed = os.time() - serverStart
		return "siege-" .. tostring(math.floor(elapsed / Config.siege.period))
	end

	-- A team is shielded while any online member has an active siege shield.
	local function teamShielded(teamName: string, now: number): boolean
		for other, otherState in playerStates do
			local otherTeam: Team? = other.Team
			if otherTeam ~= nil and otherTeam.Name == teamName and Loop.isShielded(otherState, now) then
				return true
			end
		end
		return false
	end

	local function saveProfile(player: Player): boolean
		local profile = profiles[player]
		local state = playerStates[player]
		if profile == nil or state == nil then
			return false
		end
		profile.data = Loop.toSave(Config, state, os.time())
		local ok, err = store:save(profile)
		if not ok then
			warn(string.format(logPrefix .. "save failed for %s: %s", player.Name, tostring(err)))
		end
		return ok
	end

	-- Monetization: catalog id lookup, idempotent receipts, and pass ownership.
	-- Studio-only synthetic ids let the debug surface exercise the receipt processor.
	local debugProductIds: { [string]: number } = {}
	-- Sent to the receipt processor for keys with no synthetic id: it maps to no
	-- catalog entry, so the processor decides "NotProcessedYet" on the normal path.
	local UNKNOWN_DEBUG_PRODUCT_ID = 900000999

	local function productKeyFor(productId: number): string?
		local entry = Catalog.productById[productId]
		if entry ~= nil then
			return entry.key
		end
		for key, id in debugProductIds do
			if id == productId then
				return key
			end
		end
		return nil
	end

	-- The player each in-flight receipt belongs to, keyed by PurchaseId.
	local receiptPlayers: { [string]: Player } = {}

	local function applyProductGrant(player: Player, state: Loop.PlayerState, productKey: string, now: number): boolean
		local entry = Catalog.productByKey[productKey]
		if entry == nil then
			return false
		end
		if #state.processedPurchases >= Loop.SAVE_CAPACITY then
			return false
		end
		local grant = entry.grant
		if grant.kind == "serverBoost" then
			serverBoostUntil = now + (grant.seconds or 0)
			Notify:FireAllClients(Messages.serverBoostActive)
		elseif not Loop.grantProduct(Config, state, grant :: Loop.ProductGrant, now) then
			return false
		end
		track(player, "robux_purchase", { productKey = productKey, price = entry.price })
		return true
	end

	local receipts = Receipts.new({
		grant = function(userId: number, productKey: string): boolean
			local player = Players:GetPlayerByUserId(userId)
			if player == nil then
				return false
			end
			local state = playerStates[player]
			if state == nil then
				return false
			end
			return applyProductGrant(player, state, productKey, os.time())
		end,
		hasProcessed = function(purchaseId: string): boolean
			local player: Player? = receiptPlayers[purchaseId]
			if player == nil then
				return false
			end
			local state = playerStates[player]
			if state == nil then
				return false
			end
			return Loop.hasProcessed(state, purchaseId)
		end,
		markProcessed = function(purchaseId: string): ()
			local player: Player? = receiptPlayers[purchaseId]
			if player == nil then
				return
			end
			local state = playerStates[player]
			if state ~= nil then
				Loop.markProcessed(state, purchaseId)
			end
		end,
		productKeyFor = productKeyFor,
		-- Durably persists the grant before the processor reports PurchaseGranted.
		-- Only false/errors here trigger a Roblox retry; commit itself never grants
		-- twice (Receipts already marked the purchase processed by this point).
		commit = function(userId: number): boolean
			local player = Players:GetPlayerByUserId(userId)
			if player == nil then
				-- The player isn't here to receive the save, but they were never
				-- registered without one either (see onPlayerAdded's disconnect-during-
				-- load guard), so there is no in-memory state this purchase could still
				-- be waiting to persist. Nothing to commit; let Roblox retry on next
				-- rejoin, when hasProcessed will already be true from the ledger.
				return true
			end
			return saveProfile(player)
		end,
	})

	local function handleReceipt(receipt: Receipts.Receipt): string
		local player = Players:GetPlayerByUserId(receipt.PlayerId)
		if player == nil then
			return "NotProcessedYet"
		end
		receiptPlayers[receipt.PurchaseId] = player
		local decision = receipts:process(receipt)
		receiptPlayers[receipt.PurchaseId] = nil
		if decision == "PurchaseGranted" then
			local state = playerStates[player]
			if state ~= nil then
				-- Receipts' own commit hook (above) already persisted the grant before
				-- returning PurchaseGranted; just push the fresh snapshot to the client.
				local now = os.time()
				StateChanged:FireClient(player, Loop.snapshot(Config, state, now, activeLuckMultiplier(now)))
			end
		end
		return decision
	end

	MarketplaceService.ProcessReceipt = function(receipt: any): Enum.ProductPurchaseDecision
		local decision = handleReceipt(receipt :: Receipts.Receipt)
		if decision == "PurchaseGranted" then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local function refreshPasses(player: Player, state: Loop.PlayerState): ()
		for _, entry in Catalog.gamepasses do
			if entry.id > 0 then
				local ok, owns = pcall(function()
					return MarketplaceService:UserOwnsGamePassAsync(player.UserId, entry.id)
				end)
				if ok and owns == true then
					Loop.setPass(state, entry.key, true)
				end
			end
		end
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, gamePassId: number, wasPurchased: boolean)
			if not wasPurchased then
				return
			end
			local state = playerStates[player]
			if state == nil then
				return
			end
			local entry = Catalog.gamepassById[gamePassId]
			if entry == nil then
				return
			end
			Loop.setPass(state, entry.key, true)
			track(player, "robux_purchase", { productKey = entry.key, price = entry.price })
			saveProfile(player)
			local now = os.time()
			StateChanged:FireClient(player, Loop.snapshot(Config, state, now, activeLuckMultiplier(now)))
		end
	)

	-- We sell no paid random items, so this is logged for the record only.
	local function logPaidRandomItemsRestriction(player: Player): ()
		local ok, info = pcall(function()
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end)
		if ok and type(info) == "table" then
			print(
				string.format(
					logPrefix .. "%s ArePaidRandomItemsRestricted=%s (no paid random items sold)",
					player.Name,
					tostring(info.ArePaidRandomItemsRestricted)
				)
			)
		end
	end

	local function fireTutorialState(player: Player, state: Loop.PlayerState): ()
		TutorialState:FireClient(player, {
			step = Loop.tutorialStepId(state),
			hint = Loop.tutorialHint(state),
		})
	end

	local function observeTutorial(player: Player, state: Loop.PlayerState, eventName: string): ()
		local stepId = Loop.tutorialStepId(state)
		if not Loop.observeTutorial(state, eventName) then
			return
		end
		track(player, "tutorial_step", { step = stepId })
		if Loop.tutorialComplete(state) then
			track(player, "tutorial_complete", {})
		end
		fireTutorialState(player, state)
	end

	local function onPlayerAdded(player: Player): ()
		local profile, err = store:load(profileKey(player), migrate)
		if profile == nil then
			if err == "locked" then
				player:Kick(Messages.profileLocked)
			else
				player:Kick(Messages.profileLoadFailed)
			end
			return
		end

		-- The player may have disconnected while store:load was yielding on the
		-- DataStore round trip. Release the lock and register nothing for them:
		-- onPlayerRemoving already ran and found no profile to release, so if we
		-- registered here anyway the entry would leak for the life of the server
		-- and its stale saves would fight the player's next session. Checking by
		-- UserId is not enough: a fast rejoin to this same server creates a new
		-- Player object with the same UserId before this load returns, and
		-- GetPlayerByUserId would find that new object and wrongly treat this
		-- departed `player` as still connected. Checking this exact Player
		-- instance's Parent catches only this player's own disconnect.
		if player.Parent ~= Players then
			store:release(profile)
			return
		end

		profiles[player] = profile
		local state = Loop.fromSave(Config, profile.data, os.time())
		playerStates[player] = state
		qaPlayer = player
		assignTeam(player)

		refreshPasses(player, state)
		logPaidRandomItemsRestriction(player)

		local joinNow = os.time()
		StateChanged:FireClient(player, Loop.snapshot(Config, state, joinNow, activeLuckMultiplier(joinNow)))
		fireTutorialState(player, state)
		track(player, "session_start", {})
		broadcastSiege()
		print(
			string.format(
				logPrefix .. "%s joined team %s",
				player.Name,
				if player.Team then player.Team.Name else "none"
			)
		)
	end

	-- Shared by PlayerRemoving and the Studio-only sessionEnd debug action: emit the
	-- session_end event and persist the profile without tearing the session down.
	local function endSession(player: Player): ()
		track(player, "session_end", {})
		saveProfile(player)
	end

	local function onPlayerRemoving(player: Player): ()
		endSession(player)
		limiter:forget(tostring(player.UserId))
		local profile = profiles[player]
		if profile ~= nil then
			store:release(profile)
		end
		profiles[player] = nil
		playerStates[player] = nil
		siegeJoined[player] = nil
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- Remotes.
	BuyEgg.OnServerInvoke = function(player: Player, sourceId: any)
		local allowed, limitReason = limiter:allow(tostring(player.UserId), "BuyEgg", os.clock())
		if not allowed then
			return false, limitReason
		end

		if not Validate.isString(sourceId, 64) then
			return false, "invalid source id type"
		end

		local state = playerStates[player]
		if not state then
			return false, "player state not found"
		end

		local now = os.time()
		local chargedPrice = Loop.sourcePrice(Config, state, sourceId)
		local ok, reason = Loop.buySource(Config, state, sourceId, now)
		if ok then
			print(string.format(logPrefix .. "%s bought source %s", player.Name, sourceId))
			track(player, "egg_purchase", { eggId = sourceId, price = chargedPrice })
			observeTutorial(player, state, "buy")
			StateChanged:FireClient(player, Loop.snapshot(Config, state, now, activeLuckMultiplier(now)))
			return true, nil
		end

		return false, reason
	end

	local function hatchHandler(player: Player, index: any)
		local allowed, limitReason = limiter:allow(tostring(player.UserId), "HatchEgg", os.clock())
		if not allowed then
			return false, limitReason
		end

		if
			not Validate.isIndex(index, 1, Loop.maxIncubators(Config, playerStates[player] or Loop.newPlayer(Config)))
		then
			return false, "invalid incubator index type"
		end

		local state = playerStates[player]
		if not state then
			return false, "player state not found"
		end

		local now = os.time()
		local roll = rng:NextNumber()
		local incubator = state.incubators[index]
		local sourceId = if incubator ~= nil then incubator.sourceId else nil
		local ok, creatureIdOrReason = Loop.hatch(Config, state, index, now, roll, activeLuckMultiplier(now))
		if ok then
			local creatureId = creatureIdOrReason
			local team: Team? = player.Team
			if team ~= nil then
				-- Auto Lock (autoLock pass): deposit non-raidable while a siege is not
				-- yet open, so the creature sits locked in the vault before the window
				-- comes; once a raid is active the deposit is raidable like any other.
				local raidable = currentSiege() == "active" or not state.passes.autoLock
				collectRaid:collect(team.Name, creatureId, raidable)
			end

			local creatureConfig = Config.creatures[creatureId]
			if creatureConfig ~= nil and opts.rareRarities[creatureConfig.rarity] then
				Notify:FireAllClients(Messages.rareHatchLocal(player.Name, creatureConfig.displayName))
				if broadcast ~= nil then
					broadcast:announce("rareHatch", { player = player.Name, creature = creatureId })
				end
			end
			if sourceId ~= nil and creatureConfig ~= nil then
				track(player, "egg_hatch", { eggId = sourceId, kaijuId = creatureId, rarity = creatureConfig.rarity })
			end
			observeTutorial(player, state, "hatch")

			print(string.format(logPrefix .. "%s hatched %s at slot %d", player.Name, creatureId, index))
			StateChanged:FireClient(player, Loop.snapshot(Config, state, now, activeLuckMultiplier(now)))
			broadcastSiege()
			return true, creatureId
		end

		return false, creatureIdOrReason
	end
	HatchEgg.OnServerInvoke = hatchHandler

	local function raidHandler(player: Player, target: any)
		local allowed, limitReason = limiter:allow(tostring(player.UserId), "Raid", os.clock())
		if not allowed then
			return false, limitReason
		end

		local state = playerStates[player]
		if not state then
			return false, "player state not found"
		end

		local team: Team? = player.Team
		if team == nil then
			return false, "no team assigned"
		end

		local rivalName = RaidTarget.resolve(TEAM_NAMES, team.Name, target)
		if rivalName == nil then
			return false, "no rival team"
		end

		local phase = currentSiege()
		if phase ~= "active" then
			return false, "siege not active"
		end

		local now = os.time()
		local windowId = siegeWindowId()
		if siegeJoined[player] ~= windowId then
			siegeJoined[player] = windowId
			track(player, "siege_join", { siegeId = windowId })
		end

		if teamShielded(rivalName, now) then
			return false, "rival shielded"
		end

		raidActor = { player = player, state = state, windowId = windowId }
		local moved = collectRaid:raid(team.Name, rivalName, siegeElapsed(), false)
		raidActor = nil
		qaLastRaidMoved = moved

		local raidNow = os.time()
		StateChanged:FireClient(player, Loop.snapshot(Config, state, raidNow, activeLuckMultiplier(raidNow)))
		broadcastSiege()
		if moved > 0 then
			RaidReplayRemote:FireClient(player, { rival = rivalName, moved = moved })
		end
		return true, moved
	end
	Raid.OnServerInvoke = function(player: Player)
		return raidHandler(player, nil)
	end

	MergeRemote.OnServerInvoke = function(player: Player, familyIndex: any)
		local allowed, limitReason = limiter:allow(tostring(player.UserId), "Merge", os.clock())
		if not allowed then
			return false, limitReason
		end

		local state = playerStates[player]
		if not state then
			return false, "player state not found"
		end
		if not Validate.isIndex(familyIndex, 1, #Config.mergeFamilies) then
			return false, "invalid family index"
		end

		local family = Config.mergeFamilies[familyIndex]
		if family == nil then
			return false, "unknown family"
		end

		local lastErr = "no merge available"
		for _, rule in family.rules do
			local ok, resultId, err, fromId = Loop.merge(Config, state, family, rule)
			if ok then
				track(
					player,
					"kaiju_merge",
					{ fromKaijuId = fromId or rule.from, toKaijuId = resultId or rule.resultId }
				)
				print(string.format(logPrefix .. "%s merged into %s", player.Name, tostring(resultId)))
				local mergeNow = os.time()
				StateChanged:FireClient(player, Loop.snapshot(Config, state, mergeNow, activeLuckMultiplier(mergeNow)))
				return true, resultId
			end
			lastErr = err or lastErr
		end

		return false, lastErr
	end

	ClaimQuest.OnServerInvoke = function(player: Player, questId: any)
		local allowed, limitReason = limiter:allow(tostring(player.UserId), "ClaimQuest", os.clock())
		if not allowed then
			return false, limitReason
		end

		local state = playerStates[player]
		if not state then
			return false, "player state not found"
		end
		if not Validate.isString(questId, 64) then
			return false, "invalid quest id"
		end

		local known = false
		for _, questDef in Config.dailyQuests do
			if questDef.id == questId then
				known = true
				break
			end
		end
		if not known then
			return false, "unknown quest"
		end

		local ok, reward = Loop.claimQuest(Config, state, questId)
		if ok then
			track(player, "quest_claim", { questId = questId })
			observeTutorial(player, state, "claim")
			print(string.format(logPrefix .. "%s claimed quest %s for %d", player.Name, questId, reward))
			local claimNow = os.time()
			StateChanged:FireClient(player, Loop.snapshot(Config, state, claimNow, activeLuckMultiplier(claimNow)))
		end
		return ok, reward
	end

	StoreOpen.OnServerEvent:Connect(function(player: Player)
		local allowed = limiter:allow(tostring(player.UserId), "StoreOpen", os.clock())
		if not allowed then
			return
		end
		local state = playerStates[player]
		if state == nil then
			return
		end
		track(player, "store_open", {})
		observeTutorial(player, state, "store")
	end)

	-- Heartbeat: one production tick and one siege broadcast per second, plus saves.
	local secondAccumulator = 0
	local saveAccumulator = 0

	RunService.Heartbeat:Connect(function(dt: number)
		secondAccumulator += dt
		while secondAccumulator >= 1 do
			secondAccumulator -= 1
			local now = os.time()
			-- Effective-multiplier cap: Schedule.multiplier multiplies every active
			-- event together, so two valid (<= LiveopsEvent.MAX_MULTIPLIER each)
			-- pushed events overlapping in time could otherwise stack past the
			-- intended cap. Clamp only the number fed into Loop.tick; Schedule's
			-- own (static-schedule) behavior is unchanged.
			local coinMultiplier = LiveopsEvent.effectiveMultiplier(liveSchedule:multiplier("coins", now))

			for player, state in playerStates do
				Loop.tick(Config, state, 1, coinMultiplier, now)
				StateChanged:FireClient(player, Loop.snapshot(Config, state, now, activeLuckMultiplier(now)))
			end

			broadcastSiege()

			saveAccumulator += 1
			if saveAccumulator >= SAVE_INTERVAL_SECONDS then
				saveAccumulator = 0
				for player in playerStates do
					saveProfile(player)
				end
			end
		end
	end)

	game:BindToClose(function()
		for player in profiles do
			saveProfile(player)
		end
		for _, profile in profiles do
			store:release(profile)
		end
	end)

	-- Studio-only debug surface.
	if RunService:IsStudio() then
		-- Synthetic Roblox ids so the debug surface can exercise the real receipt
		-- processor. Built from the pack's own Catalog.products (key -> synthetic
		-- id) rather than a hardcoded list, so grantProduct works for every
		-- catalog key the pack ships, not just the template's "kaijuPack".
		local nextDebugProductId = 900000001
		for _, entry in Catalog.products do
			debugProductIds[entry.key] = nextDebugProductId
			nextDebugProductId += 1
		end

		local debugFn = Instance.new("BindableFunction")
		debugFn.Name = opts.debugName
		debugFn.OnInvoke = function(...: any): any
			local args = { ... }
			local action = args[1]

			if action == "forceSiege" then
				local raw = os.time() - serverStart
				local period = Config.siege.period
				local remainder = raw % period
				siegeForcedOffset = if remainder == 0 then period else period - remainder
				siegeForcedUntil = raw + Config.siege.duration
				broadcastSiege()
				return true
			elseif action == "saveReload" then
				local player = args[2]
				if typeof(player) ~= "Instance" or not player:IsA("Player") then
					return nil, "invalid player"
				end
				local profile = profiles[player]
				if profile == nil then
					return nil, "no profile"
				end
				local state = playerStates[player]
				if state == nil then
					return nil, "no state"
				end

				profile.data = Loop.toSave(Config, state, os.time())
				store:release(profile)
				profiles[player] = nil
				playerStates[player] = nil

				local reloaded, err = store:load(profileKey(player), migrate)
				if reloaded == nil then
					return nil, err
				end
				profiles[player] = reloaded
				local newState = Loop.fromSave(Config, reloaded.data, os.time())
				playerStates[player] = newState
				local reloadNow = os.time()
				local snapshot = Loop.snapshot(Config, newState, reloadNow, activeLuckMultiplier(reloadNow))
				StateChanged:FireClient(player, snapshot)
				return snapshot
			elseif action == "seedVault" then
				local teamName = args[2]
				local count = args[3]
				if typeof(teamName) ~= "string" or collectRaid:counts()[teamName] == nil then
					return false, "unknown team"
				end
				if typeof(count) ~= "number" or count % 1 ~= 0 or count < 0 then
					return false, "invalid count"
				end
				for _ = 1, count do
					collectRaid:collect(teamName, "seeded-egg", true)
				end
				broadcastSiege()
				return true, collectRaid:counts()[teamName]
			elseif action == "grantProduct" then
				local player = args[2]
				local productKey = args[3]
				local purchaseId = args[4]
				if typeof(player) ~= "Instance" or not player:IsA("Player") then
					return nil, "invalid player"
				end
				if type(productKey) ~= "string" then
					return nil, "invalid productKey"
				end
				if type(purchaseId) ~= "string" or purchaseId == "" then
					return nil, "invalid purchaseId"
				end
				local fakeId = debugProductIds[productKey] or UNKNOWN_DEBUG_PRODUCT_ID
				return handleReceipt({ PlayerId = player.UserId, ProductId = fakeId, PurchaseId = purchaseId })
			elseif action == "giveKaiju" then
				local player = args[2]
				local creatureId = args[3]
				local count = args[4]
				if typeof(player) ~= "Instance" or not player:IsA("Player") then
					return nil, "invalid player"
				end
				if type(creatureId) ~= "string" or Config.creatures[creatureId] == nil then
					return nil, "unknown creature id"
				end
				if typeof(count) ~= "number" or count % 1 ~= 0 or count < 1 then
					return nil, "invalid count"
				end
				local state = playerStates[player]
				if state == nil then
					return nil, "no state"
				end
				for _ = 1, count do
					table.insert(state.creatures, creatureId)
				end
				local giveNow = os.time()
				StateChanged:FireClient(player, Loop.snapshot(Config, state, giveNow, activeLuckMultiplier(giveNow)))
				return true
			elseif action == "sessionEnd" then
				local player = args[2]
				if typeof(player) ~= "Instance" or not player:IsA("Player") then
					return nil, "invalid player"
				end
				if playerStates[player] == nil then
					return nil, "no state"
				end
				endSession(player)
				return true
			elseif action == "setPass" then
				local player = args[2]
				local passKey = args[3]
				local owned = args[4]
				if typeof(player) ~= "Instance" or not player:IsA("Player") then
					return nil, "invalid player"
				end
				if type(passKey) ~= "string" then
					return nil, "invalid passKey"
				end
				if type(owned) ~= "boolean" then
					return nil, "invalid value"
				end
				local state = playerStates[player]
				if state == nil then
					return nil, "no state"
				end
				Loop.setPass(state, passKey, owned)
				saveProfile(player)
				local setPassNow = os.time()
				StateChanged:FireClient(
					player,
					Loop.snapshot(Config, state, setPassNow, activeLuckMultiplier(setPassNow))
				)
				return true
			elseif action == "tutorialState" then
				local player = args[2]
				if typeof(player) ~= "Instance" or not player:IsA("Player") then
					return nil, "invalid player"
				end
				local state = playerStates[player]
				if state == nil then
					return nil, "no state"
				end
				return Loop.tutorialStepId(state)
			elseif action == "analyticsCounts" then
				return analytics:counts()
			elseif action == "resetTutorial" then
				local player = args[2]
				if typeof(player) ~= "Instance" or not player:IsA("Player") then
					return nil, "invalid player"
				end
				local state = playerStates[player]
				if state == nil then
					return nil, "no state"
				end
				Loop.resetTutorial(Config, state)
				saveProfile(player)
				fireTutorialState(player, state)
				return true
			end

			return false, "unknown action"
		end
		debugFn.Parent = ServerStorage
		print(logPrefix .. "debug BindableFunction " .. opts.debugName .. " available (Studio)")
	end

	-- World interaction: ProximityPrompts on incubators and vaults call the same handlers as the HUD.
	local function addPrompt(parent: Instance, actionText: string, objectText: string, hold: number): ProximityPrompt
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = actionText
		prompt.ObjectText = objectText
		prompt.HoldDuration = hold
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = parent
		return prompt
	end
	for _, teamName in TEAM_NAMES do
		for i = 1, opts.incubatorsPerTeam do
			local incubator = World.incubator(teamName, i)
			local base = incubator and incubator.PrimaryPart
			if base then
				local prompt = addPrompt(base, Messages.incubatorActionText, Messages.incubatorObjectText(i), 0)
				prompt.Triggered:Connect(function(player: Player)
					local team: Team? = player.Team
					if team == nil or team.Name ~= teamName then
						Notify:FireClient(player, Messages.wrongTeamIncubator(teamName))
						return
					end
					local ok, result = hatchHandler(player, i)
					print(
						string.format(
							logPrefix .. "prompt hatch %s slot %d -> %s %s",
							player.Name,
							i,
							tostring(ok),
							tostring(result)
						)
					)
					if not ok then
						Notify:FireClient(player, Messages.hatchFailed(tostring(result)))
					end
				end)
			end
		end
		local vault = World.vault(teamName)
		local crate = vault and vault:FindFirstChildWhichIsA("BasePart")
		if crate then
			local prompt = addPrompt(crate, Messages.vaultActionText, Messages.vaultObjectText(teamName), 1.5)
			prompt.Triggered:Connect(function(player: Player)
				local team: Team? = player.Team
				if team == nil or team.Name == teamName then
					Notify:FireClient(player, Messages.raidOwnVault)
					return
				end
				local ok, result = raidHandler(player, teamName)
				print(
					string.format(
						logPrefix .. "prompt raid %s -> %s vault: %s %s",
						player.Name,
						teamName,
						tostring(ok),
						tostring(result)
					)
				)
				if not ok then
					Notify:FireClient(player, Messages.raidFailed(tostring(result)))
				end
			end)
		end
	end

	-- QA-only surface for Open Cloud Luau Execution (smoke scenarios, published,
	-- non-Studio place) and the Studio MCP playtest subagent (playtest scenarios).
	-- A BindableFunction (same pattern as opts.debugName above), not a `_G`
	-- global: `_G` is disallowed repo-wide (selene global_usage) and can't carry
	-- live closures across a require() boundary anyway. Available unconditionally
	-- (not Studio-gated): both callers already need privileged, authenticated
	-- access to run arbitrary server Luau, so exposing read state here adds no
	-- new attack surface reachable by an ordinary client. `seed` is the only
	-- mutator and only ever touches the QA player's own state.
	--
	-- execute_luau usage: `game.ServerStorage.ForgeQA:Invoke("get", "coins")`,
	-- `:Invoke("seed", { coins = 100 })`, `:Invoke("snapshot")`.
	local function forgeQaGet(key: string): any
		local state = qaState()
		if state == nil then
			return nil
		end
		if key == "schemaVersion" then
			-- The loaded profile's own persisted version, not the config constant:
			-- reading the constant would prove only that a QA player exists, never
			-- that the save schema actually loaded and was stamped by migration.
			local profile = qaPlayer ~= nil and profiles[qaPlayer] or nil
			if profile == nil or type(profile.data) ~= "table" or type(profile.data.version) ~= "number" then
				return nil
			end
			return profile.data.version
		elseif key == "owned" then
			return #state.creatures
		elseif key == "coins" then
			return state.wallet:balance(Config.currency)
		elseif key == "coinsPerSecond" then
			return Loop.coinsPerSecond(Config, state)
		elseif key == "baseCoinsPerSecond" then
			return Loop.baseCoinsPerSecond(Config, state)
		elseif key == "lastRaidMoved" then
			return qaLastRaidMoved
		elseif key == "lastCoinSnapshot" then
			return qaLastCoinSnapshot
		elseif key == "coins2xOwned" then
			return state.passes.coins2x == true
		end
		return nil
	end

	local function forgeQaSnapshot(): { owned: number, coins: number, vault: number }
		local state = qaState()
		if state == nil then
			return { owned = 0, coins = 0, vault = 0 }
		end
		return {
			owned = #state.creatures,
			coins = state.wallet:balance(Config.currency),
			vault = #state.vaultedCreatures,
		}
	end

	local function forgeQaSnapshotCoins(): number
		local state = qaState()
		qaLastCoinSnapshot = if state ~= nil then state.wallet:balance(Config.currency) else 0
		return qaLastCoinSnapshot
	end

	-- Deterministic state setter for smoke scenarios (see qa-scenarios/rejoin.yml):
	-- writes straight into the QA player's live state and persists it immediately
	-- so a follow-up `leave`/`rejoin` step round-trips through the real save path.
	local function forgeQaSeed(fields: { coins: number?, owned: number?, vault: number? }): ()
		local player = qaPlayer
		local state = qaState()
		if player == nil or state == nil then
			return
		end
		if fields.coins ~= nil then
			local delta = fields.coins - state.wallet:balance(Config.currency)
			if delta > 0 then
				state.wallet:credit(Config.currency, delta)
			elseif delta < 0 then
				state.wallet:debit(Config.currency, -delta)
			end
		end
		local fallbackCreatureId = Config.sourceOrder[1] and Config.sources[Config.sourceOrder[1]].pool[1].id or ""
		if fields.owned ~= nil then
			state.creatures = {}
			for _ = 1, fields.owned do
				table.insert(state.creatures, fallbackCreatureId)
			end
		end
		if fields.vault ~= nil then
			state.vaultedCreatures = {}
			for _ = 1, fields.vault do
				table.insert(state.vaultedCreatures, fallbackCreatureId)
			end
		end
		saveProfile(player)
	end

	-- The QA player's rival team, picked at runtime from whichever team they
	-- were actually assigned (see assignTeam/rivalOf above) instead of a
	-- hardcoded name: genre qa-scenarios are shared by every pack, and a pack
	-- can `forge plan --teams` with names other than the two-team "Blue"/"Red"
	-- template.
	local function forgeQaRivalTeam(): string?
		local player = qaPlayer
		if player == nil then
			return nil
		end
		local team: Team? = player.Team
		if team == nil then
			return nil
		end
		return rivalOf(team.Name)
	end

	-- Forces the siege window active immediately, same effect as the
	-- Studio-only debugName action, but reachable through the pack-independent
	-- ForgeQA surface so genre qa-scenarios do not need opts.debugName.
	local function forgeQaForceSiege(): boolean
		local raw = os.time() - serverStart
		local period = Config.siege.period
		local remainder = raw % period
		siegeForcedOffset = if remainder == 0 then period else period - remainder
		siegeForcedUntil = raw + Config.siege.duration
		broadcastSiege()
		return true
	end

	-- Seeds the QA player's rival team's vault with `count` raidable items,
	-- resolving the rival team at runtime instead of taking a team name from
	-- the caller, so genre qa-scenarios never hardcode a team.
	local function forgeQaSeedVault(count: number): (boolean, string?)
		local rivalName = forgeQaRivalTeam()
		if rivalName == nil then
			return false, "no rival team"
		end
		if type(count) ~= "number" or count % 1 ~= 0 or count < 0 then
			return false, "invalid count"
		end
		for _ = 1, count do
			collectRaid:collect(rivalName, "seeded-egg", true)
		end
		broadcastSiege()
		return true, nil
	end

	local forgeQaFn = Instance.new("BindableFunction")
	forgeQaFn.Name = "ForgeQA"
	forgeQaFn.OnInvoke = function(action: any, arg: any): any
		if action == "get" and type(arg) == "string" then
			return forgeQaGet(arg)
		elseif action == "snapshot" then
			return forgeQaSnapshot()
		elseif action == "snapshotCoins" then
			return forgeQaSnapshotCoins()
		elseif action == "seed" and type(arg) == "table" then
			forgeQaSeed(arg)
			return true
		elseif action == "tutorialState" then
			local state = qaState()
			if state == nil then
				return nil
			end
			return Loop.tutorialStepId(state)
		elseif action == "rivalTeam" then
			return forgeQaRivalTeam()
		elseif action == "forceSiege" then
			return forgeQaForceSiege()
		elseif action == "seedVault" and type(arg) == "number" then
			return forgeQaSeedVault(arg)
		end
		return nil
	end
	forgeQaFn.Parent = ServerStorage
end

return Server
