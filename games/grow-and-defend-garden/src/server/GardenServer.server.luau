--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Forge = ReplicatedStorage:WaitForChild("Forge")
local Config = require(Forge.games["grow-and-defend-garden"].src.shared.Config)
local GrowHarvest = require(Forge.genres["grow-harvest"].module.GrowHarvest)
local SurvivalCoop = require(Forge.genres["survival-coop"].module.SurvivalCoop)
local ProfileStore = require(Forge.core.infra.data.ProfileStore)
local RuntimeBackend = require(Forge.core.infra.data.RuntimeBackend)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Plant = Remotes:WaitForChild("Plant") :: RemoteFunction
local BuySeed = Remotes:WaitForChild("BuySeed") :: RemoteFunction
local Harvest = Remotes:WaitForChild("Harvest") :: RemoteFunction
local Sell = Remotes:WaitForChild("Sell") :: RemoteFunction
local StateChanged = Remotes:WaitForChild("StateChanged") :: RemoteEvent

local states: { [Player]: any } = {}
local profiles: { [Player]: any } = {}
local loading: { [Player]: boolean } = {}

-- Save schema revision. A stored revision that is not this one is discarded and
-- replaced with a fresh save rather than decoded against the wrong shape.
local SCHEMA_VERSION = 1
-- Every autosave renews the profile lock, so the lock timeout must stay above
-- two autosave intervals or a live session could be taken over mid-play.
local SAVE_INTERVAL_SECONDS = 60

-- Remotes are client-callable and can arrive faster than a player can act, so each
-- player gets the genre contract's token bucket (5 actions / 2 s) here as well.
local RATE_CAPACITY, RATE_REFILL = 5, 2.5

local store = ProfileStore.new(RuntimeBackend.new(require(script.Parent.PersistenceConfig), "GrowAndDefendGarden"), {
	sessionId = if game.JobId ~= "" then game.JobId else "studio-" .. tostring(os.time()),
	lockTimeout = 2 * SAVE_INTERVAL_SECONDS,
	retries = 3,
	-- ProfileStore's default backoff is a no-op so it stays runnable under Lune;
	-- production has to inject the delay or a throttle is retried back to back.
	wait = function(attempt: number)
		task.wait(math.min(2 ^ (attempt - 1), 16))
	end,
	now = function(): number
		return os.time()
	end,
})

local function allowAction(state: any, now: number): boolean
	state.tokens = math.min(RATE_CAPACITY, state.tokens + (now - state.lastAction) * RATE_REFILL)
	state.lastAction = now
	if state.tokens < 1 then
		return false
	end
	state.tokens -= 1
	return true
end

local function snapshot(state: any, now: number)
	local plots = {}
	for index = 1, Config.plotCount do
		plots[index] = {
			cropId = state.grow:cropAt(index),
			ready = state.grow:isReady(index, now),
			remaining = state.grow:remaining(index, now),
		}
	end
	return {
		coins = state.grow:balance(),
		barricades = state.barricades,
		seeds = state.seeds,
		-- Held (harvested, unsold) crops: the Sell button sells from here, never from a
		-- plot, and the client needs the counts to know what is sellable.
		harvested = state.harvested,
		plots = plots,
		nextWaveIn = state.coop:secondsUntilNext(now),
		lastWave = state.lastWave,
	}
end

local function freshSave(): any
	return {
		schemaVersion = SCHEMA_VERSION,
		balance = Config.startingCoins,
		seeds = {},
		harvested = {},
		barricades = 0,
		plots = {},
		waves = 0,
		lastWave = nil,
	}
end

local function isCount(value: any): boolean
	return type(value) == "number" and value >= 0 and value <= 1e9 and value % 1 == 0
end

-- Crop-keyed counters, dropping entries this build has no crop for.
local function counts(raw: any): { [string]: number }
	local result: { [string]: number } = {}
	if type(raw) ~= "table" then
		return result
	end
	for cropId, value in raw do
		if Config.crops[cropId] ~= nil and isCount(value) and value > 0 then
			result[cropId] = value
		end
	end
	return result
