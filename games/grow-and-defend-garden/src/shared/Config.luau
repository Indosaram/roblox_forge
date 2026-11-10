--!strict
local EconConfig = require("./EconConfig")

export type CropConfig = { growthSeconds: number, sellPrice: number, defense: number }
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
		-- defense = barricade points one harvest contributes. It scales with the crop's
		-- time and price so upgrading the plot is the answer to the wave curve, instead
		-- of every crop being worth the same +1 and the wall arriving regardless.
		carrot = { growthSeconds = 20, sellPrice = 10, defense = 1 },
		pumpkin = { growthSeconds = 45, sellPrice = 30, defense = 3 },
		starfruit = { growthSeconds = 90, sellPrice = 80, defense = 7 },
	} :: { [string]: CropConfig },
	cropOrder = { "carrot", "pumpkin", "starfruit" } :: { string },
	waves = { waveInterval = 60, baseEnemies = 3, growth = 1 } :: WaveConfig,
}

return Config
