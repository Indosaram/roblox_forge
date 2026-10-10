--!strict
local qa = require("../commands/qa")
local registryLib = require("./genreregistry")

return {
	["owned bootstrap requires explicit Studio config and evidence options"] = function()
		local registry: registryLib.Registry = { root = "genres", order = {}, packages = {}, runtimes = {} }
		local base = { "qa", "run", "--pack", "primal-isles", "--scenario", "release-first-play", "--bootstrap-owned" }
		local suffixes: { { string } } = {
			{},
			{ "--native", "--studio-receipt", "unused.json", "--evidence", "unused-output.json" },
			{ "--studio", "--studio-receipt", "unused.json" },
			{ "--studio", "--evidence", "unused-output.json" },
			{ "--studio", "--studio-receipt", "unused.json", "--evidence", "unused-output.json", "--bootstrap-owned" },
		}
		for _, suffix in suffixes do
			local args = table.clone(base)
			for _, value in suffix do
				table.insert(args, value)
			end
			assert(not qa.runScenario(args, registry), "incomplete or duplicate bootstrap must reject")
		end
	end,
}
