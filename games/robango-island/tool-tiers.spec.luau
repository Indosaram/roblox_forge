--!strict
-- Lead decision p38: any owned axe at or above the required tier cuts wood. The tutorial
-- teaches the Flint Hatchet (stone-axe); it must clear the a1.s1 wood mission by itself.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Content: any = require("./src/shared/SurvivalContent")
local qa = require("../../cli/forge/commands/qa")
local qaharness = require("../../cli/forge/lib/qaharness")
local registryLib = require("../../cli/forge/lib/genreregistry")

local function tierOf(item: string): (string?, number?)
	for _, family in (Content.toolPolicy or { families = {} }).families do
		for _, member in family.members do
			if member.item == item then
				return family.id, member.tier
			end
		end
	end
	return nil, nil
end

return {
	["every tool a gather node requires belongs to a tier family"] = function()
		for _, layout in Content.layouts do
			for _, node in layout.resourceNodes do
				if node.tool and node.tool ~= "starter-club" then
					assert(tierOf(node.tool), node.id .. ": " .. node.tool .. " has no tool tier family")
				end
			end
		end
		local axe, axeTier = tierOf("stone-axe")
		local wood, woodTier = tierOf("starter-axe")
		assert(axe == wood and (axeTier :: number) >= (woodTier :: number), "Flint Hatchet ranks with the starter axe")
	end,
	["a player holding only the Flint Hatchet completes the a1.s1 wood mission"] = function()
		local scenario = serde.decode(
			"yaml",
			fs.readFile("games/robango-island/qa-scenarios/survival-coop.archipelago-first-stage-stone-axe.yml")
		)
		local registry = assert(registryLib.discover(nil))
		local target, errors = qa.loadTarget("robango-island", registry, nil, nil)
		assert(target, table.concat(errors, "; "))
		local outcome = qaharness.runNative(scenario, target :: qaharness.Target)
		assert(outcome.ok, table.concat(outcome.failures, "; "))
	end,
}
