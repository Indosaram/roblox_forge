--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Forge = ReplicatedStorage:WaitForChild("Forge")
local Config = require(Forge.games["grow-and-defend-garden"].src.shared.Config)
local GrowHarvest = require(Forge.genres["grow-harvest"].module.GrowHarvest)
local SurvivalCoop = require(Forge.genres["survival-coop"].module.SurvivalCoop)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Plant = Remotes:WaitForChild("Plant") :: RemoteFunction
local BuySeed = Remotes:WaitForChild("BuySeed") :: RemoteFunction
local Harvest = Remotes:WaitForChild("Harvest") :: RemoteFunction
local Sell = Remotes:WaitForChild("Sell") :: RemoteFunction
local StateChanged = Remotes:WaitForChild("StateChanged") :: RemoteEvent

local states: { [Player]: any } = {}

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
		plots = plots,
		nextWaveIn = state.coop:secondsUntilNext(now),
		lastWave = state.lastWave,
	}
end

local function newState(player: Player)
	local state: any, coop: any
	local grow = GrowHarvest.new({
		crops = Config.crops,
		currency = Config.currency,
		startingBalance = Config.startingCoins,
		plotCount = Config.plotCount,
	}, {
		OnHarvest = function(context)
			state.harvested[context.cropId] = (state.harvested[context.cropId] or 0) + 1
			state.barricades += 1
		end,
	})
	coop = SurvivalCoop.new(Config.waves, {
		OnWaveSpawn = function(wave)
			local power = state.barricades
			state.barricades = 0
			coop:defend(wave.index, power)
		end,
		OnWaveResolved = function(resolution)
			state.lastWave = resolution
			if resolution.won then
				grow.wallet:credit(Config.currency, Config.winReward)
			end
		end,
	})
	state = { grow = grow, coop = coop, barricades = 0, harvested = {}, seeds = {}, lastWave = nil }
	states[player] = state
	StateChanged:FireClient(player, snapshot(state, os.time()))
end

Players.PlayerAdded:Connect(newState)
Players.PlayerRemoving:Connect(function(player: Player)
	states[player] = nil
end)
for _, player in Players:GetPlayers() do
	task.spawn(newState, player)
end

-- The seed shop is the first stage of the genre's loop (buy-seed -> plant -> harvest ->
-- sell-held), so a plot is never planted for free: a seed is bought with Coins and
-- consumed by the plant it enables. Both stages report their committed result to the
-- client, which is what the audio policy plays the genre's declared cue for.
BuySeed.OnServerInvoke = function(player: Player, cropId: any)
	local state = states[player]
	if state == nil or typeof(cropId) ~= "string" or Config.crops[cropId] == nil then
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
	if (state.seeds[cropId] or 0) <= 0 then
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
	if state == nil or typeof(plotIndex) ~= "number" then
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
		for player, state in states do
			state.coop:tick(now)
			StateChanged:FireClient(player, snapshot(state, now))
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
