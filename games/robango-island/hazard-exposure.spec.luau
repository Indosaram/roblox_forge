--!strict
-- Live hazard-zone exposure, armor refresh on equip, and brawl worn gear.
local Rules = require("../../genres/survival-coop/module/CharacterRules")
local Combat = require("../../genres/survival-coop/module/Combat")
local CraftingAdapter = require("../../genres/survival-coop/module/CraftingAdapter")
local ContentRules = require("../../core/domain/survival/Content")
local Volcano = require("../../core/domain/survival/Volcano")
local Content: any = require("./src/shared/SurvivalContent")

local function item(id: string, catalogId: string): any
	return {
		itemId = id,
		catalogId = catalogId,
		quantity = 1,
		qualityMilli = 1000,
		durabilityMilli = 1000,
		attributes = {},
	}
end
local function bag(items: { any }): any
	local out: any = { id = "bag", items = {}, reservations = {} }
	for _, entry in items do
		out.items[entry.itemId] = entry
	end
	return out
end
local function wear(b: any, ...: string): any
	local state: any = { equipped = {}, equipment = {} }
	for _, id in { ... } do
		state = assert(Rules.equip(state, b, id))
	end
	return state
end
local function layout(id: string): any
	for _, candidate in Content.layouts do
		if candidate.id == id then
			return candidate
		end
	end
	error("missing layout " .. id)
end
local CARRIED: any = { equipped = {}, equipment = {} }

