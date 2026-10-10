--!strict
-- Specs for Catalog: duplicate keys, invalid prices, paid random items, and valid catalogs.

local Catalog = require("./Catalog")

-- Grants have many shapes; erase that here so catalog literals stay readable.
local function makeGrant(fields: { [string]: any }): any
	return fields
end

return {
	["coins grants reject missing and invalid amounts"] = function()
		local invalid: { { label: string, amount: any } } = {
			{ label = "missing" },
			{ label = "string", amount = "100" },
			{ label = "boolean", amount = true },
			{ label = "zero", amount = 0 },
			{ label = "negative", amount = -1 },
			{ label = "fraction", amount = 1.5 },
			{ label = "NaN", amount = 0 / 0 },
			{ label = "infinity", amount = math.huge },
			{ label = "negative infinity", amount = -math.huge },
		}
		for _, case in invalid do
			local ok = Catalog.validate({
				products = {
					{ key = "coins", name = "Coins", price = 50, grant = { kind = "coins", amount = case.amount } },
				},
			})
			assert(not ok, case.label .. " amount must be rejected")
		end
	end,

	["coins grants accept positive finite integer amounts"] = function()
		for _, amount in { 1, 1000 } do
			local grant: Catalog.Grant = { kind = "coins", amount = amount }
			local entry: Catalog.Entry = { key = "coins", name = "Coins", price = 50, grant = grant }
			local catalog: Catalog.Catalog = { products = { entry } }
			assert(Catalog.validate(catalog), "positive integer amount must be accepted")
		end
	end,
	["duplicate key is rejected"] = function()
		local catalog: any = {
			gamepasses = {
				{ key = "vip", name = "VIP", price = 100, grant = makeGrant({ kind = "flag", flag = "vip" }) },
				{ key = "vip", name = "VIP Again", price = 200, grant = makeGrant({ kind = "flag", flag = "vip" }) },
			},
		}
		local ok, reason = Catalog.validate(catalog)
		assert(ok == false, "duplicate key should be rejected")
		assert(reason == "duplicate key: vip", "reason: " .. tostring(reason))
	end,

	["catalog with a random grant is rejected"] = function()
		local catalog: any = {
			products = {
				{
					key = "mystery_egg",
					name = "Mystery Egg",
					price = 50,
					grant = makeGrant({ kind = "random", pool = { "a", "b" } }),
				},
			},
		}
		local ok, reason = Catalog.validate(catalog)
		assert(ok == false, "random grant should be rejected")
		assert(reason == "paid random item: mystery_egg", "reason: " .. tostring(reason))
	end,

	["valid catalog of 3 gamepasses and 4 products is accepted"] = function()
		local catalog: any = {
			gamepasses = {
				{ key = "vip", name = "VIP", price = 100, grant = makeGrant({ kind = "flag", flag = "vip" }) },
				{
					key = "double_coins",
					name = "Double Coins",
					price = 250,
					grant = makeGrant({ kind = "multiplier", multiplier = 2 }),
				},
				{
					key = "extra_slots",
					name = "Extra Slots",
					price = 150,
					grant = makeGrant({ kind = "slots", amount = 5 }),
				},
			},
			products = {
				{
					key = "storm_kaiju",
					name = "Storm Kaiju",
					price = 400,
					grant = makeGrant({ kind = "kaiju", kaijuId = "storm" }),
				},
				{
					key = "speed_boost",
					name = "Speed Boost",
					price = 75,
					grant = makeGrant({ kind = "speedup", seconds = 60 }),
				},
				{ key = "shield", name = "Shield", price = 90, grant = makeGrant({ kind = "shield", seconds = 30 }) },
				{
					key = "coin_pack",
					name = "Coin Pack",
					price = 50,
					grant = makeGrant({ kind = "coins", amount = 1000 }),
				},
			},
		}
		local ok, reason = Catalog.validate(catalog)
		assert(ok == true, "valid catalog should pass: " .. tostring(reason))
		assert(reason == nil, "no reason on success")
	end,
}
