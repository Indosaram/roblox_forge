--!strict
-- Specs for audiocues: audio.yml planning/validation and deterministic cue
-- rendering for SFX and ambience (music is covered by Music.spec).

local Audiocues = require("./audiocues")
local Synth = require("../../../core/domain/procgen/Synth")
local Music = require("../../../core/domain/procgen/Music")
local wav = require("./wav")

local SFX_TYPES = { "click", "coin", "hatch", "rare", "raid", "error" }
local AMBIENCE_TYPES = { "wind", "birds" }

local function cue(kind: string, extra: any): any
	local value: any = { key = "testCue", kind = kind, duration = 0.4, seed = 42 }
	for name, field in extra or {} do
		value[name] = field
	end
	return value
end

local function planOne(value: any): Audiocues.Cue
	local cues, errors = Audiocues.plan({ cues = { value } })
	assert(cues ~= nil, "expected a valid plan: " .. table.concat(errors, "; "))
	return (cues :: { Audiocues.Cue })[1]
end

local function peakOf(buffer: Synth.Buffer): number
	return Synth.peak(buffer)
end

return {
	["genre namespaced cue keys accept hyphens but reject path separators"] = function()
		local planned = planOne(cue("sfx", { key = "pvp-arena-action", type = "raid" }))
		assert(planned.key == "pvp-arena-action", "namespaced cue key preserved")
		for _, key in { "../action", "genre/action", "genre\\action", "genre:action", "genre action" } do
			local cues, errors = Audiocues.plan({ cues = { cue("sfx", { key = key, type = "raid" }) } })
			assert(cues == nil and #errors > 0, "unsafe asset path key rejected")
		end
	end,

	["unsupported DSP sample rates do not produce a plan"] = function()
		for _, rate in { 1, 2 } do
			local cues, errors = Audiocues.plan({ cues = { cue("sfx", { type = "error", sampleRate = rate }) } })
			assert(cues == nil and #errors == 1, "unsupported filter rate is rejected at planning")
			assert(string.find(errors[1], "sampleRate", 1, true) ~= nil, "diagnostic identifies sampleRate")
		end
	end,

	["all accepted recipes render at minimum and ordinary sample rates"] = function()
		local entries: { any } = {}
		for _, sfxType in SFX_TYPES do
			table.insert(entries, cue("sfx", { type = sfxType }))
		end
		for _, ambienceType in AMBIENCE_TYPES do
			table.insert(entries, cue("ambience", { type = ambienceType }))
		end
		for _, mood in { "explore", "siege" } do
			table.insert(entries, cue("music", { mood = mood }))
		end
		for _, rate in { 3, 8000 } do
			for _, entry in entries do
				entry.sampleRate = rate
				entry.duration = 2
				local planned = planOne(entry)
				local sound = Audiocues.render(planned)
				local seconds = if planned.kind == "music"
					then Music.plan({ seed = planned.seed, duration = planned.duration, mood = planned.mood }).seconds
					else planned.duration
				assert(
					sound.sampleRate == rate and #sound.samples == math.floor(seconds * rate + 0.5),
					"renderer keeps planned rate and length"
				)
				for _, sample in sound.samples do
					assert(sample == sample and math.abs(sample) <= 1, "rendered samples are finite and bounded")
				end
				local data = wav.encode(sound)
				assert(buffer.readu32(data, 24) == rate, "rendered WAV keeps sampleRate")
				assert(buffer.readu32(data, 28) == rate * 2, "rendered WAV keeps byte rate")
			end
		end
	end,

	["rejects fractional and nonrepresentable sample rates before rendering"] = function()
		local invalidRates: { any } =
			{ 1, 2, 0.5, 44100.5, 0, -1, math.huge, -math.huge, 0 / 0, 2147483648, 4294967296, "44100", false }
		for _, rate in invalidRates do
			local cues, errors = Audiocues.plan({ cues = { cue("sfx", { type = "click", sampleRate = rate }) } })
			assert(cues == nil and #errors == 1, "invalid sampleRate must not produce a renderable plan")
		end
	end,

	["accepted integer and default sample rates match decoded WAV byte rates"] = function()
		for _, rate in { 3, 8000, 22050, 44100, 48000, 2147483647 } do
			-- Keep even the maximum header rate to one sample, without large allocations.
			local planned = planOne(cue("sfx", { type = "error", sampleRate = rate, duration = 1 / rate }))
			assert(planned.sampleRate == rate, "explicit integer rate is kept")
			local sound = Audiocues.render(planned)
			local data = wav.encode(sound)
			assert(buffer.readu32(data, 24) == rate, "WAV rate is exact")
			assert(buffer.readu32(data, 28) == buffer.readu32(data, 24) * 2, "mono PCM byte rate is consistent")
			assert(buffer.readu32(data, 40) == #sound.samples * 2, "PCM data length is consistent")
		end
		local planned = planOne(cue("sfx", { type = "click", duration = 0.001 }))
		local data = wav.encode(Audiocues.render(planned))
		assert(planned.sampleRate == 44100 and buffer.readu32(data, 24) == 44100, "default rate is preserved")
		assert(buffer.readu32(data, 28) == 88200, "default byte rate is consistent")
	end,

	["plans music, sfx, and ambience cues"] = function()
		local entries: { any } = {
			{ key = "musicExplore", kind = "music", mood = "explore", duration = 75, sampleRate = 22050, seed = 1 },
			{ key = "sfxClick", kind = "sfx", type = "click", duration = 0.12, seed = 2 },
			{ key = "ambienceWind", kind = "ambience", type = "wind", duration = 8, seed = 3 },
		}
		local cues, errors = Audiocues.plan({ cues = entries })
		assert(cues ~= nil, "valid cues must plan: " .. table.concat(errors, "; "))
		local list = cues :: { Audiocues.Cue }
		assert(#list == 3, "all three cues plan")
		assert(list[2].sampleRate == 44100, "sampleRate defaults to 44100")
		assert(list[1].sampleRate == 22050, "explicit sampleRate is kept")
	end,

	["rejects malformed cues"] = function()
		local entries: { any } = {
			{ key = "9bad", kind = "sfx", type = "click", duration = 0.1, seed = 1 },
			{ key = "badKind", kind = "voice", duration = 0.1, seed = 1 },
			{ key = "badMood", kind = "music", mood = "loud", duration = 10, seed = 1 },
			{ key = "noType", kind = "sfx", duration = 0.1, seed = 1 },
			{ key = "noDuration", kind = "sfx", type = "click", seed = 1 },
			{ key = "dup", kind = "sfx", type = "click", duration = 0.1, seed = 1 },
			{ key = "dup", kind = "sfx", type = "click", duration = 0.1, seed = 2 },
		}
		local _, errors = Audiocues.plan({ cues = entries })
		assert(#errors >= 6, "every malformed cue is reported: " .. table.concat(errors, "; "))
	end,

	["every sfx type renders non-silent and bounded"] = function()
		for _, sfxType in SFX_TYPES do
			local planned = planOne(cue("sfx", { type = sfxType }))
			local buffer = Audiocues.render(planned)
			assert(#buffer.samples == math.floor(planned.duration * planned.sampleRate + 0.5), sfxType .. " length")
			local peak = peakOf(buffer)
			assert(peak > 0.05, sfxType .. " must be audible")
			assert(peak <= 0.91, sfxType .. " must be bounded")
		end
	end,

	["sfx rendering is deterministic"] = function()
		for _, sfxType in SFX_TYPES do
			local planned = planOne(cue("sfx", { type = sfxType }))
			local a = Audiocues.render(planned)
			local b = Audiocues.render(planned)
			assert(#a.samples == #b.samples, sfxType .. " length matches")
			for i = 1, #a.samples do
				assert(a.samples[i] == b.samples[i], sfxType .. " sample " .. i .. " matches")
			end
		end
	end,

	["ambience is loopable and bounded"] = function()
		for _, ambienceType in AMBIENCE_TYPES do
			local planned = planOne(cue("ambience", { type = ambienceType, duration = 8, sampleRate = 8000 }))
			local buffer = Audiocues.render(planned)
			assert(#buffer.samples == 8 * 8000, ambienceType .. " is 8s")
			assert(math.abs(buffer.samples[1]) < 1e-6, ambienceType .. " starts silent")
			assert(math.abs(buffer.samples[#buffer.samples]) < 1e-6, ambienceType .. " ends silent")
			local peak = peakOf(buffer)
			assert(peak > 0.05 and peak <= 0.61, ambienceType .. " is audible and bounded")
		end
	end,

	["ambience rendering is deterministic"] = function()
		for _, ambienceType in AMBIENCE_TYPES do
			local planned = planOne(cue("ambience", { type = ambienceType, duration = 8, sampleRate = 8000 }))
			local a = Audiocues.render(planned)
			local b = Audiocues.render(planned)
			for i = 1, #a.samples do
				assert(a.samples[i] == b.samples[i], ambienceType .. " sample " .. i .. " matches")
			end
		end
	end,

	["music cues dispatch to the composer"] = function()
		local planned = planOne(cue("music", { mood = "siege", duration = 20, sampleRate = 4000 }))
		local buffer = Audiocues.render(planned)
		assert(#buffer.samples > 0, "music renders samples")
		assert(buffer.sampleRate == 4000, "music keeps the cue sample rate")
	end,
}
