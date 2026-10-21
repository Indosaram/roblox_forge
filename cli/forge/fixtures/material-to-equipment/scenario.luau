--!strict
-- Real generated catalog and domain modules; only persistence/clock/stock ports
-- are fixture-owned until the integrator wires durable Session transactions.
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Tree = require("../../../../core/domain/progression/SkillTree")
local Materials = require("../../../../core/domain/crafting/MaterialGrowth")
local Progression = require("../../../../genres/survival-coop/module/ProgressionExtension")
local Policy = require("./policy")
local M = {}

M.operations = {
	material_progression = function(ctx, _step): string?
		local state = Tree.level(Tree.new(Content, Policy.tree), Policy.tree, 10)
		local hide = Materials.raw(Content, "hide", 10, 0, "boar")
		local _, missing = Progression.craft(Content, state, "tan-hide", { hide })
		if missing ~= "SKILL_GATE" then
			return "missing skill must refuse tanning"
		end
		state = Tree.award(state, Policy.tree, "processing", "dry-twig:1")
		state = assert(Tree.learn(Content, state, "processing_1"))
		for i = 1, 90 do
			state = Tree.award(state, Policy.tree, "processing", "dry-twig:" .. tostring(i + 1))
		end
		state = assert(Tree.learn(Content, state, "processing_2"))
		local leather = assert(Progression.craft(Content, state, "tan-hide", { hide }))
		if leather.budget ~= 2 or leather.attributes.flexibility ~= 6 then
			return "tanning did not consume budget and propagate attributes"
		end
		state = Tree.award(state, Policy.tree, "tailoring", "practice:1")
		state = assert(Tree.learn(Content, state, "tailoring_1"))
		local auxiliary = Materials.raw(Content, "fiber", 10, 0, nil)
		auxiliary.item, auxiliary.quantity = "dried-fiber", 2
		leather.quantity = 5
		local top = assert(Progression.craft(Content, state, "temperate-top", { leather, auxiliary }))
		leather.attributes.hardness = 9
		local stronger = assert(Progression.craft(Content, state, "temperate-top", { leather, auxiliary }))
		if top.attributes.hardness == stronger.attributes.hardness then
			return "selected materials did not change equipment"
		end
		local vitals = { energy = 10, health = 50, fatigue = 50, buffs = {} }
		local food = Materials.raw(Content, "apple", 40, 0, nil)
		food.item = "baked-apple"
		local now = ctx.now()
		local fed = assert(Progression.eat(Content, vitals, food, now, Policy))
		local gear = { { material = top, tags = { "clothing" }, base = 5 } }
		local bare = Progression.readiness(Content, vitals, {}, now, now + 10, "cold", 5, false, Policy)
		local prepared = Progression.readiness(Content, fed, gear, now, now + 10, "cold", 5, true, Policy)
		if prepared.health <= bare.health or prepared.fatigue >= bare.fatigue then
			return "food clothing and rest had no readiness effect"
		end
		local quote = Tree.quote(state)
		local reset = assert(Tree.reset(state, quote.version, false, 0))
		if reset.sp ~= state.sp + quote.refund or reset.mastery.processing.level ~= state.mastery.processing.level then
			return "reset lost paid SP or proficiency"
		end
		ctx.results[ctx.playerOf(_step)] =
			{ ok = true, data = { armorChanged = true, readinessImproved = true, refunded = quote.refund } }
		return nil
	end,
}

function M.new(_ctx): any
	return {}
end

return M
