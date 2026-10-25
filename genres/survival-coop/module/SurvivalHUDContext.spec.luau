--!strict
local _packText = (require :: any)("../../../games/robango-island/PackText.fixture") -- installs the strings.csv lookup
local Locale = require("./SurvivalHUDLocale")
local Model = require("./SurvivalHUDModel")
local Tutorial = require("./SurvivalTutorial")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Transport = require("../../../core/infra/genre/CommandTransport")
local Settlement = require("../../../core/domain/settlement/Settlement")

return {
	["PC craft action buttons sit wholly above the CoreGui tool hotbar"] = function()
		-- p105/p112: the Reserve bar (sheet bottom -56..-8) overlapped the bottom-70px tool hotbar,
		-- so only its top edge took clicks. ScreenInsets add the top inset; root is inset 12,8 / -24,-16.
		local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(string.find(hud, "craftActions.Position, craftActions.Size = UDim2.new(0, 8, 1, -56)", 1, true))
		for _, viewport in { { 1279, 720 }, { 1280, 662 }, { 1366, 768 }, { 1920, 1080 } } do
			for _, inset in { 0, 36 } do
				local gw, gh = viewport[1], viewport[2] - inset
				local _, y, _, h = Model.contextSheet(gw - 24, gh - 16, false)
				local bottom = inset + 8 + y + h - 8 -- viewport y of the action buttons' bottom edge
				assert(bottom <= viewport[2] - 70, "whole Reserve button clears the hotbar at " .. viewport[2])
				assert(h >= 200, "sheet keeps a usable body")
			end
		end
	end,
	["skill-gated recipes show the missing skill as locked and the refusal names it"] = function()
		local content: any = (require :: any)("../../../games/robango-island/src/shared/SurvivalContent")
		local progression = { level = 1, paid = {} }
		local bag = { items = {}, reservations = {} }
		local recipes = {}
		for _, recipe in content.recipes do
			if recipe.id == "dry-fiber" or recipe.id == "herbivore-feed" then
				table.insert(recipes, { id = recipe.id, inputs = {}, station = recipe.station })
			end
		end
		assert(#recipes == 2, "both campfire recipes exist")
		local rows = Model.recipeOrder(bag, recipes, function()
			return true
		end, nil, { all = true, progression = progression, details = content.recipeDetails })
		local expected = { ["dry-fiber"] = "processing_1", ["herbivore-feed"] = "cooking_1" }
		for _, row in rows do
			assert(not row.ready, row.recipe.id .. " is not craftable at level 1")
			assert(row.skill == expected[row.recipe.id], row.recipe.id .. " names its missing skill node")
		end
		progression.paid = { processing_1 = 1, cooking_1 = 1 }
		for _, row in
			Model.recipeOrder(bag, recipes, function()
				return true
			end, nil, { all = true, progression = progression, details = content.recipeDetails })
		do
			assert(row.ready and row.skill == nil, "learned node unlocks " .. row.recipe.id)
		end
		local node = "cooking_1"
		local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		-- p115 D1: the status line received the raw node id; the HUD stores the localized name.
		local stored = string.match(hud, "\n%s*refusedSkill = ([^\n]+)")
		assert(
			stored == "if row.skill then Locale.skillName(locale, row.skill) else nil",
			"refusal stores the skill name: " .. tostring(stored)
		)
		for _, locale in { "en-us", "ko-kr" } do
			local name = Locale.skillName(locale, node)
			local line = Locale.refusal(locale, "SKILL_NODE_GATE", name)
			assert(string.find(line, name, 1, true), locale .. " refusal names the skill")
			assert(not string.find(line, "%a_%d"), locale .. " refusal has no node id: " .. line)
			assert(line ~= Locale.refusal(locale, "UNKNOWN_REASON"), locale .. " refusal is not the generic line")
		end
		assert(string.find(Locale.skillName("ko-kr", node), "요리", 1, true), "KO skill name")
		assert(string.find(hud, "elseif row.skill then", 1, true), "recipe row shows the locked skill")
		assert(string.find(hud, "Locale.refusal(locale, model.reason, refusedSkill)", 1, true), "status names it")
	end,
	["desktop sheets and menus avoid the CoreGui chat rectangle"] = function()
		for _, viewport in { { 1000, 700 }, { 1346, 790 }, { 1920, 1080 } } do
			local w, h = viewport[1], viewport[2]
			local width, height, top, right = Model.contextSheetBounds(w, h, false)
			local x, y, sw, sh = Model.chatSafe(w, h, w - right - width, top, width, height)
			assert(x >= 540 or y >= 320, "sheet outside chat")
			assert(x + sw <= w and y + sh <= h, "sheet inside viewport")
		end
	end,
	["objective selects the nearest available gatherable and handles an empty island"] = function()
		local near = { available = true, distance = 4 }
		assert(
			Model.nearestGatherable({ { available = false, distance = 1 }, { available = true, distance = 20 }, near })
				== near,
			"depleted nearer node cannot become objective"
		)
		assert(Model.nearestGatherable({}) == nil, "empty island has no invented target")
		assert(Model.nearestGatherable({ { available = false, distance = 1 } }) == nil, "all depleted has no target")
	end,
	["negative controls reject pending modal target and geometry mutations"] = function()
		local source = fs.readFile("genres/survival-coop/module/SurvivalHUDModel.luau")
		local policy = { actions = { "survival-coop:attack" } }
		for _, mutation in
			{
				{ "and pending == nil", "and true", "pending" },
				{ "return not modal", "return true", "modal" },
				{ "attackTarget ~= nil and allowed", "true and allowed", "target" },
				{ "then 128 else M.HOTBAR_CLEAR", "then 0 else M.HOTBAR_CLEAR", "geometry" },
			}
		do
			local start, finish = string.find(source, mutation[1], 1, true)
			assert(start and finish, "mutation anchor exists")
			local changed = string.sub(source, 1, start - 1) .. mutation[2] .. string.sub(source, finish + 1)
			local mutant = luau.load(changed, {
				environment = {
					require = function(path)
						return if string.find(path, "CommandTransport", 1, true) then Transport else Settlement
					end,
				},
			})()
			local actions = mutant.contextActions(
				policy,
				if mutation[3] == "pending" then {} else nil,
				mutation[3] == "modal",
				nil,
				if mutation[3] == "target" then nil else {}
			)
			local _, height, top = mutant.contextSheetBounds(336, 344, true)
			assert(
				if mutation[3] == "geometry" then top + height > 344 - 128 else actions.attack,
				"mutation is caught by regression predicate"
			)
		end
	end,
	["context sheets keep movement space at every required resolution and inset"] = function()
		for _, viewport in { { 360, 640 }, { 640, 360 }, { 1920, 1080 } } do
			for _, inset in { 0, 48 } do
				local w, h = viewport[1] - 24, viewport[2] - 16 - inset
				local touch = viewport[1] < 700
				local width, height, top, right = Model.contextSheetBounds(w, h, touch)
				assert(width > 0 and height >= 100, "usable scroll body")
				local phone = w < 600 and h > w
				assert(
					width + right <= w and right >= (if phone then 0 else 8),
					"sheet stays inside horizontal safe area"
				)
				assert(
					top >= 64 and top + height <= h - (if touch and not phone then 128 else 16),
					"sheet fits its reserved bottom edge"
				)
				if phone then
					assert(width == w and right == 0, "phone uses full-width bottom sheet")
				end
			end
		end
	end,
	["context controls require target authority and an unobstructed settled HUD"] = function()
		local policy =
			{ actions = { "survival-coop:rest", "survival-coop:attack", "survival-coop:dodge", "survival-coop:guard" } }
		local target = {}
		local actions = Model.contextActions(policy, nil, false, target, target)
		assert(actions.rest and actions.attack and actions.dodge and actions.guard, "authorized nearby actions appear")
		for _, denied in
			{
				Model.contextActions(policy, nil, false, nil, nil),
				Model.contextActions(nil, nil, false, target, target),
				Model.contextActions(policy, {}, false, target, target),
				Model.contextActions(policy, nil, true, target, target),
				Model.contextActions({ actions = {} }, nil, false, target, target),
			}
		do
			assert(
				not denied.rest and not denied.attack and not denied.dodge and not denied.guard,
				"unavailable controls disappear"
			)
		end
	end,
	["shoot and stance controls appear for a ranged target and cycle only unlocked stances"] = function()
		local policy = { actions = { "survival-coop:attack-ranged", "survival-coop:stance-set" } }
		local far = {}
		local actions = Model.contextActions(policy, nil, false, nil, nil, far)
		assert(actions.shoot and actions.stance and not actions.attack, "a 30 stud target offers Shoot, not melee")
		assert(not Model.contextActions(policy, nil, true, nil, nil, far).shoot, "modal hides Shoot")
		assert(not Model.contextActions({ actions = {} }, nil, false, nil, nil, far).stance, "undeclared hidden")
		local view = { current = "none", unlocked = { attack = false, shoot = true, defense = true } }
		assert(Model.nextStance(view) == "defense", "skips locked attack")
		view.current = "defense"
		assert(Model.nextStance(view) == "shoot", "next unlocked")
		view.current = "shoot"
		assert(Model.nextStance(view) == "none", "wraps to none")
		assert(Model.nextStance({ current = "none", unlocked = {} }) == nil, "nothing to switch to")
		local function t(key: string): string
			return Locale.text("ko-kr", key)
		end
		assert(Model.stanceLabel("ko-kr", { current = "counter" }, t) == "태세: 역습 [X]", "ko stance label")
	end,
	["landing advances arrival once but airborne and later landings never skip gathering"] = function()
		local count = 0
		local session = Tutorial.resume(nil, function()
			count += 1
		end)
		assert(
			not Tutorial.landed(session, false) and Tutorial.current(session) == "arrive" and count == 0,
			"airborne does not arrive"
		)
		assert(
			Tutorial.landed(session, true) and Tutorial.current(session) == "gather" and count == 1,
			"landing completes arrival"
		)
		assert(
			not Tutorial.landed(session, true) and Tutorial.current(session) == "gather" and count == 1,
			"repeat landing does not skip gather"
		)
	end,
}
