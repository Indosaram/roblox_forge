--!strict
local Skills = require("./Skills")
local Content = require("../../../core/domain/survival/Content")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")

local IDS = { "building", "butchery", "gathering", "hearth", "tailoring", "woodcraft" }

local function document(withSkills: boolean): Content.Document
	local disciplines = {}
	for _, id in IDS do
		table.insert(disciplines, { id = id, thresholds = { 10, 30, 60, 100 } })
	end
	disciplines[6].tools = { { item = "axe", tier = 1 }, { item = "steel-axe", tier = 2 } }
	local raw: any = {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		items = {
			{ id = "axe", name = "Axe", stackMax = 1, weightMilli = 100, maxDurabilityMilli = 1000 },
			{ id = "steel-axe", name = "Steel Axe", stackMax = 1, weightMilli = 100, maxDurabilityMilli = 1000 },
		},
	}
	if withSkills then
		raw.skills = { baseStep = 1, disciplines = disciplines }
	end
	return assert(Content.canonicalize(raw))
end

local function bag(items: { { id: string, catalogId: string, durability: number } }): Inventory.State
	local content = document(true)
	local catalog = Job.catalog(content)
	local state = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for _, item in items do
		state = assert(Inventory.add(state, catalog, {
			itemId = item.id,
			catalogId = item.catalogId,
			quantity = 1,
			qualityMilli = 1000,
			durabilityMilli = item.durability,
			attributes = {},
		}, state.version))
	end
	return state
end

local function raises(run: () -> (), fragment: string): boolean
	local ok, err = (pcall :: any)(run)
	return not ok and string.find(tostring(err), fragment, 1, true) ~= nil
end

