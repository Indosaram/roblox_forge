--!strict
local Buyback = require("./Buyback")

local POLICY = { prices = { wood = 1, stone = 1, fiber = 1, meat = 2 }, dailyUnits = 200, daySeconds = 86400 }

return {
	["fixed prices, shared daily cap and UTC day reset"] = function()
		local coins, state = Buyback.sell(POLICY, nil, "meat", 10, 100)
		assert(coins == 20 and state and state.sold == 10, "meat sells at 2")
		local wood, next = Buyback.sell(POLICY, state, "wood", 190, 200)
		assert(wood == 190 and next and next.sold == 200, "wood shares the cap")
		local refused, same, reason = Buyback.sell(POLICY, next, "stone", 1, 300)
		assert(refused == nil and same == nil and reason == "DAILY_CAP", "cap reached")
		local reset, fresh = Buyback.sell(POLICY, next, "stone", 1, 86400 + 5)
		assert(reset == 1 and fresh and fresh.sold == 1, "next UTC day resets")
	end,
	["refuses unbought ids and bad quantities"] = function()
		assert(select(3, Buyback.sell(POLICY, nil, "iron-ore", 1, 0)) == "NOT_BOUGHT", "crafted/other ids refused")
		assert(select(3, Buyback.sell(POLICY, nil, "wood", 0, 0)) == "INVALID_QUANTITY", "zero refused")
		assert(select(3, Buyback.sell(POLICY, nil, "wood", 1.5, 0)) == "INVALID_QUANTITY", "fraction refused")
		assert(Buyback.remaining(POLICY, nil, 0) == 200, "full cap when unused")
	end,
}
