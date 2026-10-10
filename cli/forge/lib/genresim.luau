--!strict
local Executor = require("../../../core/domain/genre/Executor")
local Contract = require("../../../core/domain/genre/Contract")
local genrecontract = require("./genrecontract")
local registryLib = require("./genreregistry")
local Synth = require("../../../core/domain/procgen/Synth")
local M = {}
function M.create(pack: Contract.PackConfig, registry: registryLib.Registry, seed: number): Executor.Executor
	local errors = genrecontract.validatePack(pack, registry.runtimes)
	assert(#errors == 0, table.concat(errors, "; "))
	local descriptors = {}
	for _, id in pack.order do
		table.insert(descriptors, registry.runtimes[id])
	end
	local rng = Synth.rng(seed)
	local epoch = 0
	local executor = Executor.new(pack, descriptors, {
		now = function()
			return epoch
		end,
		roll = rng.next,
		emit = function() end,
	})
	local advance = executor.advance
	executor.advance = function(value)
		epoch = value
		advance(value)
	end
	return executor
end
function M.simulate(
	pack: Contract.PackConfig,
	registry: registryLib.Registry,
	input: genrecontract.GenerateInput,
	players: number,
	days: number
): { [string]: genrecontract.SimMetrics }
	local results = {}
	local order, owner, errors = registryLib.select(registry, pack.order, pack.recipe)
	assert(order, table.concat(errors, "; "))
	local driverIds: { string } = if owner then { owner.id } else pack.order
	for _, id in driverIds do
		local executor = M.create(pack, registry, input.seed)
		local generator = registry.packages[id].generator
		local recipe = if owner and owner.recipe and generator.recipes then generator.recipes[owner.recipe.id] else nil
		assert(owner == nil or recipe ~= nil, "recipe simulation capability missing")
		local driver = if recipe then recipe.driver else generator.driver
		local metrics = driver.simulate(executor, input, players, days)
		assert(
			Executor.data(metrics) and metrics.acceptedActions > 0,
			"simulation produced no accepted actions: " .. id
		)
		for _, field in { "sourceTotal", "sinkTotal", "acceptedActions", "rejectedActions" } do
			assert(Executor.finite(metrics[field]) and metrics[field] >= 0, "invalid simulation metric: " .. field)
		end
		results[if owner and owner.recipe then owner.recipe.id else id] = metrics
	end
	return results
end
function M.render(pack: string, results: { [string]: genrecontract.SimMetrics }): string
	local ids = {}
	for id in results do
		table.insert(ids, id)
	end
	table.sort(ids)
	local lines = {
		"# Genre simulation - " .. pack,
		"",
		"| Genre | Sources | Sinks | Accepted | Rejected |",
		"|---|---:|---:|---:|---:|",
	}
	for _, id in ids do
		local metrics = results[id]
		table.insert(
			lines,
			string.format(
				"| %s | %g | %g | %d | %d |",
				id,
				metrics.sourceTotal,
				metrics.sinkTotal,
				metrics.acceptedActions,
				metrics.rejectedActions
			)
		)
	end
	return table.concat(lines, "\n") .. "\n"
end
return M
