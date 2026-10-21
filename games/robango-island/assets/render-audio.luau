--!strict
-- First-party offline recipes. Never publishes, installs, or edits generated runtime code.
local Synth = require("../../../core/domain/procgen/Synth")
local Music = require("../../../core/domain/procgen/Music")
local Rng = require("../../../core/domain/random/Rng")
local Audiocues = require("../../../cli/forge/lib/audiocues")
local M = {}
function M.render(cue: any, sampleRate: number): Synth.Buffer
	if cue.kind == "music" then
		return Music.render({ seed = cue.seed, duration = cue.duration, sampleRate = sampleRate, mood = cue.mood })
	end
	if table.find({ "click", "coin", "rare", "error", "raid" }, cue.type) then
		local normalized = table.clone(cue)
		normalized.sampleRate = sampleRate
		return Audiocues.render(normalized)
	end
	local rng = Rng.new(cue.seed):fork(cue.key)
	local noise: Synth.Rng = {
		next = function()
			return rng:nextNumber()
		end,
		range = function(lo, hi)
			return lo + (hi - lo) * rng:nextNumber()
		end,
		int = function(lo, hi)
			return rng:nextInteger(lo, hi)
		end,
		sign = function()
			return if rng:nextNumber() < 0.5 then -1 else 1
		end,
	}
	local sound = Synth.buffer(cue.duration, sampleRate)
	local kind, duration = cue.type, cue.duration
	local tonal = kind == "call" or kind == "horn"
	local frequency = cue.frequency or (if kind == "horn" then 174.6 elseif kind == "stone" then 1250 else 145)
	Synth.addVoice(sound, {
		start = 0,
		duration = duration,
		freq = frequency,
		freqEnd = frequency * (if tonal then 0.72 else 0.45),
		shape = if tonal then "saw" elseif kind == "wood" or kind == "impact" then "triangle" else "noise",
		amp = 0.65,
		rng = noise,
		fmRatio = if kind == "call" then 0.7 else 2,
		fmIndex = if kind == "call" then 2.5 else 0.15,
		env = {
			attack = if tonal then 0.09 else 0.002,
			decay = duration * 0.3,
			sustain = if tonal or kind == "fire" then 0.45 else 0,
			release = duration * 0.25,
		},
	})
	if kind == "stone" then
		Synth.addVoice(sound, {
			start = 0,
			duration = duration * 0.7,
			freq = 2137,
			shape = "sine",
			amp = 0.25,
			env = { attack = 0.001, decay = duration * 0.5, sustain = 0, release = 0.02 },
		})
	elseif kind == "fire" then
		for _ = 1, 24 do
			Synth.addVoice(sound, {
				start = rng:nextNumber() * (duration - 0.05),
				duration = 0.04,
				freq = 1,
				shape = "noise",
				amp = 0.3,
				rng = noise,
				env = { attack = 0.001, decay = 0.02, sustain = 0, release = 0.01 },
			})
		end
	end
	Synth.lowpass(sound, if kind == "plant" then 3200 elseif kind == "sand" then 1600 elseif tonal then 1800 else 5000)
	Synth.normalize(sound, 0.8)
	-- Explicit boundary fades keep every looping bed seam click-free.
	local edge = math.min(math.floor(sampleRate * 0.015), math.floor(#sound.samples / 2))
	for i = 1, edge do
		local gain = (i - 1) / edge
		sound.samples[i] *= gain
		sound.samples[#sound.samples - i + 1] *= gain
	end
	return sound
end
return M
