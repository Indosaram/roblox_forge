--!strict
local Kit = require("./JourneyKit.fixture")
local Content: any = require("./src/shared/SurvivalContent")

return {
	["bow input chain requires a campfire even when the harbor workbench exists"] = function()
		local bow = nil
		for _, recipe in Content.recipes do
			if recipe.id == "bow-t1" then
				bow = recipe
			end
		end
		assert(bow ~= nil, "bow recipe exists")
		local function harbor(kind: string): boolean
			return kind == "workbench"
		end
		assert(Kit.missingStation(Content.recipes, bow, function(): number
			return 0
		end, harbor) == "campfire", "route to processing station before attempting bow")
		assert(Kit.missingStation(Content.recipes, bow, function(): number
			return 4
		end, harbor) == nil, "stocked bow inputs only need the existing workbench")
		assert(Kit.missingStation(Content.recipes, bow, function(): number
			return 0
		end, function(): boolean
			return true
		end) == nil, "fully equipped island can process and craft")
	end,
}