end

-- Plots are stored with the absolute os.time() they were planted at, so the
-- remaining growth survives a rejoin without any engine-relative bookkeeping.
local function plantedPlots(raw: any, now: number): { any }
	local result = {}
	if type(raw) ~= "table" then
		return result
	end
	local used: { [number]: boolean } = {}
	for _, entry in raw do
		if type(entry) == "table" then
			local plot, cropId, plantedAt = entry.plot, entry.cropId, entry.plantedAt
			if
				type(plot) == "number"
				and plot % 1 == 0
				and plot >= 1
				and plot <= Config.plotCount
				and not used[plot]
				and type(cropId) == "string"
				and Config.crops[cropId] ~= nil
				and type(plantedAt) == "number"
				and plantedAt % 1 == 0
				and plantedAt > 0
				and plantedAt <= now
			then
				used[plot] = true
				table.insert(result, { plot = plot, cropId = cropId, plantedAt = plantedAt })
			end
		end
	end
	table.sort(result, function(a, b)
		return a.plot < b.plot
	end)
	return result
end

local function lastWave(raw: any): any?
	if type(raw) ~= "table" or type(raw.won) ~= "boolean" then
		return nil
	end
	if not isCount(raw.index) or raw.index < 1 or not isCount(raw.enemies) or not isCount(raw.defensePower) then
		return nil
	end
	return { index = raw.index, enemies = raw.enemies, defensePower = raw.defensePower, won = raw.won }
end

-- Returns a save this build can load plus a note when anything was reset. Never
-- raises: a corrupt or outdated save degrades to defaults instead of blocking play.
local function sanitize(raw: any, now: number): (any, string?)
	local save = freshSave()
	if raw == nil then
		return save, nil
	end
	if type(raw) ~= "table" then
		return save, "save is not a table"
	end
	if raw.schemaVersion ~= SCHEMA_VERSION then
		return save, string.format("unsupported schemaVersion %s", tostring(raw.schemaVersion))
	end
	local note: string? = nil
	if isCount(raw.balance) then
		save.balance = raw.balance
	else
		note = "invalid balance"
	end
	if isCount(raw.barricades) then
		save.barricades = raw.barricades
	else
		note = note or "invalid barricades"
	end
	-- Bounded so a corrupt/huge value cannot make restore loop for minutes.
	if isCount(raw.waves) and raw.waves <= 10000 then
		save.waves = raw.waves
	end
	save.seeds = counts(raw.seeds)
	save.harvested = counts(raw.harvested)
	save.plots = plantedPlots(raw.plots, now)
	save.lastWave = lastWave(raw.lastWave)
	return save, note
end

local function toSave(state: any, now: number): any
	local plots = {}
	for index = 1, Config.plotCount do
		local cropId = state.grow:cropAt(index)
		if cropId ~= nil then
			local crop = Config.crops[cropId]
			-- plantedAt = readyAt - growthSeconds, and remaining = max(0, readyAt - now).
			-- A crop that is already ready keeps remaining 0 and stays ready on load.
			local remaining = state.grow:remaining(index, now)
			table.insert(plots, {
				plot = index,
				cropId = cropId,
				plantedAt = now + remaining - crop.growthSeconds,
			})
		end
	end
	return {
		schemaVersion = SCHEMA_VERSION,
		balance = state.grow:balance(),
		seeds = table.clone(state.seeds),
		harvested = table.clone(state.harvested),
		barricades = state.barricades,
		plots = plots,
		waves = state.coop:waveIndex(),
		lastWave = if state.lastWave ~= nil then table.clone(state.lastWave) else nil,
	}
end

-- Re-arms the wave cadence at the saved index. SurvivalCoop only exposes tick,
-- so the index is advanced by back-dating the schedule: each tick lands inside its
-- own interval, and the last one leaves nextWaveAt exactly one interval out.
-- The spawn hook is muted meanwhile, or restoring would spend live barricades.
local function restoreWaves(state: any, waves: number, now: number)
	local interval = Config.waves.waveInterval
	local start = now - waves * interval
	state.restoring = true
	for step = 0, waves do
		state.coop:tick(start + step * interval)
	end
	state.restoring = false
