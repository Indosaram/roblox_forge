--!strict
local Match = require("./Match")
local Policy = require("./Policy.fixture")
local function ready(): any
	local state = Match.new("match", Policy)
	for _, actor in { "a", "b" } do
		assert(
			Match.join(state, actor, { level = 60, maxHealth = 100, equipment = { sword = { durability = 10 } } }),
			"Match.spec.luau: 7"
		)
	end
	assert(Match.start(state, 0), "Match.spec.luau: 9")
	return state
end
return {
	["level gate capacity duplicate queue and detached equipment"] = function()
		local state = Match.new("queue", Policy)
		local facts = { level = 59, maxHealth = 100, equipment = { sword = { durability = 10 } } }
		assert(not Match.join(state, "young", facts), "Match.spec.luau: 16")
		assert(not Match.start(state, 0), "Match.spec.luau: 17")
		facts.level = 60
		for index = 1, 15 do
			assert(Match.join(state, tostring(index), facts), "Match.spec.luau: 20")
		end
		assert(not Match.join(state, "16", facts), "Match.spec.luau: 22")
		assert(not Match.join(state, "1", facts), "Match.spec.luau: 23")
		state.actors["1"].equipment.sword.durability = 0
		assert(
			facts.equipment.sword.durability == 10 and state.actors["2"].equipment.sword.durability == 10,
			"Match.spec.luau: 25"
		)
		assert(Match.leave(state, "1") and #state.order == 14, "Match.spec.luau: 26")
		assert(Match.join(state, "16", facts), "Match.spec.luau: 27")
		assert(Match.start(state, 0), "Match.spec.luau: 28")
		assert(not Match.join(state, "late", facts), "Match.spec.luau: 29")
	end,
	["preparation weather boundaries and server action restrictions"] = function()
		local state = ready()
		assert(not Match.action(state, "a", "ranged", 40, 29).ok, "Match.spec.luau: 33")
		assert(Match.action(state, "a", "ranged", 40, 30).ok, "Match.spec.luau: 34")
		assert(Match.weather(state, 149).id == "clear", "Match.spec.luau: 35")
		assert(Match.action(state, "a", "sprint", 0, 150).staminaMultiplier == 1.25, "Match.spec.luau: 36")
		assert(Match.action(state, "a", "ranged", 21, 269).ok, "Match.spec.luau: 37")
		assert(not Match.action(state, "a", "ranged", 21, 270).ok, "Match.spec.luau: 38")
		assert(Match.action(state, "a", "ranged", 20, 270).ok, "Match.spec.luau: 39")
		assert(Match.action(state, "a", "mount", 0, 389).ok, "Match.spec.luau: 40")
		assert(not Match.action(state, "a", "mount", 0, 390).ok, "Match.spec.luau: 41")
		assert(not Match.action(state, "intruder", "mount", 0, 30).ok, "Match.spec.luau: 42")
	end,
	["same tick double elimination draw and desertion elimination"] = function()
		local state = ready()
		assert(Match.tick(state, 30, {}, { a = 100, b = 100 }), "Match.spec.luau: 46")
		assert(state.phase == "finished" and state.winner == nil, "Match.spec.luau: 47")
		assert(not Match.action(state, "a", "sprint", 0, 31).ok, "Match.spec.luau: 48")
		state = ready()
		assert(Match.leave(state, "a"), "Match.spec.luau: 50")
		assert(Match.tick(state, 30, {}, {}), "Match.spec.luau: 51")
		assert(state.winner == "b" and state.actors.a.deserted, "Match.spec.luau: 52")
	end,
	["collapse damage explicit clock stale tick and deadline draw"] = function()
		local state = ready()
		assert(Match.tick(state, 510, {}, {}), "Match.spec.luau: 56")
		assert(Match.tick(state, 511, { a = { x = 120, z = 0 } }, {}), "Match.spec.luau: 57")
		assert(state.actors.a.health == 80 and state.actors.b.health == 100, "Match.spec.luau: 58")
		assert(not Match.tick(state, 510, {}, {}), "Match.spec.luau: 59")
		assert(not Match.tick(state, 511, {}, { a = 80 }), "duplicate tick cannot apply damage twice")
		assert(state.actors.a.health == 80, "duplicate frame preserves health")
		assert(Match.tick(state, 630, { a = { x = 0, z = 0 }, b = { x = 0, z = 0 } }, {}), "Match.spec.luau: 60")
		assert(state.phase == "finished" and not state.winner, "Match.spec.luau: 61")
		assert(not Match.action(state, "a", "mount", 0, 630).ok, "Match.spec.luau: 62")
		state = ready()
		assert(Match.tick(state, 630, {}, { a = 100 }), "Match.spec.luau: 64")
		assert(state.winner == "b", "Match.spec.luau: 65")
		state = ready()
		assert(Match.tick(state, 570, { a = { x = 60, z = 0 }, b = { x = 0, z = 0 } }, {}), "advance to boundary")
		assert(state.actors.a.health == 100, "shrink does not damage before boundary crosses")
		assert(Match.tick(state, 571, { a = { x = 60, z = 0 }, b = { x = 0, z = 0 } }, {}), "cross boundary")
		assert(state.actors.a.health == 80, "integrate only the outside interval")
	end,
	["reward receipts quota UTC rollover and wallet refusal"] = function()
		local state = ready()
		local document: any = { balance = 0 }
		assert(not Match.reward(document, state, "a", 0).ok, "Match.spec.luau: 70")
		assert(Match.tick(state, 30, {}, { b = 100 }), "Match.spec.luau: 71")
		assert(not Match.reward(document, state, "stranger", 0).ok, "Match.spec.luau: 72")
		assert(Match.reward(document, state, "a", 86399).amount == 150, "Match.spec.luau: 73")
		assert(Match.reward(document, state, "a", 86400).amount == 0, "Match.spec.luau: 74")
		assert(document.brawl.days["0"] == 1 and not document.brawl.days["1"], "Match.spec.luau: 75")
		for index = 2, 6 do
			state.id = tostring(index)
			local reward = Match.reward(document, state, "a", 86399)
			assert(reward.amount == (if index <= 5 then 150 else 0), "Match.spec.luau: 79")
		end
		assert(document.balance == 750, "Match.spec.luau: 81")
		state.id = "next-day"
		assert(Match.reward(document, state, "a", 86400).amount == 150, "Match.spec.luau: 83")
		document.balance, state.id = Policy.maximumBalance, "full"
		assert(
			not Match.reward(document, state, "a", 86400).ok and not document.brawl.receipts.full,
			"Match.spec.luau: 85"
		)
	end,
}
