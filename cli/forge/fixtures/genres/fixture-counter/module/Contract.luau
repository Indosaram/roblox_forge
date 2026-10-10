--!strict
local Contract = require("../../../../../../core/domain/genre/Contract")
local descriptor: Contract.RuntimeContract = {
	api = 1,
	id = "fixture-counter",
	configVersion = 1,
	saveVersion = 1,
	actions = { { id = "increment", args = {}, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } } },
	events = { "CountChanged" },
	hooks = { "CountChanged" },
	validateConfig = function(config)
		if type(config.target) ~= "number" or config.target % 1 ~= 0 or config.target < 1 or config.target > 100 then
			return { "invalid target" }
		end
		for key in config do
			if key ~= "target" then
				return { "unknown config" }
			end
		end
		return {}
	end,
	validateSave = function(save)
		if type(save.count) ~= "number" or save.count % 1 ~= 0 or save.count < 0 or save.count > 1e9 then
			return { "invalid count" }
		end
		return {}
	end,
	create = function(_config, services)
		local counts: { [string]: number } = {}
		return {
			join = function(player, save)
				counts[player] = if save then save.count else 0
				return { ok = true }
			end,
			leave = function(player)
				counts[player] = nil
			end,
			dispatch = function(player, action, _args)
				if action ~= "increment" or counts[player] == nil then
					return { ok = false, reason = "invalid action/member" }
				end
				counts[player] += 1
				services.emit({
					genre = "fixture-counter",
					name = "CountChanged",
					playerId = player,
					data = { count = counts[player] },
				})
				return { ok = true }
			end,
			advance = function(_epoch) end,
			snapshot = function(player)
				return { count = counts[player] }
			end,
			save = function(player)
				return { count = counts[player] }
			end,
		}
	end,
}
return descriptor
