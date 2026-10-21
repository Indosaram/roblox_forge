--!strict
local Expedition = require("./Expedition")
return {
	["stage admission checks index level development expiry and exact prior objectives"] = function()
		for index, minimum in { 30, 35, 40, 50, 60 } do
			local facts = {
				index = index,
				level = minimum,
				developmentGrade = index * 2,
				stage = 1,
				completedStage = 0,
				completedObjectives = 0,
				expiresAt = 100,
			}
			assert(Expedition.admitStage(facts, 99), "ExpeditionAdmission.spec.luau: routing invariant")
			facts.level -= 1
			local ok, reason = Expedition.admitStage(facts, 99)
			assert(not ok and reason == "level_gate", "ExpeditionAdmission.spec.luau: routing invariant")
			facts.level = minimum
			facts.developmentGrade -= 1
			local developed, developmentReason = Expedition.admitStage(facts, 99)
			assert(not developed and developmentReason == "development_gate", "development grade gate")
			facts.developmentGrade += 1
			assert(not Expedition.admitStage(facts, 100), "ExpeditionAdmission.spec.luau: routing invariant")
			facts.stage = 2
			facts.completedStage = 1
			facts.completedObjectives = 1
			local completed, missionReason = Expedition.admitStage(facts, 99)
			assert(not completed and missionReason == "mission_gate", "both prior stage objectives required")
			facts.completedObjectives = 2
			assert(Expedition.admitStage(facts, 99), "ExpeditionAdmission.spec.luau: routing invariant")
		end
	end,
}
