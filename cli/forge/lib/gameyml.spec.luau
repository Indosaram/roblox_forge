--!strict
-- Specs for the pure game.yml validation: a scaffold's TBD placeholders must be
-- rejected and a filled-in pack must pass.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local GameYml = require("./gameyml")

local function decode(path: string): any
	return serde.decode("yaml", fs.readFile(path))
end

return {
	["malformed sparse duplicate and nonstring genre selections fail"] = function()
		local selections: { any } = { { "alpha", "alpha" }, { [2] = "alpha" }, { 1 } }
		for _, genres in selections do
			assert(not GameYml.validate({
				name = "Fixture",
				slug = "fixture",
				genres = genres,
				art_style = "low-poly",
				poly_budget = { prop = 800 },
			}).ok, "malformed genre list accepted")
		end
	end,
	["rejects the scaffolded fixture with TBD art_style and poly_budget"] = function()
		local result = GameYml.validate(decode("cli/forge/fixtures/game-tbd.yml"))
		assert(not result.ok, "a TBD game.yml must fail validation")
		local joined = table.concat(result.errors, "\n")
		assert(
			string.find(joined, "'art_style' is still TBD", 1, true) ~= nil,
			"reason should name art_style: " .. joined
		)
		assert(
			string.find(joined, "'poly_budget' is still TBD", 1, true) ~= nil,
			"reason should name poly_budget: " .. joined
		)
	end,

	["accepts a filled-in game.yml"] = function()
		local result = GameYml.validate({
			name = "Kaiju Egg Raiders",
			slug = "kaiju-egg-raiders",
			genres = { "collect-raid" },
			art_style = "chunky low-poly toy kaiju",
			poly_budget = { kaiju = 3000, egg = 600, prop = 800, world_parts_max = 6000 },
		})
		assert(result.ok, "a complete game.yml must pass: " .. table.concat(result.errors, "; "))
	end,

	["rejects a non-positive poly budget"] = function()
		local result = GameYml.validate({
			name = "Fixture Pack",
			slug = "fixture-pack",
			genres = { "collect-raid" },
			art_style = "flat toon",
			poly_budget = { kaiju = 0 },
		})
		assert(not result.ok, "a zero budget must fail")
		assert(
			string.find(table.concat(result.errors, "\n"), "poly_budget.kaiju must be a positive integer", 1, true)
				~= nil,
			"reason should name the offending key"
		)
	end,
}
