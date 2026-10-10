--!strict
local LiveopsEvent = require("./LiveopsEvent")
local Schedule = require("../../../../core/infra/liveops/Schedule")

return {
	["valid broadcast values and inclusive limits are accepted"] = function()
		local multiplier, duration = LiveopsEvent.validate({ multiplier = 2, durationSeconds = 3600 })
		assert(multiplier == 2 and duration == 3600, "ordinary event accepted")
		local maximum, longest = LiveopsEvent.validate({ multiplier = 10, durationSeconds = 86400 })
		assert(maximum == 10 and longest == 86400, "inclusive maxima accepted")
	end,
	["malformed nonfinite and excessive broadcast values are rejected"] = function()
		local multipliers: { any } = { 0, -1, 11, 1e300, math.huge, -math.huge, 0 / 0, "2", false }
		for _, value in multipliers do
			assert(
				LiveopsEvent.validate({ multiplier = value, durationSeconds = 3600 }) == nil,
				"invalid multiplier rejected"
			)
		end
		local durations: { any } = { 0, -1, 1.5, 86401, math.huge, -math.huge, 0 / 0, "3600", false }
		for _, value in durations do
			assert(
				LiveopsEvent.validate({ multiplier = 2, durationSeconds = value }) == nil,
				"invalid duration rejected"
			)
		end
		assert(LiveopsEvent.validate({}) == nil, "missing fields rejected")
	end,
	["overlapping events cannot overflow the effective production multiplier"] = function()
		local schedule = Schedule.new({
			{ id = "a", startsAt = 0, endsAt = 10, multipliers = { coins = 10 } },
			{ id = "b", startsAt = 0, endsAt = 10, multipliers = { coins = 10 } },
		})
		assert(LiveopsEvent.effectiveMultiplier(schedule:multiplier("coins", 1)) == 10, "overlap capped")
		assert(LiveopsEvent.effectiveMultiplier(math.huge) == 10, "overflow capped")
		assert(LiveopsEvent.effectiveMultiplier(2) == 2, "ordinary multiplier preserved")
		assert(LiveopsEvent.effectiveMultiplier(1) == 1, "idle multiplier preserved")
	end,
}
