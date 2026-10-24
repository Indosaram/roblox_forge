--!strict
local Recipe = require("./recipe-generator")
local Bounty = require("./module/ArenaBounty")
local Collect = require("../collect-raid/module/Adapter.fixture")
local Arena = require("./module/Adapter.fixture")
local registryLib = require("../../cli/forge/lib/genreregistry")
local generate = require("../../cli/forge/lib/genregenerate")
local genresim = require("../../cli/forge/lib/genresim")
local serde = require("@lune/serde")
local input = {
	mode = "new" :: "new",
	slug = "bounty",
	pascal = "Bounty",
	title = "Bounty",
	concept = "",
	seed = 7,
	teams = { "Red", "Blue" },
	debugName = "BountyDebug",
	guiName = "BountyGui",
}
return {
	["normalization zeroes the collect wallet without touching standalone defaults"] = function()
		local configs = { ["collect-raid"] = Collect.config(), ["pvp-arena"] = table.clone(Arena) }
		local normalized = Recipe.normalize(configs)
		assert(normalized["collect-raid"].startingCoins == 0, "collect wallet not normalized")
		assert(configs["collect-raid"].startingCoins == 100, "standalone default mutated")
		assert(#Bounty.validateConfig(normalized) == 0, table.concat(Bounty.validateConfig(normalized), "; "))
		local errors = Bounty.validateConfig(configs)
		assert(#errors == 1 and string.find(errors[1], "startingCoins", 1, true), "funded collect wallet accepted")
		normalized.extra = {}
		assert(#Bounty.validateConfig(normalized) == 1, "unknown partner config accepted")
	end,
	["both selection orders produce canonical data and coupled metrics"] = function()
		local registry, errors = registryLib.discover()
		assert(registry, table.concat(errors, "; "))
		local a = generate.assemble(registry, { "collect-raid", "pvp-arena" }, input, ".omo/wip/bounty")
		local b = generate.assemble(registry, { "pvp-arena", "collect-raid" }, input, ".omo/wip/bounty")
		assert(not a.legacy, "recipe pack used the collect-raid legacy scaffold")
		assert(a.files["econ.yml"] == b.files["econ.yml"], "selection order changed generated config")
		local scenario = serde.decode("yaml", a.files["qa-scenarios/pvp-arena.golden-path.yml"])
		assert(scenario.partners[1] == "collect-raid", "recipe scenario lacks its partner genre")
		local pack = serde.decode("yaml", a.files["econ.yml"]).genre_contract
		assert(pack.recipe == "arena-bounty-v1", "pack does not name the recipe")
		local executor = genresim.create(pack, registry, 7)
		for _, check in Recipe.driver.run(executor, input) do
			assert(check.ok, check.name)
		end
		local first = genresim.simulate(pack, registry, input, 2, 1)
		local second = genresim.simulate(pack, registry, input, 2, 1)
		local metrics = first["arena-bounty-v1"]
		assert(
			metrics.sinkTotal == 50
				and metrics.sourceTotal >= Bounty.BOUNTY
				and metrics.balances["bounty-sim-2"] == 0
				and metrics.acceptedActions == 7
				-- the loser's source purchase on an empty wallet is the one refusal
				and metrics.rejectedActions == 1,
			"coupled wallet metrics incorrect"
		)
		assert(genresim.render("bounty", first) == genresim.render("bounty", second), "simulation is not deterministic")
	end,
}
