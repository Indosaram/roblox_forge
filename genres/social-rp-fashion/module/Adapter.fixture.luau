--!strict
local Adapter = require("./Adapter")
local config: Adapter.Config = {
	round = { minPlayers = 2, dressingSeconds = 2, votingSeconds = 2, resultsSeconds = 1 },
	themes = { "garden", "space" },
	catalog = { { id = "starter-hat", slot = "hat" }, { id = "starter-top", slot = "top" } },
	startingOwned = { "starter-hat", "starter-top" },
	resultReward = 5,
}
return config
