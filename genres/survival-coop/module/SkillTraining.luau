--!strict
-- Remaining finalized category actions, using the same mastery curve as SkillTree.award.
local SkillTree = require("../../../core/domain/progression/SkillTree")
local M = {}
function M.actions(policy: any, mastery: any, target: number): number
	local level, xp, count = mastery.level, mastery.xp or 0, 0
	while level < target do
		count += 1
		if level == 0 then
			level = 1
		else
			xp += policy.actionXP
			while level < target and xp >= SkillTree.masteryRequired(policy, level) do
				xp -= SkillTree.masteryRequired(policy, level)
				level += 1
			end
		end
	end
	return count
end
function M.forNode(content: any, progression: any, node: any): any
	local action = nil
	for _, category in content.skillCategories do
		if category.id == node.category then
			action = category.entryActions[1]
		end
	end
	return {
		action = action,
		count = M.actions(content.progressionPolicy.tree, progression.mastery[node.category], node.proficiency),
	}
end
return M
