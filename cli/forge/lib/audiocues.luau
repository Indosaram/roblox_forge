--!strict
-- audiocues: pure planning and rendering for a pack's assets/audio.yml cue
-- list. Music cues delegate to the scene composer in core/domain/procgen;
-- ambience and sound effects are small deterministic recipes built from Synth
-- primitives. No Roblox APIs, no Lune APIs, no network, no math.random, so
-- `forge gen audio` writes byte-identical WAVs on every run.

local Synth = require("../../../core/domain/procgen/Synth")
local Music = require("../../../core/domain/procgen/Music")

local Audiocues = {}

-- Version of the synthesis recipe in this module plus the core DSP it calls.
-- Bump it whenever a change alters the bytes a cue renders to, so a recorded
-- artifact names the exact recipe that produced it.
Audiocues.RECIPE_VERSION = "1"

export type Cue = {
	key: string,
	kind: string,
	mood: string?,
	type: string?,
	duration: number,
	sampleRate: number,
	seed: number,
}

local KINDS: { [string]: boolean } = { music = true, sfx = true, ambience = true }
local SFX_TYPES: { [string]: boolean } = {
	click = true,
	coin = true,
	hatch = true,
	rare = true,
	raid = true,
	error = true,
}
local AMBIENCE_TYPES: { [string]: boolean } = { wind = true, birds = true }
local MOODS: { [string]: boolean } = { explore = true, siege = true }
local KEY_PATTERN = "^[%a][%w_%-]*$"
local DEFAULT_SAMPLE_RATE = 44100
-- Synth filters clamp cutoff to [1, sampleRate * 0.45], requiring at least 3 Hz.
local MIN_SAMPLE_RATE = 3
-- Mono 16-bit WAV stores both sampleRate and sampleRate * 2 as uint32.
local MAX_SAMPLE_RATE = 2147483647

local function isPositiveNumber(value: any): boolean
	return type(value) == "number" and value > 0 and value == value and value < math.huge
end

local function isSampleRate(value: any): boolean
	return isPositiveNumber(value) and value % 1 == 0 and value >= MIN_SAMPLE_RATE and value <= MAX_SAMPLE_RATE
end

--- Validates and normalises a decoded audio.yml. Returns the cue list, or
--- (nil, errors) naming every problem found.
function Audiocues.plan(doc: any): ({ Cue }?, { string })
	local errors: { string } = {}
	if type(doc) ~= "table" or type(doc.cues) ~= "table" then
		return nil, { "audio.yml: expected a top-level 'cues' list" }
	end

	local cues: { Cue } = {}
	local seen: { [string]: boolean } = {}
	for index, raw in doc.cues do
		local label = "audio.yml: cue " .. tostring(index)
		if type(raw) ~= "table" then
			table.insert(errors, label .. " is not a table")
		else
			local key = raw.key
			if type(key) ~= "string" or string.match(key, KEY_PATTERN) == nil then
				table.insert(errors, label .. " has an invalid key '" .. tostring(key) .. "'")
			elseif seen[key] then
				table.insert(errors, label .. " duplicates key '" .. key .. "'")
			else
				seen[key] = true
				label = "audio.yml: cue " .. key
			end

			local kind = raw.kind
			if type(kind) ~= "string" or not KINDS[kind] then
				table.insert(errors, label .. " has an invalid kind '" .. tostring(kind) .. "'")
			elseif kind == "music" then
				if type(raw.mood) ~= "string" or not MOODS[raw.mood] then
					table.insert(errors, label .. " needs a mood of explore|siege")
				end
			elseif kind == "sfx" then
				if type(raw.type) ~= "string" or not SFX_TYPES[raw.type] then
					table.insert(
						errors,
						label
							.. " needs a type of "
							.. table.concat({ "click", "coin", "hatch", "rare", "raid", "error" }, "|")
					)
				end
			elseif type(raw.type) ~= "string" or not AMBIENCE_TYPES[raw.type] then
				table.insert(errors, label .. " needs a type of wind|birds")
			end

			if not isPositiveNumber(raw.duration) then
				table.insert(errors, label .. " needs a positive duration")
			end
			if type(raw.seed) ~= "number" then
				table.insert(errors, label .. " needs a numeric seed")
			end
			if raw.sampleRate ~= nil and not isSampleRate(raw.sampleRate) then
				table.insert(errors, label .. " has an invalid sampleRate (expected an integer from 3 to 2147483647)")
			end

			if
				type(key) == "string"
				and type(kind) == "string"
				and KINDS[kind]
				and isPositiveNumber(raw.duration)
				and type(raw.seed) == "number"
			then
				table.insert(cues, {
					key = key,
					kind = kind,
					mood = if type(raw.mood) == "string" then raw.mood else nil,
					type = if type(raw.type) == "string" then raw.type else nil,
					duration = raw.duration,
					sampleRate = if raw.sampleRate ~= nil then raw.sampleRate else DEFAULT_SAMPLE_RATE,
					seed = raw.seed,
				})
			end
		end
	end

	if #errors > 0 then
		return nil, errors
	end
	return cues, {}
