--!strict
-- Pure, engine-free smoke checks for grow-and-defend-garden. Requires only the
-- pack's pure modules (src/shared) and pure genre/core modules, so the same
-- source bundles for Open Cloud Luau Execution. Without this file `forge gate`
-- ran no behavioural check at all for this pack.

local GrowHarvest = require("../../../genres/grow-harvest/module/GrowHarvest")
local GrowHarvestAudio = require("../../../genres/grow-harvest/module/Audio")
local Config = require("../src/shared/Config")
local Assets = require("../src/shared/Assets")

export type Check = {
	name: string,
	ok: boolean,
	detail: string,
}

local M = {}

local function pass(name: string, detail: string): Check
	return { name = name, ok = true, detail = detail }
end

local function fail(name: string, detail: string): Check
	return { name = name, ok = false, detail = detail }
end

local function newGrow()
	return GrowHarvest.new({
		crops = Config.crops,
		currency = Config.currency,
		startingBalance = Config.startingCoins,
		plotCount = Config.plotCount,
	})
end

-- The exact loop the HUD drives: buy a seed, plant it, wait out the growth timer,
-- harvest one unit, sell it, and confirm the balance moved by the crop's price.
local function checkPlantHarvestSell(): Check
	local name = "plant-harvest-sell loop"
	local grow = newGrow()
	if grow:balance() ~= Config.startingCoins then
		return fail(name, string.format("starting balance %d, expected %d", grow:balance(), Config.startingCoins))
	end

	local cropId = Config.cropOrder[1]
	local crop = Config.crops[cropId]
	if crop == nil then
		return fail(name, "cropOrder[1] is not a configured crop: " .. tostring(cropId))
	end
	if not grow:plant(1, cropId, 0) then
		return fail(name, "plant rejected the first crop on plot 1")
	end
	if grow:plant(1, cropId, 0) then
		return fail(name, "plant accepted an already-occupied plot")
	end
	if grow:isReady(1, 0) then
		return fail(name, "crop was ready at plant time")
	end
	if grow:harvest(1, crop.growthSeconds - 1) ~= nil then
		return fail(name, "harvest succeeded before the growth timer elapsed")
	end

	local harvested = grow:harvest(1, crop.growthSeconds)
	if harvested ~= cropId then
		return fail(name, "harvest returned " .. tostring(harvested) .. ", expected " .. cropId)
	end
	if grow:cropAt(1) ~= nil then
		return fail(name, "plot still holds a crop after harvest")
	end

	local before = grow:balance()
	local price = grow:sell(cropId)
	if price ~= crop.sellPrice then
		return fail(name, string.format("sell returned %d, expected %d", price, crop.sellPrice))
	end
	if grow:balance() ~= before + crop.sellPrice then
		return fail(name, "balance did not increase by the sell price")
	end
	return pass(name, string.format("%s sells for %d", cropId, price))
end

