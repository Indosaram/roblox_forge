--!strict
local Chapters = require("./Chapters")

return {
	["chapters enforce order levels checkpoints and one-time completion"] = function()
		local state = Chapters.new()
		local catalog = {}
		for index = 1, 8 do
			table.insert(catalog, {
				id = "chapter-" .. index,
				gates = { characterLevel = index, completed = if index > 1 then { "chapter-" .. (index - 1) } else {} },
				objectives = {
					{ id = "gather-" .. index, action = "gather", target = "wood", quantity = 2 },
					{ id = "survey-" .. index, action = "survey", target = "island", quantity = 2 },
				},
				rewards = { coins = index },
			})
		end
		local skipped, order = Chapters.open(state, catalog, catalog[2].id, math.huge)
		assert(not skipped and order == "CHAPTER_ORDER", "sequential opening")
		for index, chapter in catalog do
			local low, gate = Chapters.open(state, catalog, chapter.id, chapter.gates.characterLevel - 1)
			assert(not low and gate == "LEVEL_GATE", "character level admission")
			state = assert(Chapters.open(state, catalog, chapter.id, math.huge))
			local incomplete, reason = Chapters.claim(state, catalog)
			assert(not incomplete and reason == "OBJECTIVES_INCOMPLETE", "incomplete claim refused")
			for _, objective in chapter.objectives do
				for count = 1, objective.quantity do
					local evidence = {
						id = objective.id .. ":" .. count,
						action = objective.action,
						target = objective.target,
						quantity = 1,
						marker = tostring(count),
					}
					state = assert(Chapters.observe(state, catalog, evidence))
					local replay = assert(Chapters.observe(state, catalog, evidence))
					assert(replay.counts[objective.id] == count, "receipt replay cannot double count")
					state = Chapters.restore(replay, catalog)
				end
			end
			local claimed, rewards = Chapters.claim(state, catalog)
			state = assert(claimed, "completed objectives produce claim candidate")
			assert(type(rewards) == "table" and state.completed[chapter.id], "fixed reward candidate")
			assert(state.active == nil and next(state.counts) == nil, "claim clears checkpoints")
			local reopened, refusal = Chapters.open(state, catalog, chapter.id, math.huge)
			assert(not reopened and refusal == "ALREADY_COMPLETED", "completed chapter cannot reopen " .. index)
		end
	end,
	["survey requires distinct markers even with different receipts"] = function()
		local catalog = {
			{
				id = "survey",
				gates = { characterLevel = 1 },
				objectives = { { id = "markers", action = "survey", target = "island", quantity = 2 } },
				rewards = {},
			},
		}
		local state = assert(Chapters.open(Chapters.new(), catalog, "survey", 1))
		state = assert(Chapters.observe(state, catalog, {
			id = "first",
			action = "survey",
			target = "island",
			quantity = 1,
			marker = "north",
		}))
		local repeated, reason = Chapters.observe(state, catalog, {
			id = "second",
			action = "survey",
			target = "island",
			quantity = 1,
			marker = "north",
		})
		assert(not repeated and reason == "DISTINCT_MARKER_REQUIRED", "distinct marker reuse refused")
	end,
}