end

local function midiToFreq(note: number): number
	return 440 * 2 ^ ((note - 69) / 12)
end

-- Adds a struck bell tone: a sine fundamental with a touch of FM plus a quiet
-- octave partial, both decaying to silence.
local function addBell(buffer: Synth.Buffer, start: number, freq: number, amp: number, ring: number): ()
	Synth.addVoice(buffer, {
		start = start,
		duration = ring,
		freq = freq,
		shape = "sine",
		amp = amp,
		fmRatio = 3.5,
		fmIndex = 0.5,
		env = { attack = 0.002, decay = ring * 0.7, sustain = 0, release = 0.02 },
	})
	Synth.addVoice(buffer, {
		start = start,
		duration = ring * 0.6,
		freq = freq * 2.01,
		shape = "sine",
		amp = amp * 0.35,
		env = { attack = 0.002, decay = ring * 0.5, sustain = 0, release = 0.02 },
	})
end

local function renderClick(cue: Cue, rng: Synth.Rng): Synth.Buffer
	local buffer = Synth.buffer(cue.duration, cue.sampleRate)
	Synth.addVoice(buffer, {
		start = 0,
		duration = math.min(0.05, cue.duration),
		freq = 1,
		shape = "noise",
		amp = 0.35,
		env = { attack = 0.0005, decay = 0.02, sustain = 0, release = 0.005 },
		rng = rng,
	})
	Synth.addVoice(buffer, {
		start = 0,
		duration = math.min(0.09, cue.duration),
		freq = 1750,
		freqEnd = 1200,
		shape = "sine",
		amp = 0.7,
		env = { attack = 0.001, decay = 0.06, sustain = 0, release = 0.01 },
	})
	Synth.highpass(buffer, 500)
	return Synth.normalize(buffer, 0.8)
end

local function renderCoin(cue: Cue, _rng: Synth.Rng): Synth.Buffer
	local buffer = Synth.buffer(cue.duration, cue.sampleRate)
	addBell(buffer, 0, midiToFreq(84), 0.7, math.min(0.3, cue.duration))
	addBell(buffer, 0.08, midiToFreq(91), 0.7, math.min(0.35, cue.duration - 0.08))
	Synth.delay(buffer, { time = 0.11, feedback = 0.25, mix = 0.2 })
	return Synth.normalize(buffer, 0.85)
end

local function renderHatch(cue: Cue, rng: Synth.Rng): Synth.Buffer
	local buffer = Synth.buffer(cue.duration, cue.sampleRate)
	Synth.addVoice(buffer, {
		start = 0,
		duration = math.min(0.14, cue.duration),
		freq = 1,
		shape = "noise",
		amp = 0.8,
		env = { attack = 0.0005, decay = 0.05, sustain = 0.1, release = 0.05 },
		rng = rng,
	})
	Synth.highpass(buffer, 900)
	local pop = math.max(0.05, cue.duration - 0.05)
	Synth.addVoice(buffer, {
		start = 0.05,
		duration = pop,
		freq = 220,
		freqEnd = 900,
		shape = "sine",
		amp = 0.7,
		env = { attack = 0.02, decay = 0.1, sustain = 0.5, release = 0.12 },
	})
	Synth.addVoice(buffer, {
		start = 0.05,
		duration = pop,
		freq = 110,
		freqEnd = 450,
		shape = "triangle",
		amp = 0.3,
		env = { attack = 0.02, decay = 0.1, sustain = 0.5, release = 0.12 },
	})
	Synth.addVoice(buffer, {
		start = 0.05,
		duration = math.min(0.12, pop),
		freq = 90,
		freqEnd = 50,
		shape = "sine",
		amp = 0.5,
		env = { attack = 0.001, decay = 0.1, sustain = 0, release = 0.02 },
	})
	return Synth.normalize(buffer, 0.85)
end

local function renderRare(cue: Cue, _rng: Synth.Rng): Synth.Buffer
	local buffer = Synth.buffer(cue.duration, cue.sampleRate)
	local notes = { 72, 76, 79, 84, 88, 91 }
	for index, note in notes do
		local start = (index - 1) * 0.11
		if start < cue.duration then
			addBell(buffer, start, midiToFreq(note), 0.55, math.min(0.28, cue.duration - start))
		end
	end
	Synth.delay(buffer, { time = 0.09, feedback = 0.4, mix = 0.3 })
	Synth.reverb(buffer, { room = 0.7, damp = 0.4, mix = 0.22 })
	return Synth.normalize(buffer, 0.85)
end

