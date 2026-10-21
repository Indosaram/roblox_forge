--!strict
local Graph = require("../../lib/contentgraph")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local categories = assert(Content.skillCategories, "v2 skill categories")
local nodes = assert(Content.skillNodes, "v2 skill nodes")

return {
	["real Robango content has finite material station skill and development witnesses"] = function()
		local graph = Graph.check(Content)
		assert(graph.ok, "real content progression graph must be reachable")
		assert(graph.counts.skillNodes == 72 and #categories == 12, "progression contract 9")
		assert(#graph.rankPrefix >= 5, "progression contract 10")
		for _, prefix in graph.rankPrefix do
			assert(prefix.available >= prefix.required, "progression contract 12")
		end
	end,
	["cyclic mandatory materials and skills are detected not hidden by catalog profiles"] = function()
		local mutated = table.clone(Content)
		local changedNodes = table.clone(nodes)
		changedNodes[1] = table.clone(changedNodes[1])
		changedNodes[1].prerequisites = { changedNodes[1].id }
		mutated.skillNodes = changedNodes
		assert(not Graph.check(mutated).ok, "progression contract 20")
		mutated = table.clone(Content)
		mutated.recipes = table.clone(Content.recipes)
		for i, recipe in mutated.recipes do
			if recipe.id == "dry-twig" then
				local row = table.clone(recipe)
				row.inputs = { { item = "dried-wood", quantity = 1 } }
				mutated.recipes[i] = row
			end
		end
		assert(not Graph.check(mutated).ok, "progression contract 30")
	end,
}
