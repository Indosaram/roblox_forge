--!strict
-- Specs for Catalog: duplicate keys, invalid prices, paid random items, and valid catalogs.

local Catalog = require("./Catalog")

-- Grants have many shapes; erase that here so catalog literals stay readable.
local function makeGrant(fields: { [string]: any }): any
	return fields
end

return {
	["survival grant kinds validate in their sections"] = function()
		local catalog: any = {
			gamepasses = {
				{
					key = "wide",
					name = "Wide Storage",
					price = 199,
					grant = makeGrant({ kind = "storageSlots", amount = 10 }),
				},
				{
					key = "alt",
					name = "Character Slot",
					price = 149,
					grant = makeGrant({ kind = "characterSlot", amount = 1 }),
				},
			},
			products = {
				{ key = "respec", name = "Respec", price = 99, grant = makeGrant({ kind = "respecToken" }) },
				{
					key = "reef",
					name = "Reef Outfit",
					price = 149,
					grant = makeGrant({ kind = "cosmeticSet", cosmeticSetId = "reef-outfit" }),
				},
			},
			subscriptions = {
				{
					key = "tide",
					name = "Tide Monthly",
					price = 499,
					grant = makeGrant({ kind = "subscriptionMonthly", cosmeticSetId = "tide-set", storageSlots = 10 }),
				},
			},
		}
		local ok, reason = Catalog.validate(catalog)
		assert(ok == true, "survival catalog must validate: " .. tostring(reason))
		assert(
			#Catalog.lint(catalog) == 0,
			"survival catalog must lint clean: " .. table.concat(Catalog.lint(catalog), "; ")
		)
	end,

	["survival grant kinds reject missing fixed fields and wrong sections"] = function()
		local cases: { { label: string, catalog: any, reason: string } } = {
			{
				label = "storage without amount",
				catalog = { gamepasses = { { key = "s", name = "S", price = 1, grant = { kind = "storageSlots" } } } },
				reason = "storageSlots grant requires a positive integer amount: s",
			},
			{
				label = "cosmetic without set id",
				catalog = { products = { { key = "c", name = "C", price = 1, grant = { kind = "cosmeticSet" } } } },
				reason = "cosmeticSet grant requires a fixed cosmeticSetId: c",
			},
			{
				label = "subscription without storage",
				catalog = {
					subscriptions = {
						{
							key = "m",
							name = "M",
							price = 1,
							grant = { kind = "subscriptionMonthly", cosmeticSetId = "x" },
						},
					},
				},
				reason = "subscriptionMonthly grant requires positive integer storageSlots: m",
			},
			{
				label = "subscription kind sold as a product",
				catalog = {
					products = {
						{
							key = "p",
							name = "P",
							price = 1,
							grant = { kind = "subscriptionMonthly", cosmeticSetId = "x", storageSlots = 1 },
						},
					},
				},
				reason = "invalid grant kind: p",
			},
			{
				label = "coins sold as a subscription",
				catalog = {
					subscriptions = { { key = "k", name = "K", price = 1, grant = { kind = "coins", amount = 5 } } },
				},
				reason = "invalid grant kind: k",
			},
		}
		for _, case in cases do
			local ok, reason = Catalog.validate(case.catalog)
			assert(ok == false, case.label .. " must be rejected")
			assert(reason == case.reason, case.label .. ": reason " .. tostring(reason))
		end
	end,

	["lint flags every ADR-07 rule by field name and kind"] = function()
		local cases: { { label: string, entry: any, section: string, rule: string } } = {
			{ label = "pool", section = "products", rule = "paid-random", entry = { pool = { "a" } } },
			{ label = "oddsPct", section = "products", rule = "paid-random", entry = { grant = { oddsPct = 5 } } },
			{ label = "luck_mult", section = "gamepasses", rule = "luck-drop-boost", entry = { luck_mult = 2 } },
			{ label = "dropBonus", section = "products", rule = "luck-drop-boost", entry = { dropBonus = 1 } },
			{ label = "rateUp", section = "products", rule = "luck-drop-boost", entry = { grant = { rateUp = 1 } } },
			{
				label = "coins kind",
				section = "products",
				rule = "soft-currency-sale",
				entry = { grant = { kind = "coins" } },
			},
			{
				label = "currency field",
				section = "products",
				rule = "soft-currency-sale",
				entry = { currencyAmount = 9 },
			},
			{
				label = "multiplier kind",
				section = "gamepasses",
				rule = "luck-drop-boost",
				entry = { grant = { kind = "multiplier" } },
			},
			{ label = "enhance input", section = "products", rule = "mixed-random", entry = { enhanceInput = "gem" } },
			{
				label = "subscription extra effect",
				section = "subscriptions",
				rule = "subscription-effect",
				entry = { grant = { kind = "subscriptionMonthly", cosmeticSetId = "x", storageSlots = 1, xpBonus = 2 } },
			},
			{
				label = "subscription wrong kind",
				section = "subscriptions",
				rule = "subscription-effect",
				entry = { grant = { kind = "speedup" } },
			},
		}
		for _, case in cases do
			local entry = table.clone(case.entry)
			entry.key = "bad"
			entry.name = "Bad"
			entry.price = 10
			local violations = Catalog.lint({ [case.section] = { entry } })
			local found = false
			for _, violation in violations do
				if string.sub(violation, 1, #case.rule + 7) == case.rule .. ": bad (" then
					found = true
				end
			end
			assert(found, case.label .. ": expected " .. case.rule .. ", got " .. table.concat(violations, "; "))
		end
	end,

	["lint passes deterministic entries and ignores names and keys"] = function()
		local catalog: any = {
			products = {
				{
					key = "luckyHat",
					name = "Lucky Drop Hat",
					price = 49,
					grant = { kind = "cosmeticSet", cosmeticSetId = "hat" },
				},
				{ key = "shield", name = "Shield", price = 90, grant = { kind = "shield", seconds = 30 } },
			} :: { any },
		}
		local violations = Catalog.lint(catalog)
		assert(#violations == 0, "clean catalog: " .. table.concat(violations, "; "))
		assert(#Catalog.lint(nil) == 0 and #Catalog.lint({}) == 0, "empty input lints clean")
	end,
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
