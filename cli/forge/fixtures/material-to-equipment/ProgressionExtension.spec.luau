--!strict
local Progression = require("../../../../genres/survival-coop/module/ProgressionExtension")
local Materials = require("../../../../core/domain/crafting/MaterialGrowth")
local Tree = require("../../../../core/domain/progression/SkillTree")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Policy = require("./policy")

local function equipment(): any
	local material = Materials.raw(Content, "hide", 10, 0, nil)
	material.item = "temperate-top"
	return { material = material, tags = { "clothing" }, base = 5 }
end

return {
	["refund mastery cannot apply across categories or cancelled jobs"] = function()
		local state = Tree.level(Tree.new(Content, Policy.tree), Policy.tree, 60)
		state.paid.processing_6 = 12
		local input = Materials.raw(Content, "branch", 10, 0, nil)
		local cancelled =
			Progression.refunds(Content, state, "dry-twig", { input }, "processing", 74, "cancelled", true)
		assert(next(cancelled) == nil, "cancellation already returns input")
		local wrong = Progression.refunds(Content, state, "starter-axe", { input }, "processing", 74, "wrong", false)
		assert(next(wrong) == nil, "processing mastery cannot refund tool crafting")
		-- Enough actual consumed units make the negative deterministic; this is
		-- not a timing/retry test and the recorded seed stays fixed.
		input.quantity = 100
		local normal = Progression.refunds(Content, state, "dry-twig", { input }, "processing", 74, "batch", false)
		assert((normal.branch or 0) > 0, "fixed seed exercises successful mastery trials")
		wrong = Progression.refunds(Content, state, "starter-axe", { input }, "processing", 74, "batch", false)
		assert(next(wrong) == nil, "large wrong-category batch never rolls")
		state.paid = {}
		assert(
			next(Progression.refunds(Content, state, "dry-twig", { input }, "processing", 74, "missing", false)) == nil,
			"node six required"
		)
	end,
	["support and research enforce level station budget and prior tier"] = function()
		local state = Tree.level(Tree.new(Content, Policy.tree), Policy.tree, 60)
		local facts = { developmentRank = 10, station = "signal-relay", stationTier = 1, coins = 5000 }
		local _, prerequisite = Progression.upgrade(Content, state, {}, "support-tier-2", facts)
		assert(prerequisite == "UPGRADE_PREREQUISITE", "support tier requires preceding tier")
		local candidate = assert(
			Progression.upgrade(Content, state, { ["support-tier-1"] = true }, "support-tier-2", facts),
			"support tier candidate"
		)
		assert(candidate.cost == 1500 and candidate.seconds == 60, "authored support costs")
		facts.coins = 0
		local _, funds = Progression.upgrade(Content, state, {}, "support-tier-1", facts)
		assert(funds == "INSUFFICIENT_COINS", "support is not free")
		facts.coins = 5000
		facts.station = "workbench"
		local _, station = Progression.upgrade(Content, state, {}, "support-tier-1", facts)
		assert(station == "STATION_GATE", "communication station required")
		facts.station = "signal-relay"
		local _, duplicate = Progression.upgrade(Content, state, { ["support-tier-1"] = true }, "support-tier-1", facts)
		assert(duplicate == "ALREADY_COMPLETED", "no repeat settlement")
		state.level = 59
		local _, level = Progression.upgrade(Content, state, {}, "support-tier-1", facts)
		assert(level == "CHARACTER_LEVEL_GATE", "support requires level sixty")
	end,
	["missing purchased skill refuses actual craft learning enables it and gathering uses the same gate"] = function()
		local state = Tree.level(Tree.new(Content, Policy.tree), Policy.tree, 10)
		local hide = Materials.raw(Content, "hide", 10, 0, nil)
		local _, missing = Progression.craft(Content, state, "tan-hide", { hide })
		assert(missing == "SKILL_GATE", "progression contract 19")
		state.mastery.processing.level = 10
		state = assert(Tree.learn(Content, state, "processing_1"), "progression contract 21")
		state = assert(Tree.learn(Content, state, "processing_2"), "progression contract 22")
		assert(Progression.craft(Content, state, "tan-hide", { hide }), "progression contract 23")
		assert(
			Progression.gather(state, { gates = { skillNodes = { "gathering_1" } } }) == "SKILL_GATE",
			"progression contract 24"
		)
		state.mastery.gathering.level = 1
		state = assert(Tree.learn(Content, state, "gathering_1"), "progression contract 26")
		assert(
			Progression.gather(state, { gates = { skillNodes = { "gathering_1" } } }) == nil,
			"progression contract 27"
		)
	end,
	["food clothing rest and exact buff expiry measurably alter expedition readiness"] = function()
		local vitals = { energy = 10, health = 50, fatigue = 50, buffs = {} }
		local food = Materials.raw(Content, "apple", 40, 0, nil)
		food.item = "baked-apple"
		local fed = assert(Progression.eat(Content, vitals, food, 0, Policy), "progression contract 33")
		assert(
			fed.energy == 28 and fed.health == 59 and fed.buffs.resistance.untilTime == 300,
			"progression contract 34"
		)
		local bare = Progression.readiness(Content, vitals, {}, 0, 10, "cold", 5, false, Policy)
		local clothed = Progression.readiness(Content, vitals, { equipment() }, 0, 10, "cold", 5, false, Policy)
		local prepared = Progression.readiness(Content, fed, { equipment() }, 0, 10, "cold", 5, true, Policy)
		assert(clothed.health > bare.health and clothed.fatigue < bare.fatigue, "progression contract 38")
		assert(prepared.health > clothed.health and prepared.fatigue < clothed.fatigue, "progression contract 39")
		local whole = Progression.readiness(Content, fed, {}, 299, 301, "cold", 5, false, Policy)
		local split = Progression.readiness(Content, fed, {}, 299, 300, "cold", 5, false, Policy)
		split = Progression.readiness(Content, split, {}, 300, 301, "cold", 5, false, Policy)
		assert(
			math.abs(whole.health - split.health) < 0.000001 and math.abs(whole.fatigue - split.fatigue) < 0.000001,
			"progression contract 43"
		)
		food.item = "recovery-feed"
		local _, feed = Progression.eat(Content, vitals, food, 0, Policy)
		assert(feed == "NOT_PLAYER_FOOD", "progression contract 46")
	end,
	["two modification slots replace without stacking support applies once and unsupported items refuse"] = function()
		local state = Tree.level(Tree.new(Content, Policy.tree), Policy.tree, 60)
		local item = equipment()
		local _, skill = Progression.modify(Content, state, item, "modify-hardness", 1)
		assert(skill == "SKILL_GATE", "progression contract 52")
		state.paid.tailoring_4 = 8
		local modified =
			assert(Progression.modify(Content, state, item, "modify-hardness", 1), "progression contract 54")
		modified = assert(Progression.modify(Content, state, modified, "modify-hardness", 1), "progression contract 55")
		assert(Progression.equipment(Content, modified, Policy).armor == 9, "progression contract 56")
		modified.support = "support-tier-3"
		assert(Progression.equipment(Content, modified, Policy).armor == 10, "progression contract 58")
		local _, slot = Progression.modify(Content, state, item, "modify-hardness", 3)
		assert(slot == "INVALID_MODIFICATION_SLOT", "progression contract 60")
		state.paid.weapon_tool_4 = 8
		local _, eligibility = Progression.modify(Content, state, item, "modify-sharpness", 1)
		assert(eligibility == "INELIGIBLE_MODIFICATION", "progression contract 62")
		assert(item.modifications == nil, "progression contract 63")
	end,
}
