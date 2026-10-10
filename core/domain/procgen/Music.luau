--!strict
-- Music: deterministic procedural composition for the framework's two game
-- moods. Given a seed, a target duration, and a mood it builds a chord
-- progression, a melody drawn from the mood's scale, bass and drum parts, and
-- an intro-then-loop arrangement, then synthesises them with Synth.
--
-- Everything comes from the Synth PRNG seeded by the caller, so the same spec
-- always renders the same samples. There are no Roblox or Lune APIs here.

local Synth = require("./Synth")

local Music = {}

export type Mood = "explore" | "siege"

export type Spec = {
	seed: number,
	duration: number,
	sampleRate: number?,
	mood: string?,
}

export type Plan = {
	mood: Mood,
	bpm: number,
	bars: number,
	barSeconds: number,
	seconds: number,
	sampleRate: number,
	progression: { number },
}

type MoodConfig = {
	bpm: number,
	scale: { number },
	pentatonic: { number },
	root: number,
	padShape: string,
	leadShape: string,
	bassShape: string,
	padAttack: number,
	padRelease: number,
	padAmp: number,
	leadAmp: number,
	bassAmp: number,
	introBars: number,
	melodySlots: number,
	restChance: number,
	progression: { number },
	delay: Synth.DelayOptions?,
	reverb: Synth.ReverbOptions,
}

-- explore: calm A-major at 84 BPM (I-vi-IV-V); siege: tense A-minor at 140 BPM
-- (i-VI-III-VII) with a driving kick and a denser, syncopated lead.
local MOODS: { [string]: MoodConfig } = {
	explore = {
		bpm = 84,
		scale = { 0, 2, 4, 5, 7, 9, 11 },
		pentatonic = { 0, 2, 4, 7, 9 },
		root = 57,
		padShape = "triangle",
		leadShape = "triangle",
		bassShape = "sine",
		padAttack = 0.5,
		padRelease = 0.6,
		padAmp = 0.22,
		leadAmp = 0.3,
		bassAmp = 0.35,
		introBars = 4,
		melodySlots = 8,
		restChance = 0.4,
		progression = { 1, 6, 4, 5 },
		delay = { time = 0.36, feedback = 0.3, mix = 0.16 },
		reverb = { room = 0.72, damp = 0.4, mix = 0.28 },
	},
	siege = {
		bpm = 140,
		scale = { 0, 2, 3, 5, 7, 8, 10 },
		pentatonic = { 0, 3, 5, 7, 10 },
		root = 45,
		padShape = "saw",
		leadShape = "saw",
		bassShape = "square",
		padAttack = 0.02,
		padRelease = 0.15,
		padAmp = 0.16,
		leadAmp = 0.24,
		bassAmp = 0.38,
		introBars = 4,
		melodySlots = 16,
		restChance = 0.28,
		progression = { 1, 6, 3, 7 },
		delay = { time = 0.21, feedback = 0.34, mix = 0.2 },
		reverb = { room = 0.6, damp = 0.5, mix = 0.18 },
	},
}

local function moodOf(name: string?): Mood
	if name == "siege" then
		return "siege"
	end
	return "explore"
end

local function midiToFreq(note: number): number
	return 440 * 2 ^ ((note - 69) / 12)
end

