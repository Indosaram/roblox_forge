--!strict
-- G6: recipeDetails.stationTier is enforced at craft-reserve, and the tier-2/3 kiln and
-- tier-3 workbench exist as placeable stations on the catalog upgrade path.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Rules = require("../../core/domain/survival/Content")
local Text = require("../../genres/survival-coop/module/CharacterText")
local HudLocale = require("../../genres/survival-coop/module/SurvivalHUDLocale")
local NAMES = require("./PackText.fixture").names -- also installs the strings.csv lookup the genre text tables read
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
	-- p134 v77 (journey6h @126m): g46 asked for pickaxe-t2 and the HUD line never said the bench must be
	-- tier 2, so the craft was refused STATION_TIER at the home bench with no way to learn why.
	["the guide line for a tier-2 recipe names the tier the station must have"] = function()
		local ch = { level = 40, points = 800, definitions = {}, progress = {} }
		for _, guide in Content.guides do
			ch.definitions[guide.id] = guide.id ~= "rw.g46.t2-tool"
		end
		local ko = assert(Text.guideObjective("ko-kr", Content, ch, NAMES("ko-kr"), true, true), "a line")
		assert(string.find(ko, "2단계 작업대", 1, true), "korean names the tier-2 bench: " .. ko)
		local en = assert(Text.guideObjective("en-us", Content, ch, NAMES("en-us"), true, true), "a line")
		assert(string.find(en, "Needs a tier-2", 1, true), "english names the tier: " .. en)
		assert(string.find(en, NAMES("en-us").workbench, 1, true), "english names the bench: " .. en)
		-- A base-tier recipe keeps the plain inputs line (no tier sentence).
		local plain = assert(
			Text.guideObjective(
				"en-us",
				Content,
				{ level = 16, points = 400, definitions = {} },
				NAMES("en-us"),
				true,
				true
			)
		)
		assert(not string.find(plain, "tier-", 1, true), "tier-free step stays tier-free: " .. plain)
	end,
	["STATION_TIER reads as a station rank refusal, never the generic supplies line"] = function()
		local ko = HudLocale.refusal("ko-kr", "STATION_TIER")
		assert(string.find(ko, "시설", 1, true) and ko ~= HudLocale.text("ko-kr", "unknown"), ko)
		local en = HudLocale.refusal("en-us", "STATION_TIER")
		assert(string.find(en, "upgraded station", 1, true), en)
		assert(en ~= HudLocale.text("en-us", "unknown"), "not the generic refusal")
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
