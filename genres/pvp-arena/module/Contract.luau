--!strict
local Types = require("../../../core/domain/genre/Contract")
local Adapter = require("./Adapter")
local contract: Types.RuntimeContract = {
	api = 1,
	id = "pvp-arena",
	configVersion = 1,
	saveVersion = 1,
	actions = {
		{ id = "enqueue", args = {}, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "attack", args = {}, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
	},
	events = { "OnRoundStart", "OnRoundEnd", "MatchSettled" },
	hooks = { "OnRoundStart", "OnRoundEnd", "MatchSettled" },
	validateConfig = Adapter.validateConfig,
	validateSave = Adapter.validateSave,
	create = Adapter.create,
}
return contract
