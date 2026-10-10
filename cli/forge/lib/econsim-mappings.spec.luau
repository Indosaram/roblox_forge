--!strict
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local Codegen = require("./codegen")
local Econ = require("./econsim")

local function compare(document: any): (any, any)
	local generated = luau.load(Codegen.generate(serde.encode("yaml", document)))()
	local config = Econ.parseConfig(document)
	assert(
		config.currency == generated.currency and config.startingCoins == generated.startingCoins,
		"config.currency == generated.currency and config.startingCoins == generated.startingCoins"
	)
	assert(#config.eggs == #generated.eggOrder and #config.eggs > 0, "mapping eggs must not disappear")
	for _, egg in config.eggs do
		local actual = generated.eggs[egg.id]
		assert(
			actual ~= nil and actual.price == egg.price and actual.hatchSeconds == egg.hatchSeconds,
			"actual ~= nil and actual.price == egg.price and actual.hatchSeconds == egg.hatchSeconds"
		)
		assert(#actual.pool == #egg.pool, "#actual.pool == #egg.pool")
		for index, entry in egg.pool do
			assert(
				entry.id == actual.pool[index].id and entry.weight == actual.pool[index].weight,
				"entry.id == actual.pool[index].id and entry.weight == actual.pool[index].weight"
			)
		end
	end
	for _, kaiju in config.kaiju do
		assert(
			generated.kaiju[kaiju.id].coinsPerSecond == kaiju.coinsPerSecond,
			"generated.kaiju[kaiju.id].coinsPerSecond == kaiju.coinsPerSecond"
		)
	end
	local result = Econ.simulate(config, { players = 2, days = 1, seed = 42 })
	assert(
		result.hasEggLoop and result.totalSpent > 0 and result.totalProduced > 0,
		"result.hasEggLoop and result.totalSpent > 0 and result.totalProduced > 0"
	)
	assert(
		result.eggBuyCounts.starter > 0 and result.rarityOwners.Common > 0,
		"purchases must hatch income-producing kaiju"
	)
	return config, generated
end

return {
	["mapping normalization matches executed codegen including explicit IDs and sorted pools"] = function()
		local config, generated = compare({
			currencies = { Z = { starting = 999 }, A = { id = "Coins", starting = 100 } },
			incubators = { max = 1 },
			eggs = {
				z = { id = "expensive", price = 1000000, pool = {} },
				a = {
					id = "starter",
					price = 10,
					hatchSeconds = 0,
					pool = {
						z = { id = "common", weight = 1 },
						a = { id = "common", weight = 2 },
					},
				},
			},
			kaiju = { z = { id = "common", coinsPerSecond = 1 }, a = { coinsPerSecond = 2 } },
		})
		assert(
			config.kaiju[1].id == "a" and config.kaiju[2].id == "common",
			'config.kaiju[1].id == "a" and config.kaiju[2].id == "common"'
		)
		assert(
			generated.eggOrder[1] == "starter" and config.eggs[1].pool[1].weight == 2,
			'generated.eggOrder[1] == "starter" and config.eggs[1].pool[1].weight == 2'
		)
	end,
	["mapping key fallback covers currencies eggs kaiju and pools"] = function()
		local config = compare({
			currencies = { Z = { starting = 999 }, Coins = { starting = 100 } },
			incubators = { max = 1 },
			eggs = { starter = { price = 10, hatchSeconds = 0, pool = { common = { weight = 1 } } } },
			kaiju = { common = { coinsPerSecond = 1 } },
		})
		assert(
			config.currency == "Coins" and config.eggById.starter.pool[1].id == "common",
			'config.currency == "Coins" and config.eggById.starter.pool[1].id == "common"'
		)
	end,
	["sequence order and numeric key fallback match codegen"] = function()
		local config, generated = compare({
			currencies = { { id = "Coins", starting = 100 }, { id = "Gems", starting = 999 } },
			incubators = { max = 1 },
			eggs = {
				{ id = "starter", price = 10, pool = { { id = "common", weight = 1 } } },
				{ id = "", price = 1000000, pool = {} },
			},
			kaiju = { { id = "common", coinsPerSecond = 1 }, { id = "", coinsPerSecond = 2 } },
		})
		assert(
			generated.eggOrder[2] == "2" and config.kaiju[2].id == "2",
			'generated.eggOrder[2] == "2" and config.kaiju[2].id == "2"'
		)
	end,
}
