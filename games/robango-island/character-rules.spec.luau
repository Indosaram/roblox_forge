--!strict
local Rules = require("../../genres/survival-coop/module/CharacterRules")
local Tree = require("../../core/domain/progression/SkillTree")
local Content: any = require("./src/shared/SurvivalContent")

local function item(id: string, catalogId: string, durability: number?): any
	return {
		itemId = id,
		catalogId = catalogId,
		quantity = 1,
		qualityMilli = 1000,
		durabilityMilli = durability or 1000,
		attributes = {},
	}
end
local function bag(items: { any }, reservations: any?): any
	local out: any = { id = "bag", items = {}, reservations = reservations or {} }
	for _, entry in items do
		out.items[entry.itemId] = entry
	end
	return out
end
local EMPTY: any = { equipped = {}, equipment = {} }

return {
	["slots cover six clothing pieces and one weapon/tool"] = function()
		assert((Rules.slotOf :: any)("cold-head") == "head" and Rules.slotOf("tropical-bag") == "bag", "clothing")
		assert((Rules.slotOf :: any)("axe-t2") == "weapon" and Rules.slotOf("stone-pick") == "weapon", "tools")
		assert((Rules.slotOf :: any)("flint-knife") == "weapon" and Rules.slotOf("starter-club") == "weapon", "starter")
		assert((Rules.slotOf :: any)("wood") == nil and Rules.slotOf("iron") == nil, "materials are not gear")
		assert(#Rules.SLOTS == 7, "seven slots")
	end,
	["equip records the item, replaces the slot and unequip clears it"] = function()
		local b = bag({ item("a", "axe-t1"), item("b", "axe-t2"), item("c", "cold-top") })
		local s: any = assert(Rules.equip(EMPTY, b, "a"))
		assert(s.equipped.weapon == "a" and s.equipment.a.base == 5, "equipped t1")
		assert(EMPTY.equipped.weapon == nil, "input not mutated")
		local replaced: any = assert(Rules.equip(s, b, "b"))
		assert(replaced.equipped.weapon == "b" and replaced.equipment.a ~= nil, "replaced, old record kept")
		s = replaced
		s = assert(Rules.equip(s, b, "c")) :: any
		assert(s.equipped.top == "c" and s.equipment.c.tags[1] == "clothing", "clothing slot")
		s = assert(Rules.unequip(s, "weapon")) :: any
		assert(s.equipped.weapon == nil and s.equipped.top == "c", "unequip")
	end,
	["equip and unequip refuse with typed reasons and no change"] = function()
		local b = bag(
			{ item("a", "axe-t1"), item("w", "wood"), item("x", "axe-t1", 0), item("r", "cold-head") },
			{ job = { r = 1 } }
		)
		local function refused(state: any, reason: string?): string?
			assert(state == nil and reason ~= nil, "refused")
			return reason
		end
		assert(refused(Rules.equip(EMPTY, b, "missing")) == "ITEM_NOT_OWNED", "not owned")
		assert(refused(Rules.equip(EMPTY, b, "w")) == "NOT_EQUIPMENT", "material")
		assert(refused(Rules.equip(EMPTY, b, "x")) == "ITEM_BROKEN", "broken")
		assert(refused(Rules.equip(EMPTY, b, "r")) == "ITEM_RESERVED", "reserved")
		local s = assert(Rules.equip(EMPTY, b, "a"))
		assert(refused(Rules.equip(s, b, "a")) == "ALREADY_EQUIPPED", "twice")
		assert(refused(Rules.unequip(EMPTY, "head")) == "SLOT_EMPTY", "empty")
		assert(refused(Rules.unequip(EMPTY, "tail")) == "INVALID_SLOT", "slot")
	end,
	["worn ignores equipped items that left the bag and compare is candidate minus current"] = function()
		local b = bag({ item("a", "axe-t1"), item("b", "axe-t3") })
		local s = assert(Rules.equip(EMPTY, b, "a"))
		local gone = bag({ item("b", "axe-t3") })
		assert(Rules.worn(s, gone).weapon == nil, "sold item no longer worn")
		local delta = Rules.compare(Content, Rules.worn(s, b).weapon, Rules.record(b.items.b))
		assert(delta.performance == 10, "t3 (15) vs t1 (5): " .. tostring(delta.performance))
		assert(Rules.compare(Content, nil, Rules.record(item("c", "cold-top"))).cold >= 2, "cold top adds cold")
	end,
	["character view: level, next XP, SP totals, rank 0-10 and lab rank"] = function()
		local policy = Content.progressionPolicy.tree
		local tree = Tree.level(Tree.new(Content, policy), policy, 5)
		local view = Rules.character(Content, tree, 250)
		assert(view.level == 5 and view.maxLevel == 60, "level")
		assert(view.nextXP == policy.xpBase + policy.xpStep * 5, "next xp")
		assert(view.sp == 15 and view.totalSP == 15, "sp")
		assert(view.rank == 2 and view.nextRankAt == 300, "rank 100 per rank")
		assert(view.labRank == 3 and not view.labUnlocked, "lab rank 3 locked")
		assert(Rules.rank(5000) == 10 and Rules.rank(-1) == 0, "clamped")
		local max = Rules.character(Content, Tree.level(tree, policy, 60), 1000)
		assert(max.nextXP == 0 and max.nextRankAt == nil and max.labUnlocked, "caps")
	end,
	["reset quote lists removed nodes and refunds exactly the paid SP"] = function()
		local tree: any = {
			level = 10,
			sp = 3,
			paid = { gathering_1 = 2, gathering_2 = 4 },
			mastery = {},
			receipts = {},
			version = 7,
		}
		local quote = Rules.resetQuote(tree)
		assert(quote.refund == 6 and quote.version == 7 and #quote.nodes == 2, "quote")
		assert(quote.nodes[1] == "gathering_1", "sorted")
	end,
	["research view gates by level, development rank and previous tier; running shows half refund"] = function()
		local policy = Content.progressionPolicy.tree
		local low = Tree.new(Content, policy)
		local view = Rules.research(Content, nil, low, 3, 1000)
		assert(#view == 3 and #view[1].tiers == 3, "three lines x three tiers")
		assert(view[1].tiers[1].status == "locked" and view[1].tiers[1].reason == "CHARACTER_LEVEL_GATE", "level gate")
		local tree = Tree.level(low, policy, 30)
		assert(Rules.research(Content, nil, tree, 2, 1000)[1].tiers[1].reason == "DEVELOPMENT_GATE", "rank gate")
		local ready = Rules.research(Content, nil, tree, 3, 1000)[1]
		assert(ready.tiers[1].status == "ready" and ready.tiers[2].reason == "UPGRADE_PREREQUISITE", "tier order")
		local late: any = {
			version = 1,
			completed = {},
			receipts = {},
			jobs = { j1 = { id = "research-life-1", status = "running", cost = 100, finishAt = 60 } },
		}
		local running = Rules.research(Content, late, tree, 3, 1000)[1].tiers[1]
		assert(running.status == "running" and running.refund == 50 and running.jobId == "j1", "running quote")
		late.completed["research-life-1"] = true
		late.jobs = {}
		local done = Rules.research(Content, late, tree, 3, 1000)[1]
		assert(done.tiers[1].status == "done" and done.benefit == -2, "benefit")
	end,
	["support view: 5/10/15 tiers, level 60 gate and current effect"] = function()
		local policy = Content.progressionPolicy.tree
		local tree = Tree.level(Tree.new(Content, policy), policy, 59)
		local record = Rules.record(item("a", "axe-t1"))
		local view = Rules.support(Content, nil, tree, record, 10000)
		assert(view.tiers[1].value == 5 and view.tiers[2].value == 10 and view.tiers[3].value == 15, "values")
		assert(view.tiers[1].reason == "CHARACTER_LEVEL_GATE", "level 60 gate")
		record.support, record.completed = "support-tier-1", { ["support-tier-1"] = true }
		local at60 = Rules.support(Content, nil, Tree.level(tree, policy, 60), record, 10000)
		assert(at60.current == 5 and at60.tiers[1].status == "done" and at60.tiers[2].status == "ready", "next tier")
	end,
	["modify view lists only eligible rows and both slots"] = function()
		local policy = Content.progressionPolicy.tree
		local tree = Tree.level(Tree.new(Content, policy), policy, 30)
		local weapon = Rules.modify(Content, nil, tree, Rules.record(item("a", "axe-t1")))
		assert(#weapon.rows == 1 and weapon.rows[1].row.id == "modify-sharpness", "weapon gets sharpness")
		assert(weapon.rows[1].reason == "SKILL_GATE", "skill gate surfaced")
		local coat = Rules.record(item("c", "cold-top"))
		coat.modifications = { ["1"] = { { id = "hardness", value = 2 } } }
		local clothing = Rules.modify(Content, nil, tree, coat)
		assert(
			#clothing.rows == 3 and clothing.slots[1].value == 2 and clothing.slots[2] == nil,
			"clothing rows and slots"
		)
	end,
}
