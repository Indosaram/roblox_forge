--!strict
-- p134 C1 fix 1 (phone run, staging v67): stake pulls dead-ended for ~8 min and the first craft
-- took 22 min. Drives the opening through the real OpeningDirector on the live onboarding role
-- (engine fixture) and the real OpeningScene view, and checks the four fixes:
--  1. a pulled stake's prompt is off and only pullable stakes glow; a refused pull is surfaced
--     to the player (ForgeOpeningRefusal) with KO and EN toast copy;
--  2. a bone source sits by the crash site, bare-handed at level 1, so the knife is a minute away;
--  3. the craft sheet preselects the recipe the tracker asks for (Bone Knife, then the hatchet);
--  4. the dodge beat shows a red ground ring before each charge (Scene.telegraph);
-- plus the bag count badge fits two digits (the "+3 fiber, bag shows 1 and 1" report: 12 and 15).
local Scene = require("./src/shared/OpeningScene")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Fixture = require("./PackText.fixture")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local HudShell = require("../../genres/survival-coop/module/HudShell")

local ACTOR = "11734795308"
-- A new player's walk speed (RoleWorld baseWalkSpeed) in studs per second.
local WALK = 16

local function onboarding(): any
	for _, layout in Content.layouts do
		if layout.id == "rw.onboarding" then
			return layout
		end
	end
	error("rw.onboarding layout")
end

local function anchor(layout: any, id: string): any
	for _, entry in layout.anchors do
		if entry.id == id then
			return entry.position
		end
	end
	error("anchor " .. id)
end

local function flat(a: any, b: any): number
	return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

-- The live director on the onboarding role, a fresh player loaded and past the cold open.
local function director(): any
	local engine = Engine.new(nil, true)
	local now = 5000
	local world = engine.role.build(Content, Source, Policy, function()
		return now
	end, "rw.onboarding", 1776)
	local opening = assert(world.opening, "onboarding builds the opening director")
	engine.move(ACTOR, { x = 12, y = 5, z = 64 })
	local live = { tutorial = 1, items = {}, document = {}, near = true }
	opening.bind({
		tutorial = function()
			return live.tutorial, false
		end,
		items = function()
			return live.items
		end,
		dodgeAt = function()
			return nil
		end,
		position = function()
			return nil
		end,
		near = function()
			return live.near
		end,
		store = {
			snapshot = function()
				return live.document
			end,
			transaction = function(_, transform)
				return transform(live.document)
			end,
		},
		analytics = function() end,
		travel = function()
			return true
		end,
		spawn = function(fn)
			fn()
		end,
	})
	local function tick(ms: number?)
		now += ms or 0
		opening.tick({ ACTOR }, now)
	end
	tick()
	live.tutorial = 2
	assert(opening.intent(ACTOR, "cold-open-done"), "cold open intent")
	tick()
	local player = engine.game:GetService("Players"):GetPlayerByUserId(tonumber(ACTOR))
	return {
		engine = engine,
		world = world,
		opening = opening,
		live = live,
		tick = tick,
		player = player,
		prompt = function(index: number): any
			return assert(opening.stakes[index]:FindFirstChildOfClass("ProximityPrompt"), "stake prompt")
		end,
		refusal = function(): string?
			local raw = player:GetAttribute("ForgeOpeningRefusal")
			return if type(raw) == "string" then string.match(raw, "^([%u_]+)#") else nil
		end,
	}
end