end

local function newState(player: Player, saved: any)
	local state: any, coop: any
	local grow = GrowHarvest.new({
		crops = Config.crops,
		currency = Config.currency,
		startingBalance = saved.balance,
		plotCount = Config.plotCount,
	}, {
		OnHarvest = function(context)
			state.harvested[context.cropId] = (state.harvested[context.cropId] or 0) + 1
			state.barricades += 1
		end,
	})
	coop = SurvivalCoop.new(Config.waves, {
		OnWaveSpawn = function(wave)
			if state.restoring then
				return
			end
			-- Spend only what the wave actually needs; the surplus stays banked. Zeroing
			-- the whole stockpile destroyed player progress every wave.
			local needed = wave.enemies
			local power = math.min(state.barricades, needed)
			state.barricades -= power
			coop:defend(wave.index, power)
		end,
		OnWaveResolved = function(resolution)
			state.lastWave = resolution
			if resolution.won then
				grow.wallet:credit(Config.currency, Config.winReward)
			end
		end,
	})
	state = {
		grow = grow,
		coop = coop,
		barricades = saved.barricades,
		harvested = table.clone(saved.harvested),
		seeds = table.clone(saved.seeds),
		lastWave = saved.lastWave,
		tokens = RATE_CAPACITY,
		lastAction = 0,
		-- True only while the saved wave index is replayed; see restoreWaves.
		restoring = false,
	}
	for _, planted in saved.plots do
		assert(grow:plant(planted.plot, planted.cropId, planted.plantedAt), "saved plot was validated")
	end
	restoreWaves(state, saved.waves, os.time())
	states[player] = state
	StateChanged:FireClient(player, snapshot(state, os.time()))
end

local function profileKey(player: Player): string
	return "player_" .. tostring(player.UserId)
end

local function savePlayer(player: Player): boolean
	local profile = profiles[player]
	local state = states[player]
	if profile == nil or state == nil then
		return false
	end
	profile.data = toSave(state, os.time())
	local ok, err = store:save(profile)
	if not ok then
		warn(string.format("GardenServer save failed for %s: %s", player.Name, tostring(err)))
	end
	return ok
end

-- PlayerAdded can fire for a player the GetPlayers() sweep below already handled,
-- which used to build a second state and wipe the first. `loading` covers the
-- store:load yield, during which no state exists yet.
local function onPlayerAdded(player: Player)
	if states[player] ~= nil or loading[player] then
		return
	end
	loading[player] = true
	local note: string? = nil
	local profile, err = store:load(profileKey(player), function(raw: any): any
		local save, problem = sanitize(raw, os.time())
		note = problem
		return save
	end)
	loading[player] = nil
	-- The player may have disconnected while store:load was yielding. Release the
	-- lock instead of leaking a session whose PlayerRemoving already ran.
	if player.Parent ~= Players then
		if profile ~= nil then
			store:release(profile)
		end
		return
	end
	if profile == nil then
		warn(string.format("GardenServer load failed for %s: %s", player.Name, tostring(err)))
		newState(player, freshSave())
		return
	end
	if note ~= nil then
		warn(string.format("GardenServer reset save for %s: %s", player.Name, note))
	end
	profiles[player] = profile
	newState(player, profile.data)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player: Player)
	savePlayer(player)
	local profile = profiles[player]
	if profile ~= nil then
		store:release(profile)
	end
	profiles[player] = nil
	states[player] = nil
	loading[player] = nil
end)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

-- Saves may still be in flight when a server shuts down, and PlayerRemoving is
-- not guaranteed there. Save and release explicitly so a restart keeps progress.
game:BindToClose(function()
	for player in profiles do
		savePlayer(player)
	end
	for _, profile in profiles do
		store:release(profile)
	end
end)

