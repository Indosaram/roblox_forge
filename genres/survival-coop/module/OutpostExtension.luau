--!strict
local Aggregate = require("./ClanExtension")
local Outpost = require("../../../core/domain/settlement/ClanOutpost")
local Schema = require("../../../core/infra/net/Schema")
local M = {}
function M.actions(): { any }
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	return {
		{
			id = "outpost-start",
			args = { id, Schema.object({ matchId = id }) },
			origin = "server",
			rate = { capacity = 5, refillPerSecond = 1 },
		},
		{
			id = "outpost-advance",
			args = { id, Schema.object({ matchId = id }) },
			origin = "server",
			rate = { capacity = 50, refillPerSecond = 10 },
		},
	}
end
function M.new(config: any): any
	return Aggregate.aggregate(config, Outpost, "outpost", { "start", "advance" })
end
function M.factory(ctx: any): any
	return if ctx.world and ctx.world.outpost then M.new(ctx.world.outpost) else nil
end
return M
