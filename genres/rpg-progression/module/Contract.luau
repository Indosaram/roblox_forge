--!strict
local Types = require("../../../core/domain/genre/Contract")
local Schema = require("../../../core/infra/net/Schema")
local Adapter = require("./Adapter")
local names = { "OnBossSpawn", "OnBossDefeated", "QuestClaimed", "LevelChanged" }
local contract: Types.RuntimeContract = {
	api = 1,
	id = "rpg-progression",
	configVersion = 1,
	saveVersion = 1,
	actions = {
		{
			id = "strike-boss",
			args = { Schema.string({ maxLen = 64, pattern = "^[a-z][a-z0-9%-]*$" }) },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "claim-quest",
			args = { Schema.string({ maxLen = 64, pattern = "^[a-z][a-z0-9%-]*$" }) },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
	},
	events = names,
	hooks = table.clone(names),
	validateConfig = Adapter.validateConfig,
	validateSave = Adapter.validateSave,
	create = Adapter.create,
}
return contract
