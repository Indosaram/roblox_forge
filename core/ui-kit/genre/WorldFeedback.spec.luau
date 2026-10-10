--!strict
-- Specs for the world-feedback policy: the visual state a snapshot implies for a
-- node, and the floating-text lines between two snapshots. Pure data, no engine.

local WorldFeedback = require("./WorldFeedback")

--- A node literal is `any`: an array of nodes is heterogeneous (a node with a
--- control and one without, feedback entries of different kinds), and Luau
--- unifies an array literal's element types, so the literal is cast through this.
local function node(entry: any): any
	return entry
end

local WORLD: any = {
	name = "World",
	nodes = {
		node({
			id = "plot-a",
			kind = "node",
			position = { 8, 1, 0 },
			feedback = {
				{ kind = "growth", field = "plots.1", entity = "carrot", label = "Crop", cue = "grow-harvest-plant" },
			},
		}),
		node({
			id = "meadow-camp",
			kind = "station",
			position = { 0, 1, 10 },
			control = "rpg-progression:strike-slime",
			feedback = {
				{
					kind = "health",
					field = "activeBosses.slime",
					entity = "slime",
					max = 2,
					label = "Slime",
					cue = "rpg-progression-strike",
				},
			},
		}),
		node({
			id = "queue-desk",
			kind = "station",
			position = { 0, 1, 8 },
			control = "pvp-arena:queue",
			feedback = {
				{ kind = "lamp", field = "queued", active = true, label = "Queued", cue = "pvp-arena-queue" },
			},
		}),
		node({
			id = "mirror",
			kind = "station",
			position = { 0, 1, 8 },
			control = "social-rp-fashion:equip-hat",
			feedback = {
				{
					kind = "outfit",
					field = "equipped",
					entity = "starter-hat",
					label = "Hat",
					cue = "social-rp-fashion-equip",
				},
			},
		}),
		node({
			id = "market-stall",
			kind = "depot",
			position = { 40, 1, 0 },
			control = "grow-harvest:sell",
			feedback = {
				{ kind = "counter", field = "balance", label = "Coins", cue = "grow-harvest-sell" },
			},
		}),
	},
}

local CUES = {
	["grow-harvest-plant"] = true,
	["grow-harvest-sell"] = true,
	["rpg-progression-strike"] = true,
	["pvp-arena-queue"] = true,
	["social-rp-fashion-equip"] = true,
}

