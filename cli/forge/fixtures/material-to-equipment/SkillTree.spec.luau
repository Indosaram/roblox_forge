--!strict
local Tree = require("../../../../core/domain/progression/SkillTree")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local categories = assert(Content.skillCategories, "v2 skill categories")
local nodes = assert(Content.skillNodes, "v2 skill nodes")
local policy = { maxLevel = 60, spPerLevel = 3, maxMastery = 60, actionXP = 10, xpBase = 50, xpStep = 10 }

return {
	["twelve real categories select nodes spend SP and preserve mastery on exact refund"] = function()
		local state = Tree.new(Content, policy)
		assert(#categories == 12 and #nodes == 72, "progression contract 9")
		assert(state.sp == 3, "progression contract 10")
		for _, category in categories do
			assert(state.mastery[category.id].level == 0, "progression contract 12")
		end
		local _, missing = Tree.learn(Content, state, "tailoring_1")
		assert(missing == "PROFICIENCY_GATE", "progression contract 15")
		state = Tree.award(state, policy, "tailoring", "practice:1")
		assert(Tree.award(state, policy, "tailoring", "practice:1") == state, "progression contract 17")
		state = assert(Tree.learn(Content, state, "tailoring_1"), "progression contract 18")
		assert(state.sp == 1 and state.paid.tailoring_1 == 2, "progression contract 19")
		local _, duplicate = Tree.learn(Content, state, "tailoring_1")
		assert(duplicate == "ALREADY_LEARNED", "progression contract 21")
		local quote = Tree.quote(state)
		assert(quote.refund == 2, "progression contract 23")
		for _, busy in { { combat = true, jobs = 0 }, { combat = false, jobs = 1 } } do
			local _, reason = Tree.reset(state, quote.version, busy.combat, busy.jobs)
			assert(reason == "RESET_BUSY", "progression contract 26")
		end
		local _, stale = Tree.reset(state, quote.version - 1, false, 0)
		assert(stale == "STALE_QUOTE", "progression contract 29")
		local reset = assert(Tree.reset(state, quote.version, false, 0), "progression contract 30")
		assert(
			reset.sp == 3 and next(reset.paid) == nil and reset.mastery.tailoring.level == 1,
			"progression contract 31"
		)
		assert(state.sp == 1 and state.paid.tailoring_1 == 2, "progression contract 32")
	end,
	["SP cannot buy all specializations and prerequisites never disappear behind proficiency"] = function()
		local state = Tree.level(Tree.new(Content, policy), policy, 60)
		assert(state.sp == 180, "progression contract 36")
		for _, mastery in state.mastery do
			mastery.level = 60
		end
		local _, prerequisite = Tree.learn(Content, state, "processing_2")
		assert(prerequisite == "PREREQUISITE_GATE", "progression contract 41")
		local total = 0
		for _, node in nodes do
			total += node.cost
		end
		-- survival_2/3 cost 2/4 since the p27 economy pass; still far above level-60 SP.
		assert(total == 500 and total > 180, "progression contract 46")
		state.sp = 1
		local _, funds = Tree.learn(Content, state, "processing_1")
		assert(funds == "INSUFFICIENT_SP", "progression contract 49")
		local _, unknown = Tree.learn(Content, state, "absent")
		assert(unknown == "UNKNOWN_NODE", "progression contract 51")
	end,
	["confirmed receipts train threshold XP once and do not bypass mastery cap"] = function()
		local state = Tree.new(Content, policy)
		state = Tree.award(state, policy, "gathering", "first")
		for i = 1, 6 do
			state = Tree.award(state, policy, "gathering", tostring(i))
		end
		assert(state.mastery.gathering.level == 2 and state.mastery.gathering.xp == 0, "progression contract 59")
		state.mastery.gathering.level = 60
		state = Tree.award(state, policy, "gathering", "cap")
		assert(state.mastery.gathering.level == 60 and state.mastery.gathering.xp == 0, "progression contract 62")
	end,
}