return {
	["dead end 1: a pulled stake's prompt goes off, only pullable stakes glow, refusals surface"] = function()
		local d = director()
		for index = 1, Scene.STAKES do
			assert(d.prompt(index).Enabled == true, "stake " .. index .. " is pullable at the start")
		end
		d.engine.interact(ACTOR, "OpeningStake1")
		assert(d.opening.state(ACTOR).pulled[1], "stake 1 pulled")
		assert(d.prompt(1).Enabled == false, "the pulled stake no longer takes the action button")
		assert(d.prompt(2).Enabled == true and d.prompt(3).Enabled == true, "the others still pull")
		local marks = Scene.stakeMarks(d.opening.extension.snapshot(ACTOR))
		assert(marks[1].fallen and not marks[1].glow and not marks[1].prompt, "stake 1 lies fallen, unlit")
		assert(marks[2].glow and marks[3].glow, "remaining stakes are marked")
		-- Pulling the same stake again (the phone run's dead end) is refused and surfaced.
		d.engine.interact(ACTOR, "OpeningStake1")
		assert(d.opening.refusal(ACTOR) == "ALREADY_PULLED", "refusal kept: " .. tostring(d.opening.refusal(ACTOR)))
		assert(d.refusal() == "ALREADY_PULLED", "refusal published to the player")
		-- Two stakes send the boar: the third waits for the dodge beat, and says so.
		d.engine.interact(ACTOR, "OpeningStake2")
		assert(d.opening.state(ACTOR).charge ~= nil, "the second stake sends the charge")
		assert(d.prompt(3).Enabled == false, "stake 3 is off while the boar charges")
		local first = d.player:GetAttribute("ForgeOpeningRefusal")
		d.engine.interact(ACTOR, "OpeningStake3")
		assert(d.refusal() == "NOT_NOW", "NOT_NOW surfaced")
		assert(d.player:GetAttribute("ForgeOpeningRefusal") ~= first, "every refusal fires a fresh attribute")
		-- Out of reach is surfaced too, instead of nothing.
		d.live.near = false
		d.engine.interact(ACTOR, "OpeningStake3")
		assert(d.refusal() == "TOO_FAR", "TOO_FAR surfaced")
		d.live.near = true
		for _ = 1, Scene.MAX_TRIES do
			d.tick(Scene.CHARGE_MILLIS + Scene.SLOW_MILLIS + Scene.GRACE_MILLIS + Scene.NEXT_CHARGE_MILLIS)
		end
		assert(Scene.current(d.opening.state(ACTOR)).id == "tumble", "dodge beat passed")
		assert(d.prompt(3).Enabled == true, "the last stake is pullable again after the dodge beat")
		d.engine.interact(ACTOR, "OpeningStake3")
		d.tick()
		for index = 1, Scene.STAKES do
			assert(d.prompt(index).Enabled == false, "every stake off once all are out")
		end
		-- Every surfaced reason has KO and EN toast copy.
		for _, reason in Scene.REFUSALS do
			for _, locale in { "en-us", "ko-kr" } do
				local line = Fixture.packText(locale, Scene.refusalKey(reason))
				assert(line and line ~= Scene.refusalKey(reason), locale .. " toast for " .. reason)
			end
		end
		d.world.destroy()
	end,
	["first craft pace: a level-1 bone source sits by the crash site, the bone heap is not the only one"] = function()
		local layout = onboarding()
		local stakes = {}
		for index = 1, Scene.STAKES do
			table.insert(stakes, anchor(layout, "opening.stake." .. index))
		end
		local crash = { x = 0, z = 0 }
		for _, stake in stakes do
			crash.x += stake.x / #stakes
			crash.z += stake.z / #stakes
		end
		local bone, fiber
		for _, node in layout.resourceNodes do
			local gates = node.gates or {}
			local open = (gates.characterLevel or 1) <= 1 and #(gates.skillNodes or {}) == 0 and node.tool == nil
			if node.item == "bone" and open and flat(node.position, crash) <= 16 then
				bone = node
			end
			if node.item == "fiber" and open and flat(node.position, crash) <= 16 then
				fiber = node
			end
		end
		assert(bone, "a bare-handed level-1 bone node within 16 studs of the crash site")
		assert(fiber, "fiber within 16 studs of the crash site")
		assert(bone.id == Scene.BONE_NODE, "the tracker guides to it: " .. bone.id)
		assert(bone.stock >= 2 and bone.yield >= 1, "enough bone for the knife")
		-- Walking time from the last stake: bone, fiber, back (well under the 1 min budget).
		local last = stakes[#stakes]
		local walk = (flat(last, bone.position) + flat(bone.position, fiber.position)) / WALK
		assert(walk <= 10, string.format("stake -> bone -> fiber is %.1f s of walking", walk))
		-- The knife recipe is by hand: bone 1 + fiber 2.
		local knife
		for _, recipe in Content.recipes do
			knife = if recipe.id == "bone-knife" then recipe else knife
		end
		assert(knife and knife.station == nil, "bone knife by hand")
		-- The live role publishes it as a gather node the fan can open.
		local d = director()
		local found = false
		for _, part in d.engine.game:GetService("CollectionService"):GetTagged("ForgeSurvivalNode") do
			found = found or part:GetAttribute("ForgeNodeId") == bone.id
		end
		assert(found, "the crash-site bone pile is a live gather node")
		d.world.destroy()
	end,
	["the craft sheet preselects the recipe the opening tracker asks for"] = function()
		local recipes = Content.recipes
		-- The phone bag at the craft: starter fiber, gathered fiber, one bone, berries.
		local bag = {
			items = {
				["starter-fiber"] = {
					itemId = "starter-fiber",
					catalogId = "fiber",
					quantity = 12,
					durabilityMilli = 0,
				},
				["g-fiber"] = { itemId = "g-fiber", catalogId = "fiber", quantity = 15, durabilityMilli = 0 },
				["g-bone"] = { itemId = "g-bone", catalogId = "bone", quantity = 1, durabilityMilli = 0 },
				["starter-berry"] = { itemId = "starter-berry", catalogId = "berry", quantity = 6, durabilityMilli = 0 },
			},
			reservations = {},
		}
		local state = Scene.new(0)
		for _, case in { { "bone", "bone-knife" }, { "bone-knife", "bone-knife" }, { "flint", "stone-axe" } } do
			state.index = Scene.INDEX[case[1]]
			local view = Scene.view(state, { items = {} } :: any)
			assert(view.craftPin == case[2], case[1] .. " pins " .. tostring(view.craftPin))
			local snapshot = { extensionPin = Model.extensionPin({ opening = view, contracts = {} }) }
			-- The tutorial is on its axe step during the knife beat; the tracker's recipe still wins.
			snapshot.contracts = { tutorial = { step = "craft-stone-axe" } }
			local pin = Model.craftPin(snapshot, bag, recipes)
			assert(pin == case[2], case[1] .. ": sheet pin " .. tostring(pin))
			local rows = Model.recipeOrder(bag, recipes, function()
				return false
			end, Content.items, { pin = pin, jobs = {} })
			assert(rows[1].recipe.id == case[2], case[1] .. ": first (selected) row is " .. rows[1].recipe.id)
		end
		-- After the opening, the tutorial's axe pin is unchanged.
		local done = Model.craftPin({ contracts = { tutorial = { step = "craft-stone-axe" } } }, bag, recipes)
		assert(done == "stone-axe", "tutorial pin kept: " .. tostring(done))
		assert(Model.craftPin({}, bag, recipes) == nil, "no pin outside the opening and tutorial")
	end,
	["the dodge beat shows a red ground ring before every charge"] = function()
		local charge = Scene.charge(10000, true)
		local before = charge.startAt - Scene.TELEGRAPH_LEAD_MILLIS
		assert(not Scene.telegraph(charge, before - 1), "no ring before the lead")
		local shown, fill = Scene.telegraph(charge, before)
		assert(shown and fill == 0, "ring appears before the boar moves")
		assert(Scene.TELEGRAPH_LEAD_MILLIS >= 1000, "at least a second of warning")
		local _, mid = Scene.telegraph(charge, charge.startAt)
		assert(mid > 0 and mid < 1, "ring fills toward the strike")
		assert(select(2, Scene.telegraph(charge, charge.strikeAt)) == 1, "full at the strike")
		assert(Scene.telegraph(charge, charge.strikeAt + Scene.GRACE_MILLIS), "shown through the grace")
		assert(not Scene.telegraph(charge, charge.strikeAt + Scene.GRACE_MILLIS + 1), "gone after")
		assert(not Scene.telegraph(nil, 0), "no charge, no ring")
		-- The coach card names the red ring in both languages.
		for _, locale in { "en-us", "ko-kr" } do
			local line = assert(Fixture.packText(locale, "opening.tumble.charge"))
			assert(string.find(line, if locale == "en-us" then "red ring" else "빨간 원", 1, true), locale)
		end
	end,
	["bag count badges never wrap (toast +3 fiber read as stacks 1 and 1)"] = function()
		-- p134 C1 bag2: stacks of 12 (starter) and 15 (gathered) fiber rendered "1" and "1" (the craft
		-- sheet's 27 = 12 + 15): the 20 px badge label wrapped its second digit onto a clipped line.
		for _, cell in { 49, 53, 64 } do
			for _, size in { 13, 14, 16 } do
				for _, count in { "12", "15", "50" } do
					local badge = HudShell.bagSlot(cell, size, count).badge
					assert(badge.width >= #count * size * 0.55, count .. " badge holds its digits")
				end
			end
		end
		local fs = require("@lune/fs")
		local source = fs.readFile("genres/survival-coop/module/HudShell.luau")
		local at = assert(string.find(source, 'if item.Name == "Quantity" then', 1, true))
		local block = string.sub(source, at, at + 400)
		assert(string.find(block, "TextWrapped = false", 1, true), "the count badge never wraps")
	end,
}
