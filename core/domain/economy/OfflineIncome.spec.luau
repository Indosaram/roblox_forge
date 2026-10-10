--!strict
-- Specs for OfflineIncome: elapsed clamping, zero for negative elapsed, and efficiency scaling.

local OfflineIncome = require("./OfflineIncome")

return {
	["offline accrual is capped at maxSeconds"] = function()
		local earned = OfflineIncome.compute(0, 10_000, 10, 60, 1)
		assert(earned == 600, "accrual should stop at maxSeconds")
	end,

	["negative elapsed time yields zero"] = function()
		local earned = OfflineIncome.compute(100, 50, 10, 60, 1)
		assert(earned == 0, "lastSeen after now should yield 0")
	end,

	["efficiency 0.5 halves the payout"] = function()
		local earned = OfflineIncome.compute(0, 60, 10, 120, 0.5)
		assert(earned == 300, "half efficiency should halve the payout")
	end,

	["an exact integer result is not underpaid by float floor"] = function()
		-- 90 * 0.7 == 63 mathematically, but the raw float product is
		-- 62.99999999999999, so a bare math.floor underpays by 1.
		local earned = OfflineIncome.compute(0, 90, 1, 1e9, 0.7)
		assert(earned == 63, "exact integer payout should not be floored down, got " .. tostring(earned))
	end,

	["a sweep of non-exact efficiencies never underpays an exact integer result"] = function()
		for _, efficiency in { 0.1, 0.3, 0.7, 0.9 } do
			for rate = 1, 20 do
				for seconds = 1, 30 do
					local exact = rate * seconds * efficiency
					if exact == math.floor(exact) then
						local earned = OfflineIncome.compute(0, seconds, rate, 1e9, efficiency)
						assert(
							earned == exact,
							string.format(
								"rate=%d seconds=%d efficiency=%s expected %d got %s",
								rate,
								seconds,
								tostring(efficiency),
								exact,
								tostring(earned)
							)
						)
					end
				end
			end
		end
	end,
}
