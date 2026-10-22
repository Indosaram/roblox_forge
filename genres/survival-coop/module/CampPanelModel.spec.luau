--!strict
local Model = require("./CampPanelModel")

local function slice(): any
	return {
		role = "member",
		rung = 0,
		version = 3,
		facilities = {},
		ladder = {
			rungs = { {} },
			projects = {
				{
					id = "windbreak",
					rung = 1,
					cost = { { item = "fiber", quantity = 40 }, { item = "branch", quantity = 30 } },
				},
			},
		},
		active = { windbreak = { delivered = { fiber = 12, branch = 99 } } },
	}
end

return {
	["camp rows keep each material's delivered and needed amount"] = function()
		local row = assert(Model.model(slice(), 0)).rows[1]
		assert(row.delivered == 42 and row.need == 70, "total still summed")
		assert(#row.costs == 2, "one cost per material")
		assert(row.costs[1].item == "fiber" and row.costs[1].delivered == 12 and row.costs[1].need == 40, "fiber")
		assert(row.costs[2].item == "branch" and row.costs[2].delivered == 30 and row.costs[2].need == 30, "capped")
	end,
	["cost line names each material through pack names, else the HUD locale"] = function()
		local row = assert(Model.model(slice(), 0)).rows[1]
		local line = Model.costLine("ko-kr", row, { branch = "나뭇가지" })
		assert(line == "섬유 12/40 · 나뭇가지 30/30", line)
		assert(Model.costLine("en-us", row, nil) == "Fiber 12/40 · branch 30/30", Model.costLine("en-us", row, nil))
	end,
}
