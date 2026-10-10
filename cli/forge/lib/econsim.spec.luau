--!strict
-- Specs for econsim: determinism under a seed, inflation math on a hand-made
-- config, and the siege rule that only free-produced Common value is stealable.

local econsim = require("./econsim")

local function arraysEqual(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for index = 1, #a do
		if a[index] ~= b[index] then
			return false
		end
	end
	return true
end

local function sameResult(a: econsim.SimResult, b: econsim.SimResult): boolean
	return arraysEqual(a.dailySupply, b.dailySupply)
		and arraysEqual(a.dailyInflation, b.dailyInflation)
		and arraysEqual(a.firstPurchaseMinutes, b.firstPurchaseMinutes)
		and a.siegeCoinsTaken == b.siegeCoinsTaken
		and a.totalProduced == b.totalProduced
end

local function tinyConfig(): econsim.EconConfig
	return econsim.parseConfig({
		currencies = { { id = "Coins", starting = 100 } },
		incubators = { max = 1 },
		eggs = {
			{
				id = "small",
				displayName = "Small Egg",
				price = 10,
				hatchSeconds = 0,
				pool = { { id = "common", weight = 1 } },
			},
		},
		kaiju = {
			{ id = "common", displayName = "Common", rarity = "Common", coinsPerSecond = 1 },
		},
	})
end

local function flatConfig(): econsim.EconConfig
	return econsim.parseConfig({
		currencies = { { id = "Coins", starting = 100 } },
	})
end

local function sinkConfig(): econsim.EconConfig
	return econsim.parseConfig({
		currencies = { { id = "Coins", starting = 100 } },
		pricing = { growthPerOwned = 0.5 },
		income = { activeSlots = 2 },
		eggs = {
			{
				id = "small",
				displayName = "Small Egg",
				price = 100,
				hatchSeconds = 0,
				pool = { { id = "common", weight = 1 } },
			},
		},
		kaiju = {
			{ id = "common", displayName = "Common", rarity = "Common", coinsPerSecond = 3 },
		},
	})
end

return {
	["same seed gives identical results"] = function()
		local config = tinyConfig()
		local a = econsim.simulate(config, { players = 6, days = 4, seed = 42 })
		local b = econsim.simulate(config, { players = 6, days = 4, seed = 42 })
		assert(sameResult(a, b), "same seed must reproduce every reported number")
	end,

	["different seed gives a different run"] = function()
		local config = tinyConfig()
		local a = econsim.simulate(config, { players = 6, days = 4, seed = 1 })
		local b = econsim.simulate(config, { players = 6, days = 4, seed = 2 })
		assert(not sameResult(a, b), "different seeds should diverge")
	end,

	["inflation is computed correctly on a tiny hand-made config"] = function()
		assert(econsim.inflationPercent(100, 150) == 50, "100 -> 150 is +50%")
		assert(econsim.inflationPercent(200, 100) == -50, "200 -> 100 is -50%")
		assert(econsim.inflationPercent(0, 5) == 0, "a zero base has no defined inflation")

		local result = econsim.simulate(flatConfig(), { players = 2, days = 3, seed = 7 })
		for day = 1, 3 do
			assert(result.dailySupply[day] == 200, "flat config keeps 2 x 100 coins")
			assert(result.dailyInflation[day] == 0, "no production means zero inflation")
		end
	end,

	["siege never takes non-Common kaiju"] = function()
		local rareOnly: { econsim.OwnedKaiju } = {
			{ id = "r", rarity = "Rare", coinsPerSecond = 1000, source = "free" },
		}
		assert(econsim.stealableCommonValue(rareOnly) == 0, "a Rare-only rival has no stealable value")

		local robuxCommon: { econsim.OwnedKaiju } = {
			{ id = "c", rarity = "Common", coinsPerSecond = 1000, source = "robux" },
		}
		assert(econsim.stealableCommonValue(robuxCommon) == 0, "Robux-sourced kaiju are never stolen")

		local mixed: { econsim.OwnedKaiju } = {
			{ id = "r", rarity = "Rare", coinsPerSecond = 1000, source = "free" },
			{ id = "c", rarity = "Common", coinsPerSecond = 1, source = "free" },
		}
		assert(econsim.stealableCommonValue(mixed) == 60, "only the Common kaiju is valued")

		local rng = econsim.newRng(123)
		for _ = 1, 200 do
			local amount = econsim.siegeAmount(rng, mixed, 1000000)
			assert(amount >= 0 and amount <= 6, "a siege takes at most 10% of the free Common base")
		end
		for _ = 1, 50 do
			assert(econsim.siegeAmount(econsim.newRng(1), rareOnly, 1000000) == 0, "Rare is never taken")
		end
	end,

	["egg price scales with the owned kaiju count"] = function()
		local config = sinkConfig()
		local egg = config.eggById["small"]
		assert(econsim.eggPrice(config, egg, 0) == 100, "no kaiju keeps the base price")
		assert(econsim.eggPrice(config, egg, 2) == 200, "0.5 growth doubles at two owned")
		assert(econsim.eggPrice(config, egg, 3) == 250, "0.5 growth at three owned floors to 250")
	end,

	["income uses only the top activeSlots rates"] = function()
		local config = sinkConfig()
		local owned: { econsim.OwnedKaiju } = {
			{ id = "a", rarity = "Common", coinsPerSecond = 1, source = "free" },
			{ id = "b", rarity = "Rare", coinsPerSecond = 5, source = "free" },
			{ id = "c", rarity = "Common", coinsPerSecond = 3, source = "free" },
		}
		assert(econsim.activeRate(config, owned) == 8, "the top two of 1, 5, 3 is 8")
	end,

	["missing pricing and income sections default to no sinks"] = function()
		local config = flatConfig()
		assert(config.pricing.growthPerOwned == 0, "growth defaults to 0")
		assert(config.income.activeSlots == 0, "slots default to unlimited")
	end,

	["a differently-shaped econ.yml parses with empty defaults"] = function()
		local config = econsim.parseConfig({
			currencies = { { id = "Coins", starting = 50 } },
			crops = { { id = "carrot" } },
		})
		assert(#config.eggs == 0, "a missing eggs section parses to no eggs")
		assert(#config.kaiju == 0, "a missing kaiju section parses to no kaiju")
		assert(config.maxIncubators == 0, "a missing incubators section parses to zero")
		assert(config.cropCount == 1, "declared crops are still counted")
	end,

	["F2: first-purchase minute is measured in play time, not the absolute login offset"] = function()
		-- 0 starting coins, one 1000-price egg, 1 cps kaiju, 1 player, 1 day: the
		-- player is blocked from minute 0 of play, so every seed's session-start
		-- offset (which varies by seed) must never leak into the reported minute.
		local config = econsim.parseConfig({
			currencies = { { id = "Coins", starting = 0 } },
			incubators = { max = 1 },
			eggs = {
				{ id = "e", displayName = "E", price = 1000, hatchSeconds = 0, pool = { { id = "k", weight = 1 } } },
			},
			kaiju = { { id = "k", displayName = "K", rarity = "Common", coinsPerSecond = 1 } },
		})
		for seed = 1, 4 do
			local result = econsim.simulate(config, { players = 1, days = 1, seed = seed })
			assert(
				result.firstPurchaseMinutes[1] == 0,
				string.format(
					"seed %d: expected first-purchase play-minute 0, got %s (login offset leaked into play time)",
					seed,
					tostring(result.firstPurchaseMinutes[1])
				)
			)
		end
	end,
}
