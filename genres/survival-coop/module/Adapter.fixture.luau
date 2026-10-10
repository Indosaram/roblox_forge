--!strict
local Adapter = require("./Adapter")
local config: Adapter.Config = {
	currency = "Coins",
	waveInterval = 2,
	baseEnemies = 3,
	growth = 1,
	baseDefense = 1,
	upgradeCost = 10,
	upgradePower = 3,
	winReward = 5,
	startingBalance = 10,
}
return { config = config }