-- The seed shop is the first stage of the genre's loop (buy-seed -> plant -> harvest ->
-- sell-held), so a plot is never planted for free: a seed is bought with Coins and
-- consumed by the plant it enables. Both stages report their committed result to the
-- client, which is what the audio policy plays the genre's declared cue for.
BuySeed.OnServerInvoke = function(player: Player, cropId: any)
	local state = states[player]
	if state == nil or typeof(cropId) ~= "string" or Config.crops[cropId] == nil then
		return false
	end
	if not allowAction(state, os.time()) then
		return false
	end
	if not state.grow.wallet:canAfford(Config.currency, Config.seedPrice) then
		return false
	end
	assert(state.grow.wallet:debit(Config.currency, Config.seedPrice), "affordability was checked above")
	state.seeds[cropId] = (state.seeds[cropId] or 0) + 1
	StateChanged:FireClient(player, snapshot(state, os.time()))
	return true
end

Plant.OnServerInvoke = function(player: Player, plotIndex: any, cropId: any)
	local state = states[player]
	if state == nil or typeof(plotIndex) ~= "number" or typeof(cropId) ~= "string" then
		return false
	end
	if (state.seeds[cropId] or 0) <= 0 or not allowAction(state, os.time()) then
		return false
	end
	local planted = state.grow:plant(plotIndex, cropId, os.time())
	if planted then
		state.seeds[cropId] -= 1
	end
	StateChanged:FireClient(player, snapshot(state, os.time()))
	return planted
end

Harvest.OnServerInvoke = function(player: Player, plotIndex: any)
	local state = states[player]
	if state == nil or typeof(plotIndex) ~= "number" or not allowAction(state, os.time()) then
		return nil
	end
	local cropId = state.grow:harvest(plotIndex, os.time())
	StateChanged:FireClient(player, snapshot(state, os.time()))
	return cropId
end

Sell.OnServerInvoke = function(player: Player, cropId: any)
	local state = states[player]
	if state == nil or typeof(cropId) ~= "string" or (state.harvested[cropId] or 0) <= 0 then
		return 0
	end
	if not allowAction(state, os.time()) then
		return 0
	end
	state.harvested[cropId] -= 1
	local price = state.grow:sell(cropId)
	StateChanged:FireClient(player, snapshot(state, os.time()))
	return price
end

local secondAccumulator = 0
RunService.Heartbeat:Connect(function(dt: number)
	secondAccumulator += dt
	while secondAccumulator >= 1 do
		secondAccumulator -= 1
		local now = os.time()
		for _, state in states do
			state.coop:tick(now)
		end
	end
end)

-- The per-second broadcast is a full snapshot (plots, seeds, wave clock). Sending it
-- once per second to every player, plus once per action, wasted bandwidth; 2 s keeps
-- countdowns readable and halves the traffic.
local snapshotAccumulator = 0
RunService.Heartbeat:Connect(function(dt: number)
	snapshotAccumulator += dt
	if snapshotAccumulator >= 2 then
		snapshotAccumulator -= 2
		local now = os.time()
		for player, state in states do
			StateChanged:FireClient(player, snapshot(state, now))
		end
	end
end)

local saveAccumulator = 0
RunService.Heartbeat:Connect(function(dt: number)
	saveAccumulator += dt
	if saveAccumulator >= SAVE_INTERVAL_SECONDS then
		saveAccumulator -= SAVE_INTERVAL_SECONDS
		for player in profiles do
			savePlayer(player)
		end
	end
end)

if RunService:IsStudio() then
	local debugFn = Instance.new("BindableFunction")
	debugFn.Name = "GardenDebug"
	debugFn.OnInvoke = function(action: any): any
		local now = os.time()
		for _, state in states do
			if action == "forceWave" then
				state.coop:forceNext(now)
			elseif action == "growAll" then
				state.grow:readyAll(now)
			end
		end
		return action == "forceWave" or action == "growAll"
	end
	debugFn.Parent = ServerStorage
end
