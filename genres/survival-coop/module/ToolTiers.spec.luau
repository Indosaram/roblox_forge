--!strict
local ToolTiers = require("./ToolTiers")

local content = {
	toolPolicy = {
		families = {
			{
				id = "axe",
				members = {
					{ item = "stone-axe", tier = 1 },
					{ item = "starter-axe", tier = 1 },
					{ item = "axe-t1", tier = 2 },
				},
			},
			{ id = "pick", members = { { item = "stone-pick", tier = 1 }, { item = "pickaxe-t1", tier = 2 } } },
		},
	},
}

return {
	["a node accepts any same-family tool at or above its required tier"] = function()
		assert(ToolTiers.accepts(content, "starter-axe", "starter-axe"), "exact")
		assert(ToolTiers.accepts(content, "starter-axe", "stone-axe"), "same tier sibling")
		assert(ToolTiers.accepts(content, "starter-axe", "axe-t1"), "higher tier")
		assert(not ToolTiers.accepts(content, "axe-t1", "stone-axe"), "lower tier refused")
		assert(not ToolTiers.accepts(content, "starter-axe", "pickaxe-t1"), "other family refused")
		assert(not ToolTiers.accepts(content, "starter-axe", "spear"), "unranked tool refused")
	end,
	["without a policy a node accepts only its declared tool"] = function()
		assert(ToolTiers.accepts({}, "starter-axe", "starter-axe"), "exact")
		assert(not ToolTiers.accepts({}, "starter-axe", "stone-axe"), "no policy, no sibling")
		assert(not ToolTiers.accepts(nil, "starter-axe", "axe-t1"), "nil content")
	end,
	["a family tool is reported as replaceable so the notice can say 'or better'"] = function()
		assert(ToolTiers.hasFamily(content, "starter-axe"), "axe family")
		assert(not ToolTiers.hasFamily(content, "starter-club"), "unranked")
		assert(not ToolTiers.hasFamily({}, "starter-axe"), "no policy")
	end,
}
