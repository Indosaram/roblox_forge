--!strict
-- Real gameplay actions named by content entryActions award proficiency once.
local Progression = require("../../../../genres/survival-coop/module/ProgressionExtension")
local CraftingAdapter = require("../../../../genres/survival-coop/module/CraftingAdapter")
local Content = require("../../../../core/domain/survival/Content")
local Tree = require("../../../../core/domain/progression/SkillTree")
local Robango = require("../../../../games/robango-island/src/shared/SurvivalContent")
local tree = (Robango :: any).progressionPolicy.tree

local function fresh(): any
	return Tree.new(Robango, tree)
end

return {
	["each robango gameplay event awards its category once and unknown events nothing"] = function()
		local events: { [string]: string } = {
			carcass = "butchering",
			["ranged-hit"] = "ranged",
			["settlement-place"] = "construction",
			["home-place"] = "construction",
			["home-plant"] = "farming",
			["home-harvest"] = "farming",
			cord = "tailoring",
			["guard-block"] = "defense",
		}
		for event, category in events do
			local state = Progression.award(Robango, fresh(), event, "r1")
			assert(state.mastery[category].level == 1, event .. " awards " .. category)
			assert(Progression.award(Robango, state, event, "r1") == state, event .. " replay awards nothing")
		end
		local state = fresh()
		assert(Progression.award(Robango, state, "basicblock", "r") == state, "placeholder is not an action")
	end,
	["guarded hits award defense once and unguarded hits nothing"] = function()
		local raw: any = {
			survival_content = 1,
			rules = table.clone(Content.RULES),
			limits = table.clone(Content.DEFAULT_LIMITS),
			items = { { id = "fiber", name = "Fiber", stackMax = 100, weightMilli = 100 } },
			recipes = {},
			vitals = {},
		}
		local content: any = assert(Content.canonicalize(raw))
		content.progressionPolicy = (Robango :: any).progressionPolicy
		content.skillCategories = (Robango :: any).skillCategories
		local death = {
			worldRevision = "w",
			equipment = function()
				return {}
			end,
			position = function()
				return { x = 0, y = 0, z = 0 }
			end,
			reachable = function()
				return true
			end,
		}
		local instance: any = CraftingAdapter.new(
			{
				mode = "crafting",
				currency = "Coins",
				startingBalance = 0,
				contentVersion = 1,
				survivalDeath = true,
				inventory = {
					content = raw,
					carriedContainer = "bag",
					speedPenaltyMilli = 0,
					containers = { bag = {} },
				},
			} :: any,
			{
				now = function()
					return 0
				end,
				roll = function()
					return 0
				end,
				emit = function() end,
				survivalContent = content,
				survivalDeath = death,
			} :: any
		)
		assert(instance.join("1", nil).ok, "join")
		local function run(action: string, args: { any }, id: string, now: number): (any, any)
			local stage = assert(instance.stageCommand("1", action, args, {
				actorId = "1",
				requestId = id,
				sessionEpoch = 0,
				nowMillis = now,
				serverId = "s",
			}))
			stage.apply()
			return stage.result, (instance.save("1") :: any).progression.mastery.defense
		end
		local _, open = run("combat-damage", { 1000, 10 }, "open", 10)
		assert(open.level == 0, "unguarded hit awards nothing")
		assert(run("guard", {}, "guard", 20).ok, "guard opens")
		local hit, guarded = run("combat-damage", { 1000, 30 }, "hit", 30)
		assert(hit.ok and guarded.level == 1, "guarded hit awards defense")
		local _, again = run("combat-damage", { 1000, 30 }, "hit", 30)
		assert(again.level == 1 and again.xp == 0, "same receipt awards once")
	end,
}
