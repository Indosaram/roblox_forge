--!strict
local Adapter = require("./Adapter")
local config: Adapter.Config = {
	stats = { base = 10, exp = 1, pointsPerLevel = 1 },
	regions = {
		{ id = "meadow", name = "Meadow", requiredLevel = 1 },
		{ id = "ridge", name = "Ridge", requiredLevel = 2 },
	},
	schedules = {
		regions = {
			{ region = "meadow", interval = 2, bossIds = { "slime" } },
			{ region = "ridge", interval = 2, bossIds = { "golem" } },
		},
	},
	bosses = { slime = { health = 2, rewardXp = 10 }, golem = { health = 4, rewardXp = 20 } },
	strikeDamage = 1,
	startingBalance = 0,
	quests = {
		{
			id = "first-boss",
			requirements = { { kind = "defeat", target = "slime", count = 1 } },
			reward = { coins = 5, xp = 0 },
		},
	},
}
return config
