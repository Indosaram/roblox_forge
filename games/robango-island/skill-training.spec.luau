--!strict
local Training = require("../../genres/survival-coop/module/SkillTraining")
local Content: any = require("./src/shared/SurvivalContent")
return {
	["training count follows the shipped proficiency curve"] = function()
		local p = Content.progressionPolicy.tree
		assert(Training.actions(p, { level = 0, xp = 0 }, 3) == 24, "processing rank two needs 24 actions from zero")
		assert(Training.actions(p, { level = 1, xp = 0 }, 3) == 23, "first action already earned")
		assert(Training.actions(p, { level = 3, xp = 0 }, 3) == 0, "eligible node needs no practice")
		assert(Training.actions(p, { level = 0, xp = 0 }, 6) == 76, "rank three training cost remains explicit")
	end,
}
