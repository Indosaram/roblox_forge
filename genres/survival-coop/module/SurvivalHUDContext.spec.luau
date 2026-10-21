--!strict
local Model = require("./SurvivalHUDModel")
local Tutorial = require("./SurvivalTutorial")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Transport = require("../../../core/infra/genre/CommandTransport")
local Settlement = require("../../../core/domain/settlement/Settlement")

return {
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
				{ "then 128 else 16", "then 0 else 16", "geometry" },
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
				assert(width + right <= w and right >= 8, "sheet stays inside horizontal safe area")
				assert(top >= 64 and top + height <= h - (if touch then 128 else 16), "menu and movement remain clear")
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
