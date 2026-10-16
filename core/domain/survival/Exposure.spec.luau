--!strict
local Exposure = require("./Exposure")

local function rejects(fn: () -> ())
	assert(not pcall(fn), "expected rejection")
end

local RISE = { 100, 400, 1000 }

return {
	["four tiers map to base rise and tier zero never rises"] = function()
		assert(#Exposure.TIER_NAMES == Exposure.MAX_TIER + 1, "four named tiers")
		assert(Exposure.rate(RISE, 500, 0, 0, false) == -500, "temperate recovers")
		assert(Exposure.rate(RISE, 500, 1, 0, false) == 100, "harsh rises at tier one rate")
		assert(Exposure.rate(RISE, 500, 2, 0, false) == 400, "severe rises at tier two rate")
		assert(Exposure.rate(RISE, 500, 3, 0, false) == 1000, "extreme rises at tier three rate")
		assert(Exposure.rate(RISE, 500, 3, 0, true) == -500, "a warm actor recovers in any tier")
	end,
	["clothing resistance mitigates the rise and clamps at the policy maximum"] = function()
		assert(Exposure.mitigated(1000, 0) == 1000, "naked rise is unmitigated")
		assert(Exposure.mitigated(1000, 250) == 750, "quarter resistance")
		assert(Exposure.mitigated(1000, 1000) == 0, "full resistance blocks the rise")
		assert(Exposure.rate(RISE, 500, 3, 1000, false) == -500, "fully mitigated tier recovers")
		assert(Exposure.combine({ 400, 300 }) == 700, "scores add")
		assert(Exposure.combine({ 800, 800 }) == 1000, "scores clamp")
		assert(Exposure.combine({}) == 0, "no clothing")
	end,
	["tier and resistance boundaries reject out of range input"] = function()
		for _, tier in { -1, 4, 0.5, 0 / 0, math.huge } do
			assert(not Exposure.validTier(tier), "tier rejected")
			rejects(function()
				Exposure.rate(RISE, 500, tier, 0, false)
			end)
		end
		for _, resistance in { -1, 1001, 0.5, 0 / 0 } do
			assert(not Exposure.validResistance(resistance), "resistance rejected")
			rejects(function()
				Exposure.mitigated(100, resistance)
			end)
		end
		for _, tier in { 0, 3 } do
			assert(Exposure.validTier(tier), "boundary tier accepted")
		end
		assert(Exposure.validResistance(0) and Exposure.validResistance(1000), "boundary resistance accepted")
		rejects(function()
			Exposure.combine({ 1001 })
		end)
	end,
	["step is partition invariant and clamps at both ends"] = function()
		local value, remainder = 10000, 0
		for _ = 1, 4000 do
			value, remainder = Exposure.step(value, remainder, 333, 25)
		end
		local whole, wholeRemainder = Exposure.step(10000, 0, 333, 100000)
		assert(value == whole and remainder == wholeRemainder, "fine and coarse agree")
		assert(whole == 10000 + 33300, "exact fixed point total")
		local top, topRemainder = Exposure.step(99999, 0, 1000, 5000)
		assert(top == Exposure.MAX and topRemainder == 0, "clamps at max and drops remainder")
		local bottom, bottomRemainder = Exposure.step(1, 0, -1000, 5000)
		assert(bottom == 0 and bottomRemainder == 0, "clamps at zero")
		local same, sameRemainder = Exposure.step(7, 3, 0, 9999)
		assert(same == 7 and sameRemainder == 3, "zero rate is a no-op")
	end,
	["timeToFull is exact and agrees with step"] = function()
		assert(Exposure.timeToFull(0, 0, 0) == math.huge and Exposure.timeToFull(0, 0, -5) == math.huge, "no rise")
		assert(Exposure.timeToFull(Exposure.MAX, 0, 100) == 0, "already full")
		local at = Exposure.timeToFull(99000, 0, 700)
		local before = Exposure.step(99000, 0, 700, at - 1)
		local atValue = Exposure.step(99000, 0, 700, at)
		assert(before < Exposure.MAX and atValue == Exposure.MAX, "first millisecond at max")
	end,
}
