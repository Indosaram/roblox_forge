--!strict
-- Drift guard: Config.luau duplicates values that econ.yml declares. The two are
-- kept equal by this spec; change both together.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Config = require("./Config")

local ECON_PATH = "games/grow-and-defend-garden/econ.yml"

local function loadEcon(): any
	return serde.decode("yaml", fs.readFile(ECON_PATH))
end

return {
	["Config.startingCoins equals econ.yml currencies[1].starting"] = function()
		local econ = loadEcon()
		assert(
			Config.startingCoins == econ.currencies[1].starting,
			"startingCoins drift: Config="
				.. tostring(Config.startingCoins)
				.. " econ.yml="
				.. tostring(econ.currencies[1].starting)
		)
	end,

	["Config.crops equals econ.yml crops for every crop"] = function()
		local econ = loadEcon()
		local seen = 0
		for _, crop in econ.crops do
			seen += 1
			local config = Config.crops[crop.id]
			assert(config ~= nil, "Config.crops is missing econ.yml crop " .. tostring(crop.id))
			assert(
				config.growthSeconds == crop.growthSeconds,
				"growthSeconds drift for "
					.. crop.id
					.. ": Config="
					.. tostring(config.growthSeconds)
					.. " econ.yml="
					.. tostring(crop.growthSeconds)
			)
			assert(
				config.sellPrice == crop.sellPrice,
				"sellPrice drift for "
					.. crop.id
					.. ": Config="
					.. tostring(config.sellPrice)
					.. " econ.yml="
					.. tostring(crop.sellPrice)
			)
		end
		local configCount = 0
		for _ in Config.crops do
			configCount += 1
		end
		assert(configCount == seen, "Config.crops has " .. configCount .. " crops, econ.yml has " .. seen)
	end,

	["Config.cropOrder equals the econ.yml crop order"] = function()
		local econ = loadEcon()
		assert(
			#Config.cropOrder == #econ.crops,
			"cropOrder length drift: Config=" .. #Config.cropOrder .. " econ.yml=" .. #econ.crops
		)
		for index, crop in econ.crops do
			assert(
				Config.cropOrder[index] == crop.id,
				"cropOrder["
					.. index
					.. "] drift: Config="
					.. tostring(Config.cropOrder[index])
					.. " econ.yml="
					.. tostring(crop.id)
			)
		end
	end,

	["Config.waves equals econ.yml waves"] = function()
		local waves = loadEcon().waves
		for _, key in { "waveInterval", "baseEnemies", "growth" } do
			local expected = waves[key]
			local actual = (Config.waves :: any)[key]
			assert(type(expected) == "number", "econ.yml waves." .. key .. " must be a number")
			assert(
				actual == expected,
				"waves." .. key .. " drift: Config=" .. tostring(actual) .. " econ.yml=" .. tostring(expected)
			)
		end
	end,

	["Config.winReward equals econ.yml waves.winReward"] = function()
		local winReward = loadEcon().waves.winReward
		assert(
			Config.winReward == winReward,
			"winReward drift: Config=" .. tostring(Config.winReward) .. " econ.yml=" .. tostring(winReward)
		)
	end,
}
