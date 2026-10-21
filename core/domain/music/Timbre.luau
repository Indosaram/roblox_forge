--!strict
-- First-party deterministic sample-bank renderer using the repository DSP engine.
-- Profiles and drum mapping come from generated content, never imported score text.
local Synth = require("../procgen/Synth")
local Rng = require("../random/Rng")
local M = {}

function M.render(
	instrument: any,
	pitch: number,
	velocity: number,
	duration: number,
	sampleRate: number,
	seed: number
): any
	local profile = instrument
	if instrument.drums then
		profile = instrument.drums[(pitch - instrument.pitchMin) % #instrument.drums + 1]
	end
	local frequency = if instrument.drums then profile.frequency else 440 * 2 ^ ((pitch - 69) / 12)
	local result = Synth.buffer(duration + profile.release, sampleRate)
	local rng = Rng.new(seed):fork("instrument-" .. instrument.id)
	for index = 1, #result.samples do
		local t = (index - 1) / sampleRate
		local attack = math.min(1, t / math.max(profile.attack, 1 / sampleRate))
		local envelope = attack * math.exp(-profile.decay * t)
		if t > duration then
			envelope *= math.max(0, 1 - (t - duration) / profile.release)
		end
		local sample = 0
		for harmonic, gain in profile.harmonics do
			sample += math.sin(2 * math.pi * frequency * harmonic * t) * gain
		end
		if profile.noise > 0 then
			sample += (rng:nextNumber() * 2 - 1) * profile.noise
		end
		result.samples[index] = math.clamp(sample * envelope * velocity / 127 * profile.gain, -1, 1)
	end
	return result
end

return M
