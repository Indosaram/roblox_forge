--!strict
-- Fixture Config for Loop.spec.luau. Mirrors Kaiju Egg Raiders' economy
-- shape (two sources, three rarities, one merge family) so the genre spec
-- exercises the same numbers the pack's own Config produces, without the
-- genre module depending on any pack.

local Loop = require("./Loop")

local Fixture: Loop.Config = {
	currency = "Coins",
	startingCoins = 100,
	maxIncubators = 3,
	pricing = { growthPerOwned = 0.08 },
	income = { activeSlots = 6 },
	sources = {
		ember = {
			id = "ember",
			displayName = "Ember Egg",
			price = 50,
			hatchSeconds = 5,
			pool = {
				{ id = "pyro-pup", weight = 70 },
				{ id = "magma-mauler", weight = 25 },
				{ id = "solar-titan", weight = 5 },
			},
		},
		tidal = {
			id = "tidal",
			displayName = "Tidal Egg",
			price = 250,
			hatchSeconds = 15,
			pool = {
				{ id = "reef-runner", weight = 60 },
				{ id = "storm-serpent", weight = 30 },
				{ id = "abyss-leviathan", weight = 10 },
			},
		},
	},
	sourceOrder = { "ember", "tidal" },
	creatures = {
		["pyro-pup"] = { id = "pyro-pup", displayName = "Pyro Pup", rarity = "Common", coinsPerSecond = 1 },
		["magma-mauler"] = { id = "magma-mauler", displayName = "Magma Mauler", rarity = "Rare", coinsPerSecond = 3 },
		["solar-titan"] = { id = "solar-titan", displayName = "Solar Titan", rarity = "Legendary", coinsPerSecond = 8 },
		["reef-runner"] = { id = "reef-runner", displayName = "Reef Runner", rarity = "Common", coinsPerSecond = 2 },
		["storm-serpent"] = { id = "storm-serpent", displayName = "Storm Serpent", rarity = "Rare", coinsPerSecond = 5 },
		["abyss-leviathan"] = {
			id = "abyss-leviathan",
			displayName = "Abyss Leviathan",
			rarity = "Legendary",
			coinsPerSecond = 15,
		},
	},
	mergeFamilies = {
		{
			id = "ember",
			displayName = "Ember",
			rules = {
				{ from = "Common", to = "Rare", count = 3, resultId = "magma-mauler" },
				{ from = "Rare", to = "Legendary", count = 3, resultId = "solar-titan" },
			},
		},
		{
			id = "tidal",
			displayName = "Tidal",
			rules = {
				{ from = "Common", to = "Rare", count = 3, resultId = "storm-serpent" },
				{ from = "Rare", to = "Legendary", count = 3, resultId = "abyss-leviathan" },
			},
		},
	},
	siege = { period = 600, duration = 120, maxTake = 3 },
	offline = { maxSeconds = 8 * 3600, efficiency = 0.5 },
	dailyQuests = {
		{ id = "hatch", target = 3, reward = 100 },
		{ id = "buy", target = 5, reward = 150 },
		{ id = "raid", target = 1, reward = 300 },
	},
	tutorialSteps = {
		{ id = "buy", hint = "Buy an egg from the panel", event = "buy" },
		{ id = "hatch", hint = "Hatch your egg when it is ready", event = "hatch" },
		{ id = "claim", hint = "Claim a completed daily quest", event = "claim" },
		{ id = "store", hint = "Open the store to see Robux items", event = "store" },
	},
	profile = {
		version = 1,
		defaults = function(): { [string]: any }
			return { coins = 100, creatures = {}, lastSeen = 0, questDay = 0, quest = nil }
		end,
	},
}

return Fixture
