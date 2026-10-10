--!strict
local Types = require("../../../core/domain/genre/Contract")
local Schema = require("../../../core/infra/net/Schema")
local Adapter = require("./Adapter")
local contract: Types.RuntimeContract = {
	api = 1,
	id = "social-rp-fashion",
	configVersion = 1,
	saveVersion = 1,
	actions = {
		{
			id = "equip",
			args = { Schema.string({ maxLen = 64 }) },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "vote",
			args = { Schema.string({ maxLen = 128 }), Schema.number({ min = 1, max = 5, integer = true }) },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
	},
	events = { "OnThemeStart", "OnResults", "OutfitEquipped", "VoteCast" },
	hooks = { "OnThemeStart", "OnResults", "OutfitEquipped", "VoteCast" },
	validateConfig = Adapter.validateConfig,
	validateSave = Adapter.validateSave,
	create = Adapter.create,
}
return contract
