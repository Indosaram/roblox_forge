--!strict
-- Specs for Music: deterministic rendering, mood differences, bar quantisation,
-- loop-safe edges, and bounded output. Pure Luau, so these run under Lune.

local Music = require("./Music")
local Synth = require("./Synth")

local function render(mood: string, seed: number, duration: number): Synth.Buffer
	return Music.render({ mood = mood, seed = seed, duration = duration, sampleRate = 4000 })
end

local function sameSamples(a: Synth.Buffer, b: Synth.Buffer): boolean
	if #a.samples ~= #b.samples then
		return false
	end
	for i = 1, #a.samples do
		if a.samples[i] ~= b.samples[i] then
			return false
		end
	end
	return true
end

return {
	["plan quantises the requested duration to whole bars"] = function()
		local explore = Music.plan({ mood = "explore", seed = 1, duration = 75 })
		assert(explore.bpm == 84, "explore tempo is 84")
		assert(explore.bars == 26, "75s at 84 BPM rounds to 26 bars")
		assert(explore.seconds >= 60 and explore.seconds <= 90, "explore lands in a 60-90s loop")
		assert(#explore.progression == 4, "explore uses a four-chord progression")

		local siege = Music.plan({ mood = "siege", seed = 1, duration = 70 })
		assert(siege.bpm == 140, "siege tempo is 140")
		assert(siege.bpm > explore.bpm, "siege is faster than explore")
		assert(siege.seconds >= 60 and siege.seconds <= 90, "siege lands in a 60-90s loop")
	end,

	["an unknown mood falls back to explore"] = function()
		local plan = Music.plan({ mood = "boss", seed = 1, duration = 60 })
		assert(plan.mood == "explore", "unknown moods fall back to explore")
	end,

	["render is deterministic for a seed"] = function()
		local a = render("explore", 1001, 20)
		local b = render("explore", 1001, 20)
		assert(sameSamples(a, b), "the same spec renders identical samples")
	end,

	["different seeds produce different tracks"] = function()
		local a = render("siege", 1002, 20)
		local b = render("siege", 1003, 20)
		assert(not sameSamples(a, b), "different seeds must diverge")
	end,

	["moods differ"] = function()
		local explore = render("explore", 5, 20)
		local siege = render("siege", 5, 20)
		assert(#explore.samples ~= #siege.samples or not sameSamples(explore, siege), "moods must render differently")
	end,

	["render length matches the plan and stays bounded"] = function()
		for _, mood in { "explore", "siege" } do
			local plan = Music.plan({ mood = mood, seed = 9, duration = 20, sampleRate = 4000 })
			local buffer = Music.render({ mood = mood, seed = 9, duration = 20, sampleRate = 4000 })
			assert(#buffer.samples == math.floor(plan.seconds * 4000 + 0.5), "sample count matches the plan")
			local peak = Synth.peak(buffer)
			assert(peak > 0.2, mood .. " must not be silent")
			assert(peak <= 0.851, mood .. " must stay normalised below 1")
		end
	end,

	["track edges fade to silence for looping"] = function()
		local buffer = render("explore", 3, 20)
		assert(math.abs(buffer.samples[1]) < 1e-6, "the first sample is silent")
		assert(math.abs(buffer.samples[#buffer.samples]) < 1e-6, "the last sample is silent")
	end,
}
