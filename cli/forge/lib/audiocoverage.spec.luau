--!strict
-- Specs for Audiocoverage. Pure data, no Roblox APIs.

local Audiocoverage = require("./Audiocoverage")

local tests = {}

function tests.grow_harvest_declares_the_four_loop_cues()
	local cues = Audiocoverage.declaredCues("grow-harvest")
	assert(cues ~= nil, "grow-harvest must ship module/Audio.luau")
	table.sort(cues)
	assert(#cues == 4, "expected 4 grow-harvest cues, got " .. tostring(#cues))
	for _, expected in { "grow-harvest-buy", "grow-harvest-harvest", "grow-harvest-plant", "grow-harvest-sell" } do
		local found = false
		for _, key in cues do
			if key == expected then
				found = true
			end
		end
		assert(found, "grow-harvest must declare " .. expected)
	end
end

function tests.garden_covers_every_declared_cue()
	local manifest = {
		assets = {
			{ key = "grow-harvest-buy" },
			{ key = "grow-harvest-plant" },
			{ key = "grow-harvest-harvest" },
			{ key = "grow-harvest-sell" },
		},
	}
	local missing = Audiocoverage.missingContentIds("grow-and-defend-garden", manifest)
	assert(#missing == 0, "garden should cover every cue, missing: " .. table.concat(missing, ", "))
end

function tests.a_dropped_cue_is_reported()
	-- The regression this guard exists for: an empty manifest must report all
	-- four cues instead of passing silently.
	local missing = Audiocoverage.missingContentIds("grow-and-defend-garden", { assets = {} })
	assert(#missing == 4, "empty manifest must report 4 missing cues, got " .. tostring(#missing))
	assert(missing[1] == "grow-harvest-buy", "missing list must be sorted, got " .. tostring(missing[1]))
end

function tests.unknown_genre_is_skipped_not_failed()
	-- A genre without a runtime Audio module reads its cues from the serialized
	-- spec; it is not this guard's business.
	local missing = Audiocoverage.missingContentIds("grow-and-defend-garden", { assets = {} })
	assert(#missing <= 4, "must only report grow-harvest cues")
end

return tests
