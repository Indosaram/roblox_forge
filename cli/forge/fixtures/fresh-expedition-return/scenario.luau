--!strict
-- Reuse the real production factory/session journey, not a second simulation.
local Production = require("../production-worlds/scenario")
local Harbor = require("../../../../genres/survival-coop/module/HarborFacilities")
local Content: any = require("../../../../games/robango-island/src/shared/SurvivalContent")
local M: any = { operations = table.clone(Production.operations) }
M.operations.fresh_stage_table = function(_ctx, _step): string?
	local stages = Harbor.stages(Content)
	return if #stages == #Content.stages + #Content.supportRegions
			and stages[1].level == 1
			and stages[#stages].level == 60
		then nil
		else "incomplete stage table"
end
M.new = Production.new
return M
