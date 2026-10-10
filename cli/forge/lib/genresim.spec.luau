--!strict
local registryLib = require("./genreregistry")
local genresim = require("./genresim")
return {
	["fixture driver mutates actual executor and reports accepted actions"] = function()
		local registry, errors = registryLib.discover("cli/forge/fixtures/genres")
		assert(registry ~= nil, table.concat(errors, "; "))
		local pack = { api = 1, order = { "fixture-counter" }, configs = { ["fixture-counter"] = { target = 2 } } }
		local input = {
			mode = "new" :: "new",
			slug = "counter",
			pascal = "Counter",
			title = "Counter",
			concept = "",
			seed = 7,
			teams = { "Red", "Blue" },
			debugName = "CounterDebug",
			guiName = "CounterGui",
		}
		local a = genresim.simulate(pack, registry, input, 2, 1)
		local b = genresim.simulate(pack, registry, input, 2, 1)
		assert(a["fixture-counter"].acceptedActions == 2, "missing actual actions")
		assert(a["fixture-counter"].balances["1"] == 1, "adapter mutation missing")
		assert(genresim.render("counter", a) == genresim.render("counter", b), "nondeterministic report")
	end,
}
