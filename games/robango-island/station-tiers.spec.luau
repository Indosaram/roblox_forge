--!strict
-- G6: recipeDetails.stationTier is enforced at craft-reserve, and the tier-2/3 kiln and
-- tier-3 workbench exist as placeable stations on the catalog upgrade path.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Rules = require("../../core/domain/survival/Content")
local Workshop = require("../../genres/survival-coop/module/Workshop")
local Job = require("../../core/domain/crafting/Job")
local Inventory = require("../../core/domain/inventory/Inventory")

-- The canonical document the server crafts against (specs run from the repository root).
local Content: any = assert(Rules.canonicalize(serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))))

local function bag(items: { { string } }): Inventory.State
	local catalog = Job.catalog(Content :: any)
	local state = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for index, entry in items do
		state = assert(Inventory.add(state, catalog, {
			itemId = "i" .. index,
			catalogId = entry[1],
			quantity = tonumber(entry[2]) :: number,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = {},
		}, state.version))
	end
	return state
end

local function reserve(stationId: string, kind: string, tier: number?): (any, string?)
	local inventory = bag({ { "iron-ore", "1" }, { "charcoal", "1" } })
	return Workshop.reserve(
		Workshop.new("alice"),
		inventory,
		{ actorId = "alice", sessionEpoch = 1, requestId = "r" },
		Content :: any,
		"rev",
		"smelt-steel",
		0,
		{ carriedContainer = "bag", stationId = stationId, stationKind = kind, stationTier = tier, inReach = true }
	)
end

return {
	["smelt-steel at a tier-1 kiln is refused STATION_TIER"] = function()
		local _, err = reserve("station.kiln.t1", "kiln", 1)
		assert(err == "STATION_TIER", "tier-1 kiln must refuse smelt-steel (K3), got " .. tostring(err))
		local _, declared = reserve("home:kiln", "kiln", nil)
		assert(declared == "STATION_TIER", "an undeclared kiln defaults to its structure tier 1")
		local _, mid = reserve("station.kiln.t2", "kiln", 2)
		assert(mid == "STATION_TIER", "tier-2 kiln must refuse a K3 recipe")
		local candidate, reason = reserve("station.kiln.t3", "kiln", 3)
		assert(candidate, "tier-3 kiln accepts smelt-steel: " .. tostring(reason))
	end,
	["every stationTier recipe detail projects to the craft gate"] = function()
		local tiers = {}
		for _, recipe in Content.recipes do
			tiers[recipe.id] = recipe.tier
		end
		local checked = 0
		for _, detail in (Content :: any).recipeDetails do
			if (detail.stationTier or 1) > 1 then
				checked += 1
				assert(tiers[detail.id] == detail.stationTier, "recipe tier missing for " .. detail.id)
			end
		end
		assert(checked >= 35, "expected the catalog's tier-2/3 recipes, got " .. checked)
	end,
	["tier-2/3 kiln and tier-3 workbench are placeable stations on the upgrade path"] = function()
		local structures, recipes = {}, {}
		for _, structure in Content.structures do
			structures[structure.id] = structure
		end
		for _, recipe in Content.recipes do
			recipes[recipe.id] = recipe
		end
		for id, expected in { ["workbench-t2"] = 2, ["workbench-t3"] = 3, ["kiln-t2"] = 2, ["kiln-t3"] = 3 } do
			local structure = structures[id]
			assert(structure and structure.station and structure.tier == expected, "missing tiered station " .. id)
			assert(structure.cost[1].item == id .. "-kit", id .. " is built from its kit")
		end
		-- Kit inputs and the station they need follow the auxiliary spec upgrade rows (target B1/B2/K1/K2).
		for kit, station in
			{
				["workbench-t2-kit"] = { "workbench", 1 },
				["workbench-t3-kit"] = { "workbench", 2 },
				["kiln-t2-kit"] = { "kiln", 1 },
				["kiln-t3-kit"] = { "kiln", 2 },
			}
		do
			local recipe = recipes[kit]
			assert(recipe and recipe.station == station[1], kit .. " crafted at " .. station[1])
			assert((recipe.tier or 1) == station[2], kit .. " needs tier " .. station[2])
			local upgrade
			for _, row in (Content :: any).operations do
				if row.id == "upgrade-" .. string.gsub(kit, "%-kit$", "") then
					upgrade = row
				end
			end
			assert(upgrade, "upgrade operation for " .. kit)
			local want = {}
			for _, input in upgrade.inputs do
				want[input.item] = input.quantity
			end
			assert(#recipe.inputs == #upgrade.inputs, kit .. " input count")
			for _, actual in recipe.inputs do
				assert(want[actual.item] == actual.quantity, kit .. " uses the upgrade operation inputs")
			end
		end
	end,
}
