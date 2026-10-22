--!strict
-- Specs for craftsim: same seed gives the same JSON, and a milestone depends on real recipe inputs.
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local craftsim = require("./craftsim")

local function load(): any
	return serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
end

local function run(content: any, seed: number): any
	return craftsim.simulate(content, {
		seed = seed,
		hours = 2,
		startingBalance = 100,
		starter = { { catalogId = "fiber", quantity = 12 }, { catalogId = "berry", quantity = 3 } },
	})
end

--- The authored stone axe needs flint, flint nodes need the starter pickaxe, and that needs a
--- workbench: so the pickaxe is crafted strictly before the axe.
local function axeWaitsOnFlint(result: any): boolean
	local pickaxe, axe = nil, nil
	for _, row in result.firstCrafts do
		pickaxe = if row.id == "starter-pickaxe" then row.seconds else pickaxe
		axe = if row.id == "stone-axe" then row.seconds else axe
	end
	return axe ~= nil and pickaxe ~= nil and pickaxe < axe and result.milestones.stoneAxe.seconds == axe
end

return {
	["same seed gives byte-identical JSON"] = function()
		local content = load()
		local first = serde.encode("json", run(content, 7))
		local second = serde.encode("json", run(content, 7))
		assert(first == second, "craftsim is not deterministic for seed 7")
		local decoded = serde.decode("json", first)
		assert(decoded.schemaVersion == 1 and #decoded.hourly == 2 and decoded.robuxSpent == 0, "shape")
		assert(decoded.final.coins == decoded.hourly[2].coins, "final equals the last hour")
	end,
	["stone axe milestone waits on the authored flint input"] = function()
		local content = load()
		-- Fails if content.yml drops the stone-axe flint input.
		assert(axeWaitsOnFlint(run(content, 1)), "stone axe must wait for the pickaxe-mined flint")
		-- Mutation witness: without the input the same assertion is false.
		for _, recipe in content.recipes do
			if recipe.id == "stone-axe" then
				recipe.inputs = {}
			end
		end
		assert(not axeWaitsOnFlint(run(content, 1)), "assertion must detect a removed recipe input")
	end,
}
