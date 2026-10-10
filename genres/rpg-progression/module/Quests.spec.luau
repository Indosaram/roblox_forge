--!strict
-- Specs for Quests: requirement matching, one-time claims, and reward payout.

local Quests = require("./Quests")

local function newState(): Quests.State
	return Quests.new({
		{
			id = "slay-wolves",
			requirements = { { kind = "kill", target = "wolf", count = 3 } },
			reward = { coins = 50, xp = 20 },
		},
		{
			id = "gather-herbs",
			requirements = {
				{ kind = "collect", target = "herb", count = 2 },
				{ kind = "kill", target = "wolf", count = 1 },
			},
			reward = { coins = 30 },
		},
	})
end

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["progress records matching events and clamps at the target"] = function()
		local state = newState()
		local partial = Quests.progress(state, { kind = "kill", target = "wolf", count = 2 })
		assert(#partial == 0, "not complete after two kills")
		local completed = Quests.progress(state, { kind = "kill", target = "wolf", count = 5 })
		assert(#completed == 1 and completed[1] == "slay-wolves", "completes on the third kill")
		local again = Quests.progress(state, { kind = "kill", target = "wolf", count = 10 })
		assert(#again == 0, "an already-complete quest is not reported twice")
	end,

	["non-matching events do not advance a quest"] = function()
		local state = newState()
		Quests.progress(state, { kind = "collect", target = "wood", count = 5 })
		assert(not Quests.isComplete(state, "slay-wolves"), "a different target does not complete it")
		assert(Quests.claim(state, "slay-wolves") == nil, "an incomplete quest cannot be claimed")
	end,

	["claim pays the reward once and never twice"] = function()
		local state = newState()
		Quests.progress(state, { kind = "kill", target = "wolf", count = 3 })
		local reward = Quests.claim(state, "slay-wolves")
		assert(reward ~= nil, "a completed quest pays out")
		assert(reward.coins == 50 and reward.xp == 20, "reward fields")
		assert(Quests.claim(state, "slay-wolves") == nil, "the second claim returns nothing")
	end,

	["a quest with two requirements needs both"] = function()
		local state = newState()
		Quests.progress(state, { kind = "collect", target = "herb", count = 2 })
		assert(not Quests.isComplete(state, "gather-herbs"), "one of two requirements is not enough")
		Quests.progress(state, { kind = "kill", target = "wolf", count = 1 })
		assert(Quests.isComplete(state, "gather-herbs"), "both requirements complete the quest")
		local reward = Quests.claim(state, "gather-herbs")
		assert(reward ~= nil and reward.coins == 30, "reward coins were paid")
	end,

	["claimed quests stop accumulating progress"] = function()
		local state = newState()
		Quests.progress(state, { kind = "kill", target = "wolf", count = 3 })
		Quests.claim(state, "slay-wolves")
		local completed = Quests.progress(state, { kind = "kill", target = "wolf", count = 3 })
		assert(#completed == 0, "a claimed quest stays silent")
	end,

	["bad definitions and unknown quests error"] = function()
		expectError(function()
			Quests.new({ { id = "bad", requirements = {}, reward = { coins = 1 } } })
		end, "empty requirements")
		expectError(function()
			Quests.new({
				{
					id = "dup",
					requirements = { { kind = "kill", target = "wolf", count = 1 } },
					reward = { coins = 1 },
				},
				{
					id = "dup",
					requirements = { { kind = "kill", target = "wolf", count = 1 } },
					reward = { coins = 1 },
				},
			})
		end, "duplicate quest id")
		expectError(function()
			Quests.claim(newState(), "missing")
		end, "unknown quest")
	end,
}
