--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local Options = require("./Options")
local Session = require("./Session")
local MemoryBackend = require("../data/MemoryBackend")
local DataStoreBackend = require("../data/DataStoreBackend")
local Contract = require("../../domain/genre/Contract")
local Clock = require("./Clock")
local CommandTransport = require("./CommandTransport")
local OutfitPresenter = require("./OutfitPresenter")
local Rng = require("../../domain/random/Rng")
export type Options = Options.Options
export type ServerSession = Session.Session & { seed: number }
local M = {}
function M.start(options: Options): ServerSession
	Options.validate(options)
	local clock = options.clock or Clock.new(function()
		return DateTime.now().UnixTimestampMillis / 1000
	end)
	local seed = options.seed or math.floor(DateTime.now().UnixTimestampMillis)
	print("[forge] session seed", seed)
	local rng = Rng.new(seed)
	local jitter = rng:fork("join-retry")
	local session = Session.new(
		options,
		options.backend
			or (if RunService:IsStudio() then MemoryBackend.new() else DataStoreBackend.new(options.storeName)),
		{
			sessionId = game.JobId .. HttpService:GenerateGUID(false),
			lockTimeout = 120,
			retries = 3,
			wait = function(attempt)
				task.wait(math.min(2 ^ (attempt - 1), 16))
			end,
			now = function()
				return DateTime.now().UnixTimestampMillis / 1000
			end,
		},
		{
			encode = function(value)
				return HttpService:JSONEncode(value)
			end,
			survivalContent = if options.services then options.services.survivalContent else nil,
			survivalSpatial = if options.services then options.services.survivalSpatial else nil,
			survivalDeath = if options.services then options.services.survivalDeath else nil,
			survivalSettlement = if options.services then options.services.survivalSettlement else nil,
			survivalTransfer = if options.services then options.services.survivalTransfer else nil,
			survivalGathering = if options.services then options.services.survivalGathering else nil,
			survivalWildlife = if options.services then options.services.survivalWildlife else nil,
			survivalExtensions = if options.services then options.services.survivalExtensions else nil,
			now = function()
				return clock.now()
			end,
			roll = function()
				return rng:nextNumber()
			end,
			emit = function(_event) end,
		},
		options.durable
	)
	if options.lifecycle then
		options.lifecycle.bind(session)
	end
	assert(
		not ReplicatedStorage:FindFirstChild("ForgeAction") and not ReplicatedStorage:FindFirstChild("ForgeState"),
		"starter already bound"
	)
	local action = Instance.new("RemoteFunction")
	action.Name = "ForgeAction"
	local state = Instance.new("RemoteEvent")
	state.Name = "ForgeState"
	local signal: BindableEvent? = nil
	local revision = 0
	local function commandState(id: string): any
		if not options.durable then
			return nil
		end
		local epochs: { [string]: number? } = {}
		for _, actionId in options.durable.actions do
			epochs[actionId] = session.commandEpoch(id, actionId)
		end
		return { actions = options.durable.actions, sessionEpoch = session.commandEpoch(id), epochs = epochs }
	end
	-- Presentation bindings the spec declares (an outfit worn on a character), applied on the
	-- SERVER from each member's own authoritative snapshot so every client sees them. A nil spec
	-- declares nothing and the presenter is a no-op.
	local outfitBindings = OutfitPresenter.bindings(options.spec)
	local function snapshotFor(id: string): any
		local snapshot = session.snapshot(id)
		if #outfitBindings > 0 then
			local member = Players:GetPlayerByUserId(tonumber(id) :: number)
			if member ~= nil then
				OutfitPresenter.apply(member, snapshot, outfitBindings)
			end
		end
		return snapshot
	end
	local function roster(): { any }
		local out = {}
		for _, id in session.members() do
			local player = Players:GetPlayerByUserId(tonumber(id) :: number)
			if player then
				table.insert(out, { id = id, name = player.DisplayName })
			end
		end
		return out
	end
	local function packetFor(id: string, members: { any }): any
		return {
			snapshots = snapshotFor(id),
			roster = members,
			revision = revision,
			durable = commandState(id),
		}
	end
	local function push()
		revision += 1
		local members = session.members()
		local rosterList = roster()
		for _, player in Players:GetPlayers() do
			local id = tostring(player.UserId)
			if table.find(members, id) then
				state:FireClient(player, packetFor(id, rosterList))
			end
		end
		if signal then
			signal:Fire(revision)
		end
	end
	-- The no-argument handshake is a state request, not an action, so its reply goes only to the
	-- player who asked for it: pushing to every member let one client force whole-server snapshot
	-- and network work per call.
	local function pushTo(player: Player): ()
		local id = tostring(player.UserId)
		if not table.find(session.members(), id) then
			return
		end
		state:FireClient(player, packetFor(id, roster()))
	end
	local function dispatch(player: Player, id: any, args: any): (Contract.Result, any?)
		local ok, result, diagnostic =
			pcall(CommandTransport.invoke, session, options.durable, tostring(player.UserId), id, args)
		if not ok then
			warn("ForgeAction: " .. tostring(result))
			push() -- Hook failures are post-commit, not rollback.
			return { ok = false, reason = "server error: " .. tostring(result) }
		end
		if result.ok then
			push()
		end
		return result, diagnostic
	end
	-- A handshake is a per-player state request and is rate-limited in its own bucket, so a joined
	-- client cannot force repeated snapshot/network work outside the per-action limits.
	local HANDSHAKE_MIN_INTERVAL = 0.5
	local handshakeAt: { [string]: number } = {}
	action.OnServerInvoke = function(player, id, args)
		if id == nil and args == nil then
			local actor = tostring(player.UserId)
			if not table.find(session.members(), actor) then
				return { ok = false, reason = "profile not ready" }
			end
			local now = os.clock()
			local last = handshakeAt[actor]
			if last ~= nil and now - last < HANDSHAKE_MIN_INTERVAL then
				return { ok = false, reason = "RATE_LIMITED" }
			end
			handshakeAt[actor] = now
			pushTo(player)
			return { ok = true, durable = commandState(actor) }
		end
		return dispatch(player, id, args)
	end
	action.Parent, state.Parent = ReplicatedStorage, ReplicatedStorage
	if options.starterWorld ~= false then
		local world = Instance.new("Folder")
		world.Name = "ForgeStarter"
		local floor = Instance.new("Part")
		floor.Name, floor.Anchored, floor.Size, floor.Position =
			"Floor", true, Vector3.new(80, 1, 80), Vector3.new(0, -1, 0)
		floor.Parent = world
		local spawn = Instance.new("SpawnLocation")
		spawn.Anchored, spawn.Size, spawn.Position = true, Vector3.new(6, 1, 6), Vector3.new(0, 1, 0)
		spawn.Parent = world
		for index, control in options.controls do
			if control.kind ~= "prompt" then
				continue
			end
			local station = Instance.new("Part")
			station.Name, station.Anchored, station.Size = control.id, true, Vector3.new(4, 3, 4)
			station.Position = Vector3.new((index % 8) * 7 - 25, 1, -12)
			station.Parent = world
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name, prompt.ActionText, prompt.ObjectText = control.id, control.label, control.id
			prompt.Parent = station
			if CommandTransport.durable(options.durable, control.action) then
				-- The client owns request identity for durable prompt retries.
				continue
			end
			prompt.Triggered:Connect(function(player)
				local result = dispatch(player, control.action, control.args)
				state:FireClient(player, { result = result, control = control.id })
			end)
		end
		world.Parent = workspace
	end
	if RunService:IsStudio() then
		assert(not ServerStorage:FindFirstChild("ForgeQA"), "ForgeQA already exists")
		local qa = Instance.new("Folder")
		qa.Name = "ForgeQA"
		local changed = Instance.new("BindableEvent")
		changed.Name, changed.Parent = "StateChanged", qa
		signal = changed
		local function bind(name: string, callback: (...any) -> ...any)
			local fn = Instance.new("BindableFunction")
			fn.Name, fn.OnInvoke, fn.Parent = name, callback, qa
		end
		bind("dispatch", function(genre: string, id: string, args: { any }, playerId: string)
			local result = CommandTransport.invoke(session, options.durable, playerId, genre .. ":" .. id, args)
			if result.ok then
				push()
			end
			return result
		end)
		bind("snapshot", function(genre: string, playerId: string)
			return session.snapshot(playerId)[genre]
		end)
		bind("commandServer", function(playerId: string, requestId: string, actionId: string, args: { any })
			if not options.durable or not table.find(options.durable.serverActions or {}, actionId) then
				return { ok = false, reason = "UNDECLARED_SERVER_COMMAND" }
			end
			local result = session.commandServer(playerId, {
				requestId = requestId,
				sessionEpoch = session.commandEpoch(playerId, actionId),
				action = actionId,
				args = args,
			})
			if result.ok then
				push()
			end
			return result
		end)
		bind("advanceTo", function(value: number)
			session.advance(clock.advanceTo(value))
			push()
			return revision
		end)
		bind("beginClock", function()
			return clock.begin()
		end)
		bind("revision", function()
			return revision
		end)
		bind("advanceElapsed", function(value: number)
			session.advance(clock.advanceElapsed(value))
			push()
			return revision
		end)
		bind("save", function(playerId: string)
			local result = session.save(playerId)
			return result, if result.ok then session.envelope(playerId) else nil
		end)
		bind("restore", function(playerId: string, saved: any)
			local result = session.restore(playerId, saved)
			if result.ok then
				push()
			end
			return result
		end)
		qa.Parent = ServerStorage
	end
	local pending: { [string]: boolean? } = {}
	-- Player-facing kick text: never an internal reason code (p134 v22 D3). The internal
	-- reason stays in the ForgeLastKick attribute and the warn() log.
	local function kickText(player: Player, reason: any): string
		local ok, locale = pcall(function(): string
			return (player :: any).LocaleId
		end)
		local ko = ok and type(locale) == "string" and string.sub(locale, 1, 2) == "ko"
		if reason == "profile already active/loading" or reason == "locked" then
			return if ko
				then "이전 접속의 저장을 마무리하는 중이에요. 잠시 후 다시 접속해 주세요."
				else "Your save is still closing from your last session. Please rejoin in a moment."
		end
		return if ko
			then "저장 데이터를 불러오지 못했어요. 잠시 후 다시 접속해 주세요."
			else "We couldn't load your save. Please rejoin in a moment."
	end
	local function close(id: string)
		local result = session.close(id)
		pending[id] = if result.ok or result.released then nil else true
		if result.notificationError then
			warn("Forge departure notification " .. id .. ": " .. result.notificationError)
		end
		if not result.ok then
			warn("Forge profile release " .. id .. ": " .. tostring(result.reason))
		end
	end
	local function join(player: Player)
		local id = tostring(player.UserId)
		-- A predecessor's durable locks can still cover this profile right after a
		-- physical replacement, and a burst of simultaneous joins can transiently
		-- outrun the local transport while the host is healthy before and after.
		-- Wait both out, with jittered retries so the same burst cannot re-synchronize,
		-- instead of kicking a player who would otherwise load on the next attempt.
		local function retryable(reason: any): boolean
			return reason == "locked"
				-- Same-server rejoin while this server still closes the previous session
				-- (force-quit then relaunch, p134 v22 D3): wait for that close to finish.
				or reason == "profile already active/loading"
				or reason == "LOCAL_TRANSPORT_UNAVAILABLE"
				or reason == "LOCAL_HTTP_429"
				or (type(reason) == "string" and string.sub(reason, 1, 12) == "LOCAL_HTTP_5")
		end
		-- A previous session's close that failed is retried here first: joining must never
		-- leave the old close pending, or the heartbeat retry would close the NEW session and
		-- refuse every action it sends (p134 v22 D6).
		local function attempt(): any
			if pending[id] then
				close(id)
			end
			if pending[id] then
				return { ok = false, reason = "profile already active/loading" }
			end
			return session.join(id)
		end
		local retryDeadline = os.clock() + 90
		local result = attempt()
		while not result.ok and retryable(result.reason) and os.clock() < retryDeadline and player.Parent == Players do
			task.wait(1 + jitter:nextNumber() * 3)
			result = attempt()
		end
		if result.notificationError then
			warn("Forge join notification " .. id .. ": " .. result.notificationError)
		end
		if not result.ok then
			-- Surface the kick reason where the QA harness can read it back after
			-- the client window disappears (Studio log capture is not reliable).
			ServerStorage:SetAttribute("ForgeLastKick", id .. " " .. tostring(result.reason))
			warn("Forge profile load " .. id .. ": " .. tostring(result.reason))
			close(id)
			player:Kick(kickText(player, result.reason))
			return
		end
		if player.Parent ~= Players then
			close(id)
		else
			push()
		end
	end
	Players.PlayerAdded:Connect(join)
	Players.PlayerRemoving:Connect(function(player)
		close(tostring(player.UserId))
		handshakeAt[tostring(player.UserId)] = nil
		push()
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(join, player)
	end
	local accumulator, saves = 0, 0
	-- Each Heartbeat runs in its own thread and a live DataStore call yields for seconds when the
	-- per-key queue backs up: without this guard every second started another overlapping tick,
	-- whose recovery sweeps kept the profile busy so every action and the 30 s save were refused
	-- (p134 v22 D6). A tick that is still running absorbs the elapsed time of skipped frames.
	local ticking = false
	RunService.Heartbeat:Connect(function(delta)
		accumulator += delta
		if accumulator < 1 or ticking then
			return
		end
		ticking = true
		local elapsed = math.floor(accumulator)
		accumulator -= elapsed
		local ok, err = pcall(function()
			session.advance(clock.now())
			push()
		end)
		if not ok then
			warn("Forge heartbeat: " .. tostring(err))
		end
		local settled, failure = pcall(function()
			for id in pending do
				-- A member present on this server rejoined: its join loop owns the old close.
				local userId = tonumber(id)
				if userId == nil or Players:GetPlayerByUserId(userId) == nil then
					close(id)
				end
			end
			saves += elapsed
			if saves >= 30 then
				saves %= 30
				for _, id in session.members() do
					local result = session.save(id)
					if not result.ok then
						warn("Forge profile save " .. id .. ": " .. tostring(result.reason))
					end
				end
			end
		end)
		ticking = false
		if not settled then
			warn("Forge heartbeat: " .. tostring(failure))
		end
	end)
	game:BindToClose(function()
		for _, id in session.members() do
			close(id)
		end
		for id in pending do
			close(id)
		end
		if options.lifecycle then
			local result = options.lifecycle.close()
			if not result.ok then
				warn("Forge resource release: " .. tostring(result.reason))
			end
		end
	end)
	local seeded: any = session
	seeded.seed = seed
	return seeded :: ServerSession
end
return M