--- Maps a 1-indexed scale degree (which may exceed the scale length) to a MIDI
--- note, wrapping into higher octaves.
local function degreeToMidi(scale: { number }, root: number, degree: number): number
	local index = (degree - 1) % #scale
	local octave = math.floor((degree - 1) / #scale)
	return root + scale[index + 1] + octave * 12
end

--- The deterministic arrangement metadata: mood, tempo, quantised bar count,
--- total seconds, and the chord progression (scale degrees).
function Music.plan(spec: Spec): Plan
	local mood: Mood = moodOf(spec.mood)
	local config = MOODS[mood] :: MoodConfig
	local sampleRate = spec.sampleRate or 22050
	local barSeconds = 4 * 60 / config.bpm
	local bars = math.max(config.introBars + 4, math.floor(spec.duration / barSeconds + 0.5))
	return {
		mood = mood,
		bpm = config.bpm,
		bars = bars,
		barSeconds = barSeconds,
		seconds = bars * barSeconds,
		sampleRate = sampleRate,
		progression = table.clone(config.progression),
	}
end

local function fadeEdges(buffer: Synth.Buffer): ()
	local samples = buffer.samples
	local count = #samples
	local fade = math.min(math.floor(0.003 * buffer.sampleRate), math.floor(count / 2))
	if fade <= 1 then
		return
	end
	for i = 1, fade do
		samples[i] *= (i - 1) / fade
	end
	for i = 0, fade - 1 do
		samples[count - i] *= i / fade
	end
end

local function addDrums(buffer: Synth.Buffer, plan: Plan, barStart: number, intro: boolean, rng: Synth.Rng): ()
	local beat = plan.barSeconds / 4
	local kickEnv: Synth.Env = { attack = 0.001, decay = 0.16, sustain = 0, release = 0.02 }
	local snareEnv: Synth.Env = { attack = 0.001, decay = 0.12, sustain = 0, release = 0.02 }
	local hatEnv: Synth.Env = { attack = 0.001, decay = 0.04, sustain = 0, release = 0.01 }

	if plan.mood == "siege" then
		for b = 0, 3 do
			Synth.addVoice(buffer, {
				start = barStart + b * beat,
				duration = 0.18,
				freq = 140,
				freqEnd = 45,
				shape = "sine",
				amp = 0.9,
				env = kickEnv,
			})
		end
		for _, b in { 1, 3 } do
			Synth.addVoice(buffer, {
				start = barStart + b * beat,
				duration = 0.16,
				freq = 1,
				shape = "noise",
				amp = 0.5,
				env = snareEnv,
				rng = rng,
			})
			Synth.addVoice(buffer, {
				start = barStart + b * beat,
				duration = 0.12,
				freq = 190,
				shape = "triangle",
				amp = 0.22,
				env = snareEnv,
			})
		end
		for s = 0, 7 do
			Synth.addVoice(buffer, {
				start = barStart + s * beat / 2,
				duration = 0.05,
				freq = 1,
				shape = "noise",
				amp = 0.16,
				env = hatEnv,
				rng = rng,
			})
		end
	elseif not intro then
		for _, b in { 0, 2 } do
			Synth.addVoice(buffer, {
				start = barStart + b * beat,
				duration = 0.16,
				freq = 110,
				freqEnd = 50,
				shape = "sine",
				amp = 0.45,
				env = kickEnv,
			})
		end
		for s = 0, 7 do
			Synth.addVoice(buffer, {
				start = barStart + s * beat / 2,
				duration = 0.04,
				freq = 1,
				shape = "noise",
				amp = 0.06,
				env = hatEnv,
				rng = rng,
			})
		end
	end
end

--- Renders a mood track from `spec`. The result is `plan.seconds` long (bar
--- quantised), normalised to 0.85, with faded edges so the file loops cleanly.
function Music.render(spec: Spec): Synth.Buffer
	local plan = Music.plan(spec)
	local config = MOODS[plan.mood] :: MoodConfig
	local seed = math.floor(spec.seed)
	local buffer = Synth.buffer(plan.seconds, plan.sampleRate)
	local compRng = Synth.rng(seed)
	local drumRng = Synth.rng(seed + 0x51ED)
	local scale = config.scale
	local penta = config.pentatonic

	for bar = 0, plan.bars - 1 do
		local barStart = bar * plan.barSeconds
		local chordRoot = config.progression[(bar % #config.progression) + 1]
		local intro = bar < config.introBars

		for _, step in { 0, 2, 4 } do
			local note = degreeToMidi(scale, config.root + 12, chordRoot + step)
			Synth.addVoice(buffer, {
				start = barStart,
				duration = plan.barSeconds * 0.98,
				freq = midiToFreq(note),
				shape = config.padShape,
				amp = config.padAmp * (if intro then 0.7 else 1),
				detune = if plan.mood == "siege" then 0.008 else 0,
				env = {
					attack = config.padAttack,
					decay = 0.2,
					sustain = 0.8,
					release = config.padRelease,
				},
			})
		end

		local bassNote = degreeToMidi(scale, config.root, chordRoot) - 12
		if plan.mood == "siege" then
			for beat = 0, 3 do
				Synth.addVoice(buffer, {
					start = barStart + beat * plan.barSeconds / 4,
					duration = plan.barSeconds / 4 * 0.9,
					freq = midiToFreq(bassNote),
					shape = config.bassShape,
					amp = config.bassAmp,
					env = { attack = 0.005, decay = 0.08, sustain = 0.7, release = 0.05 },
				})
			end
		else
			for half = 0, 1 do
				Synth.addVoice(buffer, {
					start = barStart + half * plan.barSeconds / 2,
					duration = plan.barSeconds / 2 * 0.95,
					freq = midiToFreq(bassNote),
					shape = config.bassShape,
					amp = config.bassAmp * (if intro then 0.6 else 1),
					env = { attack = 0.05, decay = 0.2, sustain = 0.75, release = 0.15 },
				})
			end
		end

		if not intro or bar == config.introBars - 1 then
			local slotLength = plan.barSeconds / config.melodySlots
			local index = 1 + math.floor(compRng.next() * #penta)
			for slot = 0, config.melodySlots - 1 do
				if compRng.next() >= config.restChance then
					index = math.clamp(index + compRng.int(-2, 2), 1, #penta)
					local octave = 0
					local octaveRoll = compRng.next()
					if octaveRoll < 0.18 then
						octave = 12
					elseif octaveRoll > 0.9 then
						octave = -12
					end
					local note = config.root + 12 + penta[index] + octave
					local hold = slotLength * (if plan.mood == "siege" then 0.85 else 1.8)
					Synth.addVoice(buffer, {
						start = barStart + slot * slotLength,
						duration = hold,
						freq = midiToFreq(note),
						shape = config.leadShape,
						amp = config.leadAmp,
						detune = if plan.mood == "siege" then 0.006 else 0,
						env = { attack = 0.01, decay = hold * 0.6, sustain = 0.15, release = 0.06 },
					})
				end
			end
		end

		addDrums(buffer, plan, barStart, intro, drumRng)
	end

	if config.delay ~= nil then
		Synth.delay(buffer, config.delay)
	end
	Synth.reverb(buffer, config.reverb)
	fadeEdges(buffer)
	Synth.normalize(buffer, 0.85)
	return buffer
end

return Music
