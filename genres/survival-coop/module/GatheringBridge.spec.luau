--!strict
local Bridge = require("./GatheringBridge")
local Shared = require("../../../core/domain/genre/Contract")
return {
	["unavailable source and actor forgery are distinct"] = function()
		local bridge = Bridge.new({
			resolve = function()
				return nil
			end,
		})
		local context = { actorId = "alice", requestId = "one", sessionEpoch = 0 }
		local function admit(): Shared.Result
			return { ok = true }
		end
		assert(bridge.command("bob", { "node", 0 }, context, 10, admit).reason == "UNAUTHORIZED", "actor bound")
		local absent = bridge.command("alice", { "node", 0 }, context, 10, admit)
		assert(absent.data and absent.data.status == "recovering", "unavailable source distinct")
	end,
}
