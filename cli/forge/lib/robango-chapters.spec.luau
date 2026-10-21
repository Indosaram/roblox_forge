--!strict
local Chapters = require("../../../core/domain/journal/Chapters")
local Content: any = require("../../../games/robango-island/src/shared/SurvivalContent")
return {
	["eight authored chapters retain sequential checkpoints across reconnect"] = function()
		local state = Chapters.new()
		assert(#Content.chapters == 8, "Chapters.spec.luau: invariant at line 7")
		local _, locked = Chapters.open(state, Content.chapters, Content.chapters[1].id, 19)
		assert(locked == "LEVEL_GATE", "Chapters.spec.luau: invariant at line 9")
		local _, order = Chapters.open(state, Content.chapters, Content.chapters[2].id, 60)
		assert(order == "CHAPTER_ORDER", "Chapters.spec.luau: invariant at line 11")
		for _, chapter in Content.chapters do
			state = assert(
				Chapters.open(state, Content.chapters, chapter.id, chapter.gates.characterLevel),
				"Chapters.spec.luau: invariant at line 13"
			)
			assert(not Chapters.claim(state, Content.chapters), "Chapters.spec.luau: invariant at line 14")
			local _, wrong = Chapters.observe(
				state,
				Content.chapters,
				{ id = "forged", action = "speak", target = "nobody", quantity = 1 }
			)
			assert(wrong == "WRONG_OBJECTIVE", "Chapters.spec.luau: invariant at line 20")
			for _, objective in chapter.objectives do
				for count = 1, objective.quantity do
					local event = {
						id = objective.id .. count,
						action = objective.action,
						target = objective.target,
						quantity = 1,
						marker = tostring(count),
					}
					state = assert(
						Chapters.observe(state, Content.chapters, event),
						"Chapters.spec.luau: invariant at line 30"
					)
					local duplicate = assert(
						Chapters.observe(state, Content.chapters, event),
						"Chapters.spec.luau: invariant at line 31"
					)
					assert(
						duplicate.counts[objective.id] == state.counts[objective.id],
						"Chapters.spec.luau: invariant at line 32"
					)
					state = Chapters.restore(Chapters.copy(state), Content.chapters)
				end
			end
			local nextState, reward = Chapters.claim(state, Content.chapters)
			assert(
				nextState and reward.coins == chapter.rewards.coins and reward.xp == chapter.rewards.xp,
				"Chapters.spec.luau: invariant at line 37"
			)
			state = nextState
			assert(
				not Chapters.open(state, Content.chapters, chapter.id, 60),
				"Chapters.spec.luau: invariant at line 39"
			)
		end
		for _, chapter in Content.chapters do
			assert(state.completed[chapter.id], "Chapters.spec.luau: invariant at line 42")
		end
	end,
	["forged save order and reused survey markers are refused"] = function()
		local state = Chapters.new()
		state.completed[Content.chapters[2].id] = true
		assert(not pcall(Chapters.restore, state, Content.chapters), "Chapters.spec.luau: invariant at line 48")
		local chapter = {
			id = "one",
			gates = { characterLevel = 20 },
			objectives = { { id = "scan", action = "survey", target = "site", quantity = 5 } },
		}
		local catalog = { chapter }
		state = assert(Chapters.open(Chapters.new(), catalog, "one", 20), "Chapters.spec.luau: invariant at line 55")
		state = assert(
			Chapters.observe(
				state,
				catalog,
				{ id = "a", action = "survey", target = "site", quantity = 1, marker = "first" }
			),
			"Chapters.spec.luau: invariant at line 56"
		)
		local _, reason = Chapters.observe(
			state,
			catalog,
			{ id = "b", action = "survey", target = "site", quantity = 1, marker = "first" }
		)
		assert(reason == "DISTINCT_MARKER_REQUIRED", "Chapters.spec.luau: invariant at line 68")
		assert(
			not Chapters.observe(
				state,
				catalog,
				{ id = "c", action = "survey", target = "site", quantity = 5, marker = "other" }
			),
			"Chapters.spec.luau: invariant at line 69"
		)
	end,
}
