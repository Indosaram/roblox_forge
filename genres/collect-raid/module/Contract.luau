--!strict
local Types = require("../../../core/domain/genre/Contract")
local Schema = require("../../../core/infra/net/Schema")
local Adapter = require("./Adapter")
local function action(id: string, args: { Schema.Validator }, origin: "client" | "server"): Types.Action
	return {
		id = id,
		args = args,
		origin = origin,
		rate = if origin == "server"
			then { capacity = 100, refillPerSecond = 100 }
			else { capacity = 5, refillPerSecond = 2 },
	}
end
local identifier = Schema.string({ maxLen = 64 })
local index = Schema.number({ min = 1, max = 64, integer = true })
local events = { "OnCollect", "OnRaid", "OnSiegePhase", "SourceBought", "Hatched", "Merged", "QuestClaimed" }
local contract: Types.RuntimeContract = {
	api = 1,
	id = "collect-raid",
	configVersion = 1,
	saveVersion = 1,
	actions = {
		action("buy-source", { identifier }, "client"),
		action("hatch", { index }, "client"),
		action("merge", { identifier, index }, "client"),
		action("claim-quest", { identifier }, "client"),
		action("raid", { identifier }, "client"),
		action("collect", { identifier, Schema.boolean() }, "server"),
	},
	events = events,
	hooks = table.clone(events),
	validateConfig = Adapter.validateConfig,
	validateSave = Adapter.validateSave,
	create = Adapter.create,
}
return contract
