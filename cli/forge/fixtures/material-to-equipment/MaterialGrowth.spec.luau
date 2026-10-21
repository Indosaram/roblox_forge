--!strict
local Materials = require("../../../../core/domain/crafting/MaterialGrowth")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")

local function raw(item: string, level: number, quantity: number): Materials.Material
	local material = Materials.raw(Content, item, level, 0, nil)
	material.quantity = quantity
	return material
end

return {
	["all six processes apply authored deltas and preserve the minimum selected grade"] = function()
		for _, example in
			{
				{ id = "dry-twig", item = "branch", level = 10, key = "hardness", delta = 1 },
				{ id = "tan-hide", item = "hide", level = 10, key = "flexibility", delta = 2 },
				{ id = "polish-stone", item = "stone", level = 10, key = "sharpness", delta = 2 },
				{ id = "smelt-copper", item = "copper-ore", level = 20, key = "hardness", delta = 2 },
				{ id = "ferment-corn", item = "corn", level = 10, key = "nutrition", delta = 2 },
				{ id = "compost-leaves", item = "leaves", level = 10, key = "fertility", delta = 2 },
			}
		do
			local recipe = Materials.recipe(Content, example.id)
			assert(recipe, "authored process exists")
			local inputs = {}
			for _, required in recipe.inputs do
				table.insert(inputs, raw(required.item, example.level, required.quantity))
			end
			local result = assert(Materials.craft(Content, example.id, inputs), "legal process succeeds")
			assert(result.budget == 2 and result.quality == 0, "process consumes one budget not grade")
			assert(
				result.attributes[example.key] == math.clamp(inputs[1].attributes[example.key] + example.delta, 0, 10),
				"authored attribute delta"
			)
		end
	end,
	["same recipe selected primary properties differ auxiliaries never contribute"] = function()
		local branch, stone = raw("branch", 10, 3), raw("stone", 10, 2)
		local first = assert(Materials.craft(Content, "starter-axe", { branch, stone }), "progression contract 14")
		branch.attributes.sharpness = 10
		local second = assert(Materials.craft(Content, "starter-axe", { branch, stone }), "progression contract 16")
		assert(first.attributes.sharpness ~= second.attributes.sharpness, "progression contract 17")
		local leather = raw("hide", 10, 1)
		leather = assert(Materials.craft(Content, "tan-hide", { leather }), "progression contract 19")
		leather.quantity = 5
		leather.quality = 2
		local auxiliary = raw("fiber", 60, 2)
		auxiliary.item = "dried-fiber"
		auxiliary.attributes.hardness = 10
		local top = assert(Materials.craft(Content, "temperate-top", { leather, auxiliary }), "progression contract 25")
		assert(
			top.level == 10 and top.quality == 2 and top.attributes.hardness == leather.attributes.hardness,
			"progression contract 26"
		)
	end,
	["six authored processes clamp attributes preserve grade origin and consume budgets"] = function()
		local hide = raw("hide", 60, 1)
		hide.sourceSpeciesId = "tyrannosaurus"
		local leather = assert(Materials.craft(Content, "tan-rex-hide", { hide }), "progression contract 31")
		assert(
			leather.sourceSpeciesId == "tyrannosaurus" and leather.budget == 2 and leather.attributes.flexibility == 6,
			"progression contract 32"
		)
		assert(leather.quality == 0 and leather.level == 60 and leather.history ~= "", "progression contract 33")
		hide.sourceSpeciesId = "boar"
		local _, origin = Materials.craft(Content, "tan-rex-hide", { hide })
		assert(origin == "SOURCE_SPECIES_GATE", "progression contract 36")
		hide.budget = 0
		local _, budget = Materials.craft(Content, "tan-hide", { hide })
		assert(budget == "PROCESSING_BUDGET" and hide.budget == 0, "progression contract 39")
		hide.budget = 3
		hide.attributes.flexibility = 9
		assert(
			assert(Materials.craft(Content, "tan-hide", { hide })).attributes.flexibility == 10,
			"progression contract 42"
		)
		local _, level = Materials.craft(Content, "tan-hide", { raw("hide", 10, 2) })
		assert(level == "INPUT_MISMATCH", "progression contract 44")
		local low = raw("hide", 10, 1)
		low.level = 1
		local _, gate = Materials.craft(Content, "tan-hide", { low })
		assert(gate == "MATERIAL_LEVEL_GATE", "progression contract 48")
	end,
	["refunds are seeded primary unit trials and never touch auxiliary inputs"] = function()
		local inputs = { raw("branch", 10, 3), raw("fiber", 10, 4) }
		assert(next(Materials.refunds(inputs, { "branch" }, 0, 74, "job")) == nil, "progression contract 52")
		local certain = Materials.refunds(inputs, { "branch" }, 1, 74, "job")
		assert(certain.branch == 3 and certain.fiber == nil, "progression contract 54")
		local a = Materials.refunds(inputs, { "branch" }, 0.1, 74, "job")
		local b = Materials.refunds(inputs, { "branch" }, 0.1, 74, "job")
		assert(a.branch == b.branch, "progression contract 57")
	end,
}
