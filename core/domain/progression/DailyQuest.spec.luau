--!strict
-- Specs for DailyQuest: claim gating, one-time payouts, and daily rollover.

local DailyQuest = require("./DailyQuest")

local QUESTS: { DailyQuest.Quest } = {
	{ id = "hatch", target = 5, reward = 100 },
}

return {
	["new rejects a zero reward"] = function()
		local ok = pcall(function()
			DailyQuest.new(1, { { id = "hatch", target = 5, reward = 0 } })
		end)
		assert(not ok, "zero reward should be rejected at construction")
	end,

	["new rejects a fractional reward"] = function()
		local ok = pcall(function()
			DailyQuest.new(1, { { id = "hatch", target = 5, reward = 1.5 } })
		end)
		assert(not ok, "fractional reward should be rejected at construction")
	end,

	["new rejects a fractional target"] = function()
		local ok = pcall(function()
			DailyQuest.new(1, { { id = "hatch", target = 1.5, reward = 100 } })
		end)
		assert(not ok, "fractional target should be rejected at construction")
	end,

	["claim before target fails"] = function()
		local state = DailyQuest.new(1, QUESTS)
		DailyQuest.record(state, "hatch", 4)
		local ok, reward = DailyQuest.claim(state, "hatch")
		assert(ok == false, "claim below target should fail")
		assert(reward == 0, "failed claim pays nothing")
		assert(state.claimed["hatch"] == false, "failed claim leaves the quest unclaimed")
	end,

	["claim at target pays the reward"] = function()
		local state = DailyQuest.new(1, QUESTS)
		DailyQuest.record(state, "hatch", 5)
		assert(state.progress["hatch"] == 5, "progress reaches the target")
		local ok, reward = DailyQuest.claim(state, "hatch")
		assert(ok == true, "claim at target should succeed")
		assert(reward == 100, "claim pays the quest reward")
		assert(state.claimed["hatch"] == true, "successful claim marks the quest claimed")
	end,

	["second claim fails"] = function()
		local state = DailyQuest.new(1, QUESTS)
		DailyQuest.record(state, "hatch", 5)
		local firstOk = DailyQuest.claim(state, "hatch")
		assert(firstOk == true, "first claim succeeds")
		local againOk, againReward = DailyQuest.claim(state, "hatch")
		assert(againOk == false, "second claim should fail")
		assert(againReward == 0, "second claim pays nothing")
	end,

	["rollover resets state on a new day"] = function()
		local state = DailyQuest.new(1, QUESTS)
		DailyQuest.record(state, "hatch", 5)
		DailyQuest.claim(state, "hatch")
		local fresh = DailyQuest.rollover(state, 2, QUESTS)
		assert(fresh ~= state, "new day should build a fresh state")
		assert(fresh.day == 2, "fresh state uses the new day")
		assert(fresh.progress["hatch"] == 0, "fresh state resets progress")
		assert(fresh.claimed["hatch"] == false, "fresh state resets claims")
	end,

	["rollover keeps state on the same day"] = function()
		local state = DailyQuest.new(1, QUESTS)
		DailyQuest.record(state, "hatch", 3)
		local kept = DailyQuest.rollover(state, 1, QUESTS)
		assert(kept == state, "same day should return the same state")
		assert(kept.progress["hatch"] == 3, "progress survives a same-day rollover")
	end,
}
