--!strict
local Recipe = require("./recipe-generator")
local Grow = require("../grow-harvest/module/Adapter.fixture")
local Survival = require("./module/Adapter.fixture")
local registryLib = require("../../cli/forge/lib/genreregistry")
local generate = require("../../cli/forge/lib/genregenerate")
local genresim = require("../../cli/forge/lib/genresim")
local serde = require("@lune/serde")
local input = {
	mode = "new" :: "new",
	slug = "garden",
	pascal = "Garden",
	title = "Garden",
	concept = "",
	seed = 7,
	teams = { "Red", "Blue" },
	debugName = "GardenDebug",
	guiName = "GardenGui",
}
return {
	["normalization clones configs and leaves standalone defaults intact"] = function()
		local configs = { ["grow-harvest"] = Grow.config(), ["survival-coop"] = table.clone(Survival.config) }
		local normalized = Recipe.normalize(configs)
		assert(
			normalized["grow-harvest"].startingBalance == 0 and normalized["survival-coop"].startingBalance == 0,
			"currency defaults not normalized"
		)
		assert(
			configs["grow-harvest"].startingBalance == 10 and configs["survival-coop"].startingBalance == 10,
			"standalone defaults mutated"
		)
		normalized["grow-harvest"].crops.carrot.sellPrice = 99
		assert(configs["grow-harvest"].crops.carrot.sellPrice == 10, "normalization aliases config")
	end,
	["both selection orders produce canonical data and coupled metrics"] = function()
		local registry, errors = registryLib.discover()
		assert(registry, table.concat(errors, "; "))
		local a = generate.assemble(registry, { "grow-harvest", "survival-coop" }, input, ".omo/wip/garden")
		local b = generate.assemble(registry, { "survival-coop", "grow-harvest" }, input, ".omo/wip/garden")
		assert(a.files["econ.yml"] == b.files["econ.yml"], "selection order changed generated config")
		local pack = serde.decode("yaml", a.files["econ.yml"]).genre_contract
		local executor = genresim.create(pack, registry, 7)
		for _, check in Recipe.driver.run(executor, input) do
			assert(check.ok, check.name)
		end
		local first = genresim.simulate(pack, registry, input, 1, 1)
		local second = genresim.simulate(pack, registry, input, 1, 1)
		local metrics = first["garden-defense-v1"]
		assert(
			metrics.sourceTotal == 15 and metrics.sinkTotal == 10 and metrics.balances["garden-sim-1"] == 5,
			"coupled wallet metrics incorrect"
		)
		assert(genresim.render("garden", first) == genresim.render("garden", second), "simulation is not deterministic")
	end,
}