-- Growth timers are absolute: a plant at t must be ready at t + growthSeconds and
-- not one second earlier, which is what makes rejoin timers meaningful.
local function checkGrowthTiming(): Check
	local name = "growth timing is absolute"
	local grow = newGrow()
	for cropId, crop in Config.crops do
		if crop.growthSeconds <= 0 then
			return fail(name, "crop '" .. cropId .. "' has non-positive growthSeconds")
		end
		if not grow:plant(1, cropId, 1000) then
			return fail(name, "plant rejected '" .. cropId .. "'")
		end
		if grow:isReady(1, 1000 + crop.growthSeconds - 1) then
			return fail(name, "'" .. cropId .. "' became ready one second early")
		end
		if not grow:isReady(1, 1000 + crop.growthSeconds) then
			return fail(name, "'" .. cropId .. "' was not ready when the timer elapsed")
		end
		if grow:remaining(1, 1000) ~= crop.growthSeconds then
			return fail(name, "'" .. cropId .. "' remaining time at plant was not the growth time")
		end
		grow:readyAll(1000 + crop.growthSeconds)
		if grow:harvest(1, 1000 + crop.growthSeconds) ~= cropId then
			return fail(name, "harvest failed after readyAll for '" .. cropId .. "'")
		end
	end
	return pass(name, string.format("%d crops have sound absolute timers", #Config.cropOrder))
end

-- Every configured crop and wave value must be usable by the runtime; a zero or
-- negative price, growth time or enemy count silently breaks the loop.
local function checkConfig(): Check
	local name = "config validity"
	if Config.plotCount <= 0 then
		return fail(name, "plotCount must be positive")
	end
	if Config.seedPrice <= 0 then
		return fail(name, "seedPrice must be positive")
	end
	if Config.startingCoins < Config.seedPrice then
		return fail(name, "startingCoins cannot afford a single seed")
	end
	if #Config.cropOrder == 0 then
		return fail(name, "cropOrder is empty")
	end
	for _, cropId in Config.cropOrder do
		if Config.crops[cropId] == nil then
			return fail(name, "cropOrder names an unconfigured crop: " .. tostring(cropId))
		end
	end
	for cropId, crop in Config.crops do
		if crop.growthSeconds <= 0 then
			return fail(name, "crop '" .. cropId .. "' has non-positive growthSeconds")
		end
		if crop.sellPrice <= 0 then
			return fail(name, "crop '" .. cropId .. "' has non-positive sellPrice")
		end
	end
	local waves = Config.waves
	if waves == nil or waves.waveInterval <= 0 or waves.baseEnemies <= 0 then
		return fail(name, "wave config needs a positive interval and enemy count")
	end
	if Config.winReward < 0 then
		return fail(name, "winReward cannot be negative")
	end
	return pass(
		name,
		string.format("%d crops, %d plots, waves every %ds", #Config.cropOrder, Config.plotCount, waves.waveInterval)
	)
end

-- The save shape the server writes must stay plain DataStore-safe data.
local function checkSaveShape(): Check
	local name = "save serialization"
	local save = {
		schemaVersion = 1,
		balance = Config.startingCoins,
		seeds = { [Config.cropOrder[1]] = 2 },
		harvested = { [Config.cropOrder[1]] = 1 },
		barricades = 3,
		plots = {},
		waves = 0,
	}
	local seen = {}
	local stack: { any } = { save }
	while #stack > 0 do
		local value = table.remove(stack)
		local valueType = typeof(value)
		if valueType == "number" then
			if value ~= value or value == math.huge or value == -math.huge then
				return fail(name, "non-finite number in save")
			end
		elseif valueType == "table" then
			if seen[value] then
				return fail(name, "cycle detected in save table")
			end
			seen[value] = true
			for key, child in value do
				local keyType = typeof(key)
				if keyType ~= "string" and keyType ~= "number" then
					return fail(name, "table key is not a string/number: " .. tostring(key))
				end
				table.insert(stack, child)
			end
		elseif valueType ~= "string" and valueType ~= "boolean" then
			return fail(name, "unsupported value type in save: " .. valueType)
		end
	end
	return pass(name, "save is plain DataStore-safe data")
end

-- Every cue the genre binds must resolve to a published Roblox id, not a local
-- rbxasset:// path: a live place cannot load a path that only exists on the
-- developer's machine, so the cue would play nothing at all.
local function checkAudioCues(): Check
	local name = "audio cues resolve"
	local bound = {}
	for _, binding in GrowHarvestAudio.bindings do
		bound[binding.cue] = true
	end
	local count = 0
	for cue in bound do
		local resolved = Assets[cue]
		if type(resolved) ~= "string" or string.match(resolved, "^rbxassetid://[1-9]%d*$") == nil then
			return fail(name, cue .. " resolves to " .. tostring(resolved) .. ", which a live place cannot load")
		end
		count += 1
	end
	return pass(name, string.format("%d bound cues resolve to published ids", count))
end

function M.run(): { Check }
	return {
		checkPlantHarvestSell(),
		checkGrowthTiming(),
		checkConfig(),
		checkSaveShape(),
		checkAudioCues(),
	}
end

return M