return {
	["a pack without a skills section has no mastery catalog"] = function()
		assert(Skills.catalog(document(false)) == nil, "no skills section means inert skills")
	end,

	["each of six disciplines advances independently from action XP"] = function()
		local catalog = assert(Skills.catalog(document(true)))
		assert(#catalog.order == 6, "six disciplines")
		local state = Skills.new(catalog)
		local after, gained = Skills.award(catalog, state, "gathering", 12, 0)
		assert(gained == 10, "base step 1 with no tool caps gathering at level 1 (10 xp)")
		assert(Skills.level(catalog, after, "gathering") == 1, "gathering reached level 1")
		for _, id in IDS do
			if id ~= "gathering" then
				assert(after.disciplines[id].xp == 0, id .. " untouched by a gathering action")
			end
		end
		assert(state.disciplines.gathering.xp == 0, "award never mutates its input")
	end,

	["cap is tool tier plus mastery step and excess xp is not gained"] = function()
		local catalog = assert(Skills.catalog(document(true)))
		local state = Skills.new(catalog)
		assert(Skills.cap(catalog, state, "woodcraft", 0) == 1, "no tool: cap = step")
		assert(Skills.cap(catalog, state, "woodcraft", 2) == 3, "tier 2 tool: cap = 2 + 1")
		assert(Skills.cap(catalog, state, "woodcraft", 9) == 4, "cap bounded by declared thresholds")
		local capped, gained = Skills.award(catalog, state, "woodcraft", 500, 0)
		assert(gained == 10 and capped.disciplines.woodcraft.xp == 10, "xp stops at the cap threshold")
		local again, more = Skills.award(catalog, capped, "woodcraft", 5, 0)
		assert(more == 0 and again.disciplines.woodcraft.xp == 10, "at cap nothing more is gained")
		local tooled = Skills.award(catalog, capped, "woodcraft", 500, 2)
		assert(tooled.disciplines.woodcraft.xp == 60, "a better tool raises the ceiling")
	end,

	["tool tier reads only usable declared tools"] = function()
		local catalog = assert(Skills.catalog(document(true)))
		local items = bag({
			{ id = "a", catalogId = "axe", durability = 1000 },
			{ id = "s", catalogId = "steel-axe", durability = 0 },
		})
		assert(Skills.toolTier(catalog, "woodcraft", items) == 1, "broken steel axe does not count")
		assert(Skills.toolTier(catalog, "woodcraft", items, { s = true }) == 0, "equipped filter applies")
		assert(Skills.toolTier(catalog, "gathering", items) == 0, "axe is not a gathering tool")
	end,

	["character level is the display sum of discipline levels"] = function()
		local catalog = assert(Skills.catalog(document(true)))
		local state = Skills.new(catalog)
		state = Skills.award(catalog, state, "gathering", 10, 0)
		state = Skills.award(catalog, state, "woodcraft", 30, 2)
		assert(Skills.displayLevel(catalog, state) == 3, "1 + 2")
	end,

	["respec refunds every point deterministically with no reroll"] = function()
		local catalog = assert(Skills.catalog(document(true)))
		local state = Skills.new(catalog)
		state = Skills.award(catalog, state, "gathering", 10, 0)
		state = Skills.award(catalog, state, "woodcraft", 60, 2)
		local first = Skills.respec(catalog, state)
		local second = Skills.respec(catalog, state)
		assert(first.pool == 70, "full refund of all earned xp")
		assert(Skills.displayLevel(catalog, first) == 0, "levels cleared")
		for _, id in IDS do
			assert(first.disciplines[id].xp == 0 and first.disciplines[id].step == 1, "steps kept")
			assert(second.disciplines[id].xp == first.disciplines[id].xp, "same input, same output")
		end
		assert(second.pool == first.pool, "deterministic pool")
		local spent = assert(Skills.allocate(catalog, first, "hearth", 10, 0))
		assert(spent.pool == 60 and Skills.level(catalog, spent, "hearth") == 1, "pool reallocates")
		local _, capped = Skills.allocate(catalog, first, "hearth", 11, 0)
		assert(capped == "SKILL_CAP", "reallocation obeys the cap")
		local _, short = Skills.allocate(catalog, first, "hearth", 71, 9)
		assert(short == "INSUFFICIENT_POOL", "cannot spend more than refunded")
	end,

	["save round trips and refuses foreign or malformed data"] = function()
		local catalog = assert(Skills.catalog(document(true)))
		local state = Skills.award(catalog, Skills.new(catalog), "tailoring", 25, 1)
		local saved = Skills.save(state)
		local restored = Skills.fromSave(saved, catalog)
		assert(restored.disciplines.tailoring.xp == 25 and restored.pool == 0, "round trip")
		local future = table.clone(saved)
		future.saveVersion = 2
		assert(
			raises(function()
				Skills.fromSave(future, catalog)
			end, "UNSUPPORTED_SKILLS_SAVE"),
			"newer skills save refused"
		)
		local extra = table.clone(saved)
		extra.luck = 1
		assert(
			raises(function()
				Skills.fromSave(extra, catalog)
			end, "UNKNOWN_SKILLS_FIELD"),
			"unknown field refused"
		)
		local ghost = Skills.save(state)
		ghost.disciplines.alchemy = { xp = 1, step = 1 }
		assert(
			raises(function()
				Skills.fromSave(ghost, catalog)
			end, "UNKNOWN_DISCIPLINE"),
			"undeclared discipline refused"
		)
		local negative = Skills.save(state)
		negative.disciplines.tailoring.xp = -1
		assert(
			raises(function()
				Skills.fromSave(negative, catalog)
			end, "INVALID_SKILL_XP"),
			"negative xp refused"
		)
	end,

	["grantSaved awards into a saved record and ignores absent grants"] = function()
		local catalog = assert(Skills.catalog(document(true)))
		local items = bag({ { id = "a", catalogId = "axe", durability = 1000 } })
		local unchanged, none = Skills.grantSaved(catalog, nil, nil, items)
		assert(unchanged == nil and none == 0, "no grant, no record")
		local saved, gained = Skills.grantSaved(catalog, nil, { id = "woodcraft", xp = 50 }, items)
		assert(gained == 30 and saved.disciplines.woodcraft.xp == 30, "tier 1 axe + step 1 caps at 30")
		local _, filtered = Skills.grantSaved(catalog, nil, { id = "woodcraft", xp = 50 }, items, {})
		assert(filtered == 10, "unequipped axe gives no tier")
	end,
}