return {
	["every declared binding is flattened with its node"] = function()
		local bindings = WorldFeedback.bindings(WORLD)
		assert(#bindings == 5, "one row per declared binding")
		assert(bindings[1].nodeId == "plot-a" and bindings[1].kind == "growth", "the first node's binding comes first")
		assert(
			bindings[5].nodeId == "market-stall" and bindings[5].kind == "counter",
			"the last node's binding comes last"
		)
		assert(#WorldFeedback.nodes(WORLD) == 5, "each binding's node is reported once")
	end,

	["a crop grows through its stages from the plot snapshot"] = function()
		local binding = WorldFeedback.bindings(WORLD)[1]
		assert(WorldFeedback.state(binding, { plots = { { plot = 1 } } }).stage == 0, "an empty plot shows no crop")
		assert(
			WorldFeedback.state(binding, { plots = { { plot = 1, cropId = "carrot", ready = false } } }).stage == 1,
			"a planted crop is a sprout"
		)
		assert(
			WorldFeedback.state(binding, { plots = { { plot = 1, cropId = "carrot", ready = true } } }).stage == 2,
			"a ripe crop is ready"
		)
	end,

	["an enemy's health bar empties and reports a defeat"] = function()
		local binding = WorldFeedback.bindings(WORLD)[2]
		local full = WorldFeedback.state(binding, { activeBosses = { slime = 2 } })
		assert(full.fraction == 1 and not full.defeated, "full health is a full bar")
		local half = WorldFeedback.state(binding, { activeBosses = { slime = 1 } })
		assert(half.fraction == 0.5, "one of two is half the bar")
		local down = WorldFeedback.state(binding, { activeBosses = {} })
		assert(down.fraction == 0 and down.defeated, "no health is a defeat")
	end,

	["a pad lights while its field holds the active value"] = function()
		local binding = WorldFeedback.bindings(WORLD)[3]
		assert(WorldFeedback.state(binding, { queued = true }).active, "queued lights the pad")
		assert(not WorldFeedback.state(binding, { queued = false }).active, "not queued leaves it dark")
		assert(not WorldFeedback.state(binding, {}).active, "an absent field leaves it dark")
	end,

	["an outfit is worn while the equipped map holds it"] = function()
		local binding = WorldFeedback.bindings(WORLD)[4]
		assert(WorldFeedback.state(binding, { equipped = { hat = "starter-hat" } }).worn, "the equipped hat is worn")
		assert(not WorldFeedback.state(binding, { equipped = {} }).worn, "an empty outfit wears nothing")
		assert(
			not WorldFeedback.state(binding, { equipped = { hat = "other" } }).worn,
			"a different hat is not this one"
		)
	end,

	["a numeric change produces a signed floating-text line"] = function()
		local world: any = {
			nodes = {
				node({
					id = "stall",
					kind = "depot",
					feedback = {
						{ kind = "counter", field = "balance", label = "Coins", cue = "grow-harvest-sell" },
					},
				}),
			},
		}
		local deltas = WorldFeedback.deltas(world, { balance = 9 }, { balance = 19 })
		assert(#deltas == 1, "one reaction for one change")
		assert(deltas[1].text == "Coins +10", "the delta is signed: " .. tostring(deltas[1].text))
		assert(deltas[1].cue == "grow-harvest-sell", "the bound cue travels with the reaction")
		assert(#WorldFeedback.deltas(world, { balance = 19 }, { balance = 19 }) == 0, "no change, no reaction")
	end,

	["a crop ripening produces the declared copy, not a number"] = function()
		local binding = WorldFeedback.bindings(WORLD)[1]
		local world: any = {
			nodes = {
				node({
					id = "plot-a",
					kind = "node",
					feedback = {
						{
							kind = "growth",
							field = "plots.1",
							entity = "carrot",
							label = "Crop",
						},
					},
				}),
			},
		}
		local before = { plots = { { plot = 1, cropId = "carrot", ready = false } } }
		local after = { plots = { { plot = 1, cropId = "carrot", ready = true } } }
		local deltas = WorldFeedback.deltas(world, before, after)
		assert(#deltas == 1 and deltas[1].text == "Crop", "a ripening crop says its label")
		assert(binding.label == "Crop", "the binding carries the copy")
	end,

	["a malformed binding is reported"] = function()
		local world: any = {
			nodes = {
				node({ id = "a", kind = "node", feedback = { { kind = "sparkle", field = "x", label = "X" } } }),
				node({
					id = "b",
					kind = "node",
					feedback = { { kind = "health", field = "hp", label = "Hp", max = 0 } },
				}),
				node({ id = "c", kind = "node", feedback = { { kind = "outfit", field = "equipped", label = "Hat" } } }),
				node({
					id = "d",
					kind = "node",
					feedback = { { kind = "counter", field = "coins", label = "Coins", cue = "nope" } },
				}),
			},
		}
		local errors = WorldFeedback.violations(world, CUES)
		assert(#errors == 4, "one per malformed binding: " .. table.concat(errors, "; "))
		assert(string.find(table.concat(errors, "\n"), "sparkle", 1, true) ~= nil, "the unknown kind is named")
		assert(string.find(table.concat(errors, "\n"), "full-health", 1, true) ~= nil, "the health maximum is named")
		assert(
			string.find(table.concat(errors, "\n"), "names the outfit", 1, true) ~= nil,
			"the missing outfit is named"
		)
		assert(string.find(table.concat(errors, "\n"), "nope", 1, true) ~= nil, "the undeclared cue is named")
	end,

	["a well-formed world reports nothing"] = function()
		assert(#WorldFeedback.violations(WORLD, CUES) == 0, "the four thin genres' bindings are well formed")
	end,
}