return {
	["heat zone: inside ticks fatigue, outside does not, worn heat clothing mitigates, carried does not"] = function()
		local l = layout("rw.a3.s1")
		local b = bag({ item("t", "tropical-top") })
		local inside = { x = -280, y = 10, z = 0 }
		local bare = Rules.hazardExposure(Content, l, inside, CARRIED, b, 0, 10, 0)
		assert(bare.fatigueMilli == 10000 and bare.healthMilli == 0, "inside bare: fatigue+1/s for 10 s")
		local outside = Rules.hazardExposure(Content, l, { x = -280, y = 10, z = 40 }, CARRIED, b, 0, 10, 0)
		assert(outside.fatigueMilli == 0 and outside.healthMilli == 0, "outside the radius nothing ticks")
		local worn = Rules.hazardExposure(Content, l, inside, wear(b, "t"), b, 0, 10, 0)
		assert(worn.fatigueMilli == 8000, "worn heat 2 resists 20%, got " .. worn.fatigueMilli)
	end,
	["lava burns a quarter of max health per second, boots or not; hot spring is a refuge that recovers"] = function()
		local l = layout("rw.a5.s1")
		local b = bag({ item("b", "lava-protection-boots") })
		local lava = { x = 240, y = 18, z = 0 }
		assert(Rules.hazardExposure(Content, l, lava, CARRIED, b, 0, 1, 0).healthMilli == 25000, "bare lava")
		assert(Rules.hazardExposure(Content, l, lava, wear(b, "b"), b, 0, 1, 0).healthMilli == 25000, "standing lava")
		local spring = Rules.hazardExposure(Content, l, { x = -48, y = 18, z = 140 }, CARRIED, b, 0, 10, 0)
		assert(spring.refuge and spring.healthMilli == 0 and spring.fatigueMilli == 0, "spring stops exposure")
		assert(spring.recoverMilli == 50000, "spring recovers fatigue 5/s")
	end,
	["volcanic ground: worn lava boots halve exposure, carried boots do not"] = function()
		local l = layout("rw.a5.s1")
		local b = bag({ item("b", "lava-protection-boots") })
		local exposed: any = nil
		for x = -400, 400, 16 do
			for z = -400, 400, 16 do
				local p = { x = x, y = 18, z = z }
				local zone = Volcano.zone(l, p)
				if not exposed and zone.exposed and not zone.spring and not zone.lava then
					exposed = p
				end
			end
		end
		assert(exposed, "an exposed volcanic point exists")
		local carried = Rules.hazardExposure(Content, l, exposed, CARRIED, b, 0, 10, 0)
		local worn = Rules.hazardExposure(Content, l, exposed, wear(b, "b"), b, 0, 10, 0)
		assert(carried.healthMilli == 10000 and carried.fatigueMilli == 20000, "bare volcano rates")
		assert(worn.healthMilli == 5000 and worn.fatigueMilli == 10000, "worn boots halve")
	end,
	["a downed player does not keep ticking and the tick applies whole seconds of world clock"] = function()
		local l = layout("rw.a3.s1")
		local inside = { x = -280, y = 10, z = 0 }
		local args, from = Rules.hazardTick(Content, l, true, inside, nil, nil, nil, 100, 0)
		assert(args == nil and from == 100, "first tick starts the clock")
		args, from = Rules.hazardTick(Content, l, true, inside, nil, nil, 100, 100.5, 0)
		assert(args == nil and from == 100, "sub-second waits")
		args, from = Rules.hazardTick(Content, l, true, inside, nil, nil, 100, 102, 0)
		assert(args and args[2] == 2000 and from == 102, "two seconds of fatigue")
		args, from = Rules.hazardTick(Content, l, false, inside, nil, nil, 102, 200, 0)
		assert(args == nil and from == nil, "downed: no exposure and the clock resets")
	end,
	["adapter: hazard exposure applies to a live actor and is refused once downed"] = function()
		local raw: any = {
			survival_content = 1,
			rules = table.clone(ContentRules.RULES),
			limits = table.clone(ContentRules.DEFAULT_LIMITS),
			items = { { id = "fiber", name = "Fiber", stackMax = 100, weightMilli = 100 } },
			recipes = {},
			vitals = {},
		}
		local instance: any = CraftingAdapter.new(
			{
				mode = "crafting",
				currency = "Coins",
				startingBalance = 0,
				contentVersion = 1,
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
			} :: any
		)
		assert(instance.join("1", nil).ok, "join")
		local function run(action: string, args: { any }, id: string): any
			local stage = assert(instance.stageCommand("1", action, args, {
				actorId = "1",
				requestId = id,
				sessionEpoch = 0,
				nowMillis = 0,
			}))
			stage.apply()
			return stage.result
		end
		assert(run("hazard-exposure", { 25000, 4000, 0 }, "h1").ok, "applied")
		local vitals = instance.save("1").vitals
		assert(vitals.healthMilli == 75000 and vitals.fatigueMilli == 4000, "health and fatigue moved")
		assert(run("hazard-exposure", { 100000, 0, 0 }, "h2").ok, "lethal exposure")
		local again = run("hazard-exposure", { 1000, 1000, 0 }, "h3")
		assert(not again.ok and again.reason == "NOT_ALIVE", "a downed actor does not keep ticking")
	end,
	["equipping armor refreshes the damage path: the next hit after equip is reduced"] = function()
		local raw: any = {
			survival_content = 1,
			rules = table.clone(ContentRules.RULES),
			limits = table.clone(ContentRules.DEFAULT_LIMITS),
			items = {
				{ id = "cold-top", name = "Cold Top", stackMax = 1, weightMilli = 100, maxDurabilityMilli = 100000 },
			},
			recipes = {},
			vitals = {},
		}
		local content: any = assert(ContentRules.canonicalize(raw))
		content.progressionPolicy = Content.progressionPolicy
		content.skillCategories, content.skillNodes = Content.skillCategories, Content.skillNodes
		local top = item("c", "cold-top")
		top.durabilityMilli = 100000
		local instance: any = CraftingAdapter.new(
			{
				mode = "crafting",
				currency = "Coins",
				startingBalance = 0,
				contentVersion = 1,
				inventory = {
					content = raw,
					carriedContainer = "bag",
					speedPenaltyMilli = 0,
					containers = { bag = { top } },
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
			} :: any
		)
		assert(instance.join("1", nil).ok, "join")
		local function hit(id: string): number
			local before = instance.save("1").vitals.healthMilli
			local stage = assert(
				instance.stageCommand(
					"1",
					"combat-damage",
					{ 10000, 0 },
					{ actorId = "1", requestId = id, sessionEpoch = 0, nowMillis = 0 }
				)
			)
			stage.apply()
			assert(stage.result.ok, tostring(stage.result.reason))
			return before - instance.save("1").vitals.healthMilli
		end
		assert(hit("a") == 10000, "carried armor: full damage")
		-- gear-equip installs the new personal token; Session.hydrate fans it out to the adapter.
		local saved: any = instance.save("1")
		saved.gear = wear(bag({ top }), "c")
		assert(instance.hydrate("1", saved).ok, "hydrate after equip")
		local reduced = hit("b")
		assert(reduced < 10000, "worn armor reduces the next hit, got " .. reduced)
	end,
	["brawl: worn weapon is chosen first and worn armor reduces a resolved strike"] = function()
		local b = bag({ item("a", "axe-t1"), item("z", "axe-t2") })
		assert(Rules.brawlOrder(CARRIED, b)[1] == "a", "carried only: sorted order")
		assert(Rules.brawlOrder(wear(b, "z"), b)[1] == "z", "worn weapon first")
		local armored = bag({ item("t", "cold-top"), item("s", "cold-shoes") })
		assert(Rules.armorPermille(Content, CARRIED, armored) == 1000, "carried armor keeps full damage")
		local permille = Rules.armorPermille(Content, wear(armored, "t", "s"), armored)
		assert(permille < 1000 and permille >= 1000 - Rules.MAX_ARMOR_PERMILLE, "worn armor reduces, capped")
		local rule = {
			mode = "melee",
			windupMillis = 1,
			recoveryMillis = 1,
			range = 10,
			facingDot = 0,
			damageMilli = 10000,
			ammo = 0,
		}
		local attack = assert(
			Combat.begin("x", "t", rule :: any, 0, 0, { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }, 0, false)
		)
		local defense = Combat.defense()
		local _, full = Combat.resolve(attack, 1, "t", { x = 1, y = 0, z = 0 }, true, defense)
		defense.armorPermille = permille
		local _, reduced = Combat.resolve(attack, 1, "t", { x = 1, y = 0, z = 0 }, true, defense)
		assert(full == 10000 and reduced == 10000 * permille // 1000, "armor scales the strike")
	end,
	["a settlement-placed tier-2 bench resolves as the workbench tier-2 station"] = function()
		local kinds: { [string]: boolean } = {}
		for _, definition in Content.structures do
			if definition.station then
				kinds[definition.id] = true
			end
		end
		local base, tier = Rules.tieredKind("workbench-t2", kinds)
		assert(base == "workbench" and tier == "2", "workbench-t2 serves station.workbench.t2")
		assert(Rules.tieredKind("workbench", kinds) == nil, "untiered kind keeps its own id")
	end,
}
