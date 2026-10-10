--!strict
local EconConfig = require("./EconConfig")

export type CropConfig = { growthSeconds: number, sellPrice: number }
export type WaveConfig = { waveInterval: number, baseEnemies: number, growth: number }

local Config = {
	currency = EconConfig.currency,
	startingCoins = EconConfig.startingCoins,
	plotCount = 3,
	winReward = 25,
	-- One Coin per seed, the price the genre's own buy-seed effect declares
	-- (`{ path = [balance], delta = -1 }` in genres/grow-harvest/genre-spec.yml).
	-- The pack's loop is the genre's loop: buy a seed, plant it, harvest, sell.
	seedPrice = 1,
	crops = {
		carrot = { growthSeconds = 20, sellPrice = 10 },
		pumpkin = { growthSeconds = 45, sellPrice = 30 },
		starfruit = { growthSeconds = 90, sellPrice = 80 },
	} :: { [string]: CropConfig },
	cropOrder = { "carrot", "pumpkin", "starfruit" } :: { string },
	waves = { waveInterval = 60, baseEnemies = 3, growth = 2 } :: WaveConfig,
}

return Config
