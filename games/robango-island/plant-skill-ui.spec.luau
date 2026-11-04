--!strict
local Harness = require("./PanelHarness.fixture")
local Content: any = require("./src/shared/SurvivalContent")
local Tree = require("../../core/domain/progression/SkillTree")

local function find(h: any, name: string): any
	for _, item in h.playerGui:GetDescendants() do
		if item.Name == name then
			return item
		end
	end
	return nil
end

return {
	["skills show proficiency gate before offering a refused purchase"] = function()
		local h = Harness.harness({ realHud = true, locale = "en-us" })
		local tree: any = Tree.new(Content, Content.progressionPolicy.tree)
		tree.sp = 100
		tree.paid.processing_1 = 2
		h.packet({ snapshots = { ["survival-coop"] = { progression = tree }, survivalExtensions = {} } })
		h.hud.open("skills")
		h.click(find(h, "skill-processing"))
		local need = find(h, "SkillNeed")
		assert(need and string.find(need.Text, "0 / 3", 1, true), "proficiency requirement shown")
		-- Fun-first mastery curve: proficiency 3 is 5 category actions from zero.
		assert(need and string.find(need.Text, "5", 1, true), "remaining training count shown")
		local learn = find(h, "learn-processing_2")
		assert(learn and learn.AutoButtonColor == false, "proficiency-locked Learn is disabled")
	end,
	["farm can move carried seed and water into home storage"] = function()
		local h = Harness.harness({ locale = "en-us" })
		local home = {
			homeId = "home:1",
			structures = { plot = { kind = "farm-plot", position = { x = 0, y = 0, z = 0 } } },
			plots = {},
			storage = { items = {} },
		}
		local items = {}
		for _, id in { "corn-seed", "water" } do
			items[id] =
				{ itemId = id, catalogId = id, quantity = 1, qualityMilli = 1000, durabilityMilli = 0, attributes = {} }
		end
		h.packet({
			snapshots = {
				["survival-coop"] = { inventory = { bag = { kind = "carried", items = items, reservations = {} } } },
				survivalExtensions = { home = home },
			},
		})
		h.click(h.menu:FindFirstChild("Dock-farm"))
		local seed = find(h, "Seed-1-corn")
		assert(seed, "corn seed picker")
		h.click(seed)
		assert(find(h, "Store-corn-seed"), "carried seed has home deposit affordance")
		assert(find(h, "Store-water"), "carried water has home deposit affordance")
	end,
}
