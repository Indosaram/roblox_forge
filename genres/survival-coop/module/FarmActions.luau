--!strict
-- Durable home farming commands served by HomeExtension (fertilizer, sprayer area,
-- crop specialization). Appended after every other extension lane so existing durable
-- policy indices stay put.
local Schema = require("../../../core/infra/net/Schema")
local M = {}

function M.actions(): { any }
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	local rate = { capacity = 5, refillPerSecond = 2 }
	return {
		{
			id = "home-fertilize",
			args = { id, Schema.object({ plot = id, fertilizer = id }) },
			origin = "client",
			rate = rate,
		},
		{
			id = "home-area",
			args = {
				id,
				Schema.object({ plot = id, plots = Schema.string({ maxLen = 256, pattern = ".+" }), fertilizer = id }),
			},
			origin = "client",
			rate = rate,
		},
		{
			id = "home-specialize",
			args = { id, Schema.object({ crop = id, effect = Schema.string({ maxLen = 16 }) }) },
			origin = "client",
			rate = rate,
		},
	}
end

return M