local function renderRaid(cue: Cue, rng: Synth.Rng): Synth.Buffer
	local buffer = Synth.buffer(cue.duration, cue.sampleRate)
	local whoosh = math.min(0.4, cue.duration * 0.5)
	Synth.addVoice(buffer, {
		start = 0,
		duration = whoosh,
		freq = 1,
		shape = "noise",
		amp = 0.7,
		env = { attack = 0.12, decay = 0.1, sustain = 0.6, release = 0.15 },
		rng = rng,
	})
	Synth.lowpass(buffer, function(t: number): number
		return 300 + 2600 * math.sin(math.pi * math.min(t / whoosh, 1))
	end)
	local impact = whoosh
	if impact < cue.duration then
		Synth.addVoice(buffer, {
			start = impact,
			duration = math.min(0.4, cue.duration - impact),
			freq = 160,
			freqEnd = 45,
			shape = "sine",
			amp = 0.9,
			env = { attack = 0.001, decay = 0.3, sustain = 0, release = 0.05 },
		})
		Synth.addVoice(buffer, {
			start = impact,
			duration = math.min(0.25, cue.duration - impact),
			freq = 1,
			shape = "noise",
			amp = 0.5,
			env = { attack = 0.001, decay = 0.2, sustain = 0, release = 0.05 },
			rng = rng,
		})
	end
	return Synth.normalize(buffer, 0.9)
end

local function renderError(cue: Cue, _rng: Synth.Rng): Synth.Buffer
	local buffer = Synth.buffer(cue.duration, cue.sampleRate)
	local env: Synth.Env = { attack = 0.005, decay = 0.05, sustain = 0.6, release = 0.1 }
	Synth.addVoice(buffer, {
		start = 0,
		duration = cue.duration,
		freq = 110,
		shape = "square",
		amp = 0.5,
		detune = 0.02,
		env = env,
	})
	Synth.addVoice(buffer, {
		start = 0,
		duration = cue.duration,
		freq = 55,
		shape = "square",
		amp = 0.35,
		env = env,
	})
	Synth.lowpass(buffer, 1200)
	return Synth.normalize(buffer, 0.8)
end

-- A noise bed with one slow filter cycle and an amplitude swell that starts and
-- ends at zero, so the 8s file loops without a click.
local function addWindBed(buffer: Synth.Buffer, rng: Synth.Rng, gain: number): ()
	local duration = Synth.duration(buffer)
	local sr = buffer.sampleRate
	Synth.addVoice(buffer, {
		start = 0,
		duration = duration,
		freq = 1,
		shape = "noise",
		amp = 1,
		env = { attack = 0, decay = 0, sustain = 1, release = 0 },
		rng = rng,
	})
	Synth.lowpass(buffer, function(t: number): number
		return 420 + 300 * math.sin(2 * math.pi * t / duration)
	end)
	Synth.highpass(buffer, 110)
	local samples = buffer.samples
	local phase = 2 * math.pi / duration
	for i = 1, #samples do
		local t = (i - 1) / sr
		samples[i] *= gain * (0.5 - 0.5 * math.cos(phase * t))
	end
end

local function renderWind(cue: Cue, rng: Synth.Rng): Synth.Buffer
	local buffer = Synth.buffer(cue.duration, cue.sampleRate)
	addWindBed(buffer, rng, 1)
	return Synth.normalize(buffer, 0.6)
end

local function renderBirds(cue: Cue, rng: Synth.Rng): Synth.Buffer
	local buffer = Synth.buffer(cue.duration, cue.sampleRate)
	local bed = Synth.buffer(cue.duration, cue.sampleRate)
	addWindBed(bed, rng, 0.12)
	Synth.add(buffer, bed)
	for _ = 1, 9 do
		local start = 0.4 + rng.range(0, cue.duration - 0.8)
		local length = rng.range(0.05, 0.12)
		local base = rng.range(1800, 3600)
		Synth.addVoice(buffer, {
			start = start,
			duration = length,
			freq = base,
			freqEnd = base * rng.range(1.2, 1.6),
			shape = "sine",
			amp = 0.5,
			fmRatio = 2,
			fmIndex = rng.range(0.5, 1.5),
			env = { attack = 0.004, decay = length * 0.5, sustain = 0.1, release = 0.02 },
		})
	end
	return Synth.normalize(buffer, 0.5)
end

local SFX_RENDERERS: { [string]: (Cue, Synth.Rng) -> Synth.Buffer } = {
	click = renderClick,
	coin = renderCoin,
	hatch = renderHatch,
	rare = renderRare,
	raid = renderRaid,
	error = renderError,
}

--- Renders one cue to a Synth buffer, dispatching on kind/type/mood.
function Audiocues.render(cue: Cue): Synth.Buffer
	if cue.kind == "music" then
		return Music.render({
			seed = cue.seed,
			duration = cue.duration,
			sampleRate = cue.sampleRate,
			mood = cue.mood,
		})
	end
	local rng = Synth.rng(cue.seed)
	if cue.kind == "ambience" then
		if cue.type == "birds" then
			return renderBirds(cue, rng)
		end
		return renderWind(cue, rng)
	end
	local renderer = SFX_RENDERERS[cue.type or ""]
	if renderer ~= nil then
		return renderer(cue, rng)
	end
	return Synth.buffer(cue.duration, cue.sampleRate)
end

return Audiocues
