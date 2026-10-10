--!strict
local plan = require("./plan")

return {
	["team uniqueness distinguishes valid and repeated names"] = function()
		assert(plan.hasDuplicateTeams({ "Red", "Red" }), "adjacent duplicates rejected")
		assert(plan.hasDuplicateTeams({ "Red", "Blue", "Red" }), "separated duplicates rejected")
		assert(not plan.hasDuplicateTeams({ "Red-Team", "1Blue" }), "distinct names accepted")
	end,
	["duplicate team names are rejected before any pack is written"] = function()
		assert(not plan.run({ "plan", "--teams", "Red,Red" }), "duplicate CLI input refused")
		assert(not plan.run({ "plan", "--teams", "Red,Blue,Red" }), "repeated CLI input refused")
	end,
}
