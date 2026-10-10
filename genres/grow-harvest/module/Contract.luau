--!strict
local Shared = require("../../../core/domain/genre/Contract")
local Schema = require("../../../core/infra/net/Schema")
local Adapter = require("./Adapter")
local crop = Schema.string({ maxLen = 64, pattern = "^[a-z][a-z0-9%-]*$" })
local plot = Schema.number({ min = 1, max = 64, integer = true })
local function action(id: string, args: { Schema.Validator }): Shared.Action
	return { id = id, args = args, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } }
end
local contract: Shared.RuntimeContract = {
	api = 1,
	id = "grow-harvest",
	configVersion = 1,
	saveVersion = 1,
	actions = {
		action("buy-seed", { crop }),
		action("plant", { plot, crop }),
		action("harvest", { plot }),
		action("sell-held", { crop }),
	},
	events = { "OnPlant", "OnHarvest", "SeedBought", "CropSold" },
	hooks = { "OnPlant", "OnHarvest", "SeedBought", "CropSold" },
	validateConfig = Adapter.validateConfig,
	validateSave = Adapter.validateSave,
	create = function(config, services)
		return Adapter.create(config, services)
	end,
}
return contract
