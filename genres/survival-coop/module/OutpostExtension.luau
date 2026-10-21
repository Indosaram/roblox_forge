--!strict
local Aggregate = require("./ClanExtension")
local Outpost = require("../../../core/domain/settlement/ClanOutpost")
local Schema = require("../../../core/infra/net/Schema")
local M = {}
function M.actions(): { any }
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	return {
		{
			id = "outpost-queue",
			args = { id, Schema.object({ enabled = Schema.boolean() }) },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 1 },
		},
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
	local extension = Aggregate.aggregate(config, Outpost, "outpost", { "queue", "start", "advance" })
	if config.drive then
		extension.recover = function(actor: string, _maximum: number): any
			return config.drive(actor, extension)
		end
	end
	return extension
end
function M.factory(ctx: any): any
	return if ctx.world and ctx.world.outpost then M.new(ctx.world.outpost) else nil
end
return M
