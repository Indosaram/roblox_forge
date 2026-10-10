--!strict
-- Synth: pure, engine-free DSP primitives for the framework's keyless
-- procedural audio. Oscillators (sine/square/saw/triangle/noise), an ADSR
-- envelope, one-pole low/high pass filters, delay and a Schroeder-style
-- reverb-lite, buffer mixing/normalisation, and a deterministic xorshift PRNG.
--
-- It uses no Roblox APIs, no Lune APIs, and no math.random, so every render is
-- reproducible byte-for-byte: `forge gen audio` writes identical WAVs on every
-- run. Buffers are plain `{ samples = { number }, sampleRate = number }` tables
-- in the range [-1, 1]; effects mutate their buffer and return it for chaining.

local TAU = math.pi * 2
local TWO32 = 4294967296

local Synth = {}

export type Buffer = { samples: { number }, sampleRate: number }

export type Rng = {
	next: () -> number,
	range: (number, number) -> number,
	int: (number, number) -> number,
	sign: () -> number,
}

export type Env = {
	attack: number,
	decay: number,
	sustain: number,
	release: number,
}

export type Voice = {
	start: number,
	duration: number,
	freq: number,
	freqEnd: number?,
	shape: string?,
	amp: number?,
	env: Env?,
	phase: number?,
	detune: number?,
	fmRatio: number?,
	fmIndex: number?,
	rng: Rng?,
}

export type DelayOptions = { time: number?, feedback: number?, mix: number? }
export type ReverbOptions = { room: number?, damp: number?, mix: number? }
export type Cutoff = number | ((t: number) -> number)

local DEFAULT_ENV: Env = { attack = 0.01, decay = 0.1, sustain = 0.7, release = 0.2 }

local COMB_TIMES = { 0.0297, 0.0371, 0.0411, 0.0437 }
local ALLPASS_TIMES = { 0.005, 0.0017 }

type Comb = { line: { number }, index: number, size: number, store: number }

--- Deterministic xorshift32 generator. The seed is folded into a nonzero state
--- with a fixed constant and warmed up, so nearby seeds never produce correlated
--- streams.
function Synth.rng(seed: number): Rng
	local state = bit32.bxor(math.floor(seed) % TWO32, 0x9E3779B9)
	if state == 0 then
		state = 0x1F123BB5
	end
	local function next(): number
		local x = state
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		state = x
		return x / TWO32
	end
	for _ = 1, 4 do
		next()
	end
	return {
		next = next,
		range = function(lo: number, hi: number): number
			return lo + (hi - lo) * next()
		end,
		int = function(lo: number, hi: number): number
			local value = lo + math.floor(next() * (hi - lo + 1))
			return math.min(value, hi)
		end,
		sign = function(): number
			return if next() < 0.5 then -1 else 1
		end,
	}
end

--- An all-zero mono buffer of `duration` seconds at `sampleRate`.
function Synth.buffer(duration: number, sampleRate: number): Buffer
	local count = math.max(1, math.floor(duration * sampleRate + 0.5))
	return { samples = table.create(count, 0), sampleRate = sampleRate }
end

--- Wraps an existing sample array without copying.
function Synth.wrap(samples: { number }, sampleRate: number): Buffer
	return { samples = samples, sampleRate = sampleRate }
end

function Synth.copy(buffer: Buffer): Buffer
	return { samples = table.clone(buffer.samples), sampleRate = buffer.sampleRate }
end

function Synth.duration(buffer: Buffer): number
	return #buffer.samples / buffer.sampleRate
end

function Synth.peak(buffer: Buffer): number
	local maxValue = 0
	for _, value in buffer.samples do
		local magnitude = math.abs(value)
		if magnitude > maxValue then
			maxValue = magnitude
		end
	end
	return maxValue
end

--- One oscillator sample for a phase in [0, 1). Noise is handled by the
--- renderer (it needs an RNG), so it returns 0 here.
function Synth.osc(shape: string, phase: number): number
	if shape == "sine" then
		return math.sin(phase * TAU)
	elseif shape == "square" then
		return if phase < 0.5 then 1 else -1
	elseif shape == "saw" then
		return 2 * phase - 1
	elseif shape == "triangle" then
		return 1 - 4 * math.abs(phase - 0.5)
	end
	return 0
end

--- ADSR gain at time `t` into a note of `duration` seconds. The release always
--- ends exactly at `duration`, so a voice never rings past its own length.
function Synth.adsrAt(t: number, duration: number, env: Env): number
	if t < 0 or t >= duration then
		return 0
	end
	local attack = math.max(env.attack, 0)
	local decay = math.max(env.decay, 0)
	local sustain = math.clamp(env.sustain, 0, 1)
	local release = math.max(env.release, 0)
	local peakEnd = attack + decay
	local releaseStart = math.max(peakEnd, duration - release)

	if attack > 0 and t < attack then
		return t / attack
	end
	if decay > 0 and t < peakEnd then
		return 1 - (1 - sustain) * ((t - attack) / decay)
	end
	if t < releaseStart then
		return sustain
	end
	local held = if decay > 0 and releaseStart < peakEnd
		then math.max(0, 1 - (1 - sustain) * ((releaseStart - attack) / decay))
		else sustain
	if release <= 0 then
		return held
	end
	return held * math.max(0, 1 - (t - releaseStart) / release)
end

--- Adds one oscillator voice into `buffer`: linear pitch glide from `freq` to
--- `freqEnd`, optional FM (brightness for bells/chirps), optional detune beat,
--- and a per-voice noise stream when `shape` is "noise".
function Synth.addVoice(buffer: Buffer, voice: Voice): ()
	local samples = buffer.samples
	local count = #samples
	local sr = buffer.sampleRate
	local length = math.floor(voice.duration * sr)
	if length <= 0 then
		return
	end
	local startIndex = math.floor(voice.start * sr)
	local shape = voice.shape or "sine"
	local amp = voice.amp or 1
	local env = voice.env or DEFAULT_ENV
	local rng = voice.rng
	local freq0 = voice.freq
	local freq1 = voice.freqEnd or freq0
	local invSr = 1 / sr
	local invLast = if length > 1 then 1 / (length - 1) else 0
	local duration = length * invSr
	local detune = voice.detune or 0
	local fmRatio = voice.fmRatio
	local fmIndex = voice.fmIndex or 0
	local phase = voice.phase or 0
	local phaseB = phase
	local isNoise = shape == "noise"

	for i = 0, length - 1 do
		local index = startIndex + i + 1
		if index > count then
			break
		end
		if index >= 1 then
			local t = i * invSr
			local gain = Synth.adsrAt(t, duration, env) * amp
			local value: number
			if isNoise then
				value = if rng ~= nil then rng.next() * 2 - 1 else 0
			else
				local freq = freq0 + (freq1 - freq0) * i * invLast
				local increment = freq * invSr
				if fmIndex ~= 0 and fmRatio ~= nil then
					increment = increment * (1 + fmIndex * math.sin(TAU * fmRatio * freq * t))
				end
				value = Synth.osc(shape, phase)
				if detune ~= 0 then
					value = (value + Synth.osc(shape, phaseB)) * 0.5
					phaseB += increment * (1 + detune)
					phaseB -= math.floor(phaseB)
				end
				phase += increment
				phase -= math.floor(phase)
			end
			samples[index] += value * gain
		end
	end
end

local function cutoffAt(cutoff: Cutoff, t: number): number
	if type(cutoff) == "function" then
		return (cutoff :: (number) -> number)(t)
	end
	return cutoff :: number
end

--- One-pole low pass. `cutoff` may be a number or a function of time (for
--- sweeps); it is clamped below Nyquist so the filter always stays stable.
function Synth.lowpass(buffer: Buffer, cutoff: Cutoff): Buffer
	local samples = buffer.samples
	local sr = buffer.sampleRate
	local invSr = 1 / sr
	local fixed: number? = if type(cutoff) == "number" then cutoff :: number else nil
	local alpha = if fixed ~= nil then 1 - math.exp(-TAU * math.clamp(fixed, 1, sr * 0.45) * invSr) else 0
	local y = 0
	for i = 1, #samples do
		if fixed == nil then
			local fc = math.clamp(cutoffAt(cutoff, (i - 1) * invSr), 1, sr * 0.45)
			alpha = 1 - math.exp(-TAU * fc * invSr)
		end
		y += alpha * (samples[i] - y)
		samples[i] = y
	end
	return buffer
end

--- One-pole high pass (input minus its low-passed part).
function Synth.highpass(buffer: Buffer, cutoff: Cutoff): Buffer
	local samples = buffer.samples
	local sr = buffer.sampleRate
	local invSr = 1 / sr
	local fixed: number? = if type(cutoff) == "number" then cutoff :: number else nil
	local alpha = if fixed ~= nil then 1 - math.exp(-TAU * math.clamp(fixed, 1, sr * 0.45) * invSr) else 0
	local low = 0
	for i = 1, #samples do
		local x = samples[i]
		if fixed == nil then
			local fc = math.clamp(cutoffAt(cutoff, (i - 1) * invSr), 1, sr * 0.45)
			alpha = 1 - math.exp(-TAU * fc * invSr)
		end
		low += alpha * (x - low)
		samples[i] = x - low
	end
	return buffer
end

--- Single-tap feedback delay, mixed under the dry signal.
function Synth.delay(buffer: Buffer, opts: DelayOptions?): Buffer
	local options: DelayOptions = opts or {}
	local time = options.time or 0.3
	local feedback = math.clamp(options.feedback or 0.35, 0, 0.95)
	local mix = options.mix or 0.3
	local size = math.max(1, math.floor(time * buffer.sampleRate))
	local line = table.create(size, 0)
	local index = 1
	local samples = buffer.samples
	for i = 1, #samples do
		local dry = samples[i]
		local echo = line[index]
		line[index] = dry + echo * feedback
		index += 1
		if index > size then
			index = 1
		end
		samples[i] = dry + echo * mix
	end
	return buffer
end

--- Schroeder-style reverb-lite: four damped comb filters in parallel into two
--- allpass filters, blended under the dry signal. Cheap and fully deterministic
--- (fixed delay times, no randomness).
function Synth.reverb(buffer: Buffer, opts: ReverbOptions?): Buffer
	local options: ReverbOptions = opts or {}
	local room = math.clamp(options.room or 0.75, 0, 0.98)
	local damp = math.clamp(options.damp or 0.35, 0, 1)
	local mix = options.mix or 0.25
	local sr = buffer.sampleRate
	local n = #buffer.samples
	local wet = table.create(n, 0)

	local combs: { Comb } = {}
	for _, time in COMB_TIMES do
		local size = math.max(1, math.floor(time * sr))
		table.insert(combs, { line = table.create(size, 0), index = 1, size = size, store = 0 })
	end

	for i = 1, n do
		local input = buffer.samples[i]
		local sum = 0
		for _, comb in combs do
			local out = comb.line[comb.index]
			comb.store = out * (1 - damp) + comb.store * damp
			comb.line[comb.index] = input + comb.store * room
			comb.index += 1
			if comb.index > comb.size then
				comb.index = 1
			end
			sum += out
		end
		wet[i] = sum / #combs
	end

	for _, time in ALLPASS_TIMES do
		local size = math.max(1, math.floor(time * sr))
		local line = table.create(size, 0)
		local index = 1
		local gain = 0.5
		for i = 1, n do
			local delayed = line[index]
			local output = -wet[i] + delayed
			line[index] = wet[i] + delayed * gain
			index += 1
			if index > size then
				index = 1
			end
			wet[i] = output
		end
	end

	for i = 1, n do
		buffer.samples[i] += wet[i] * mix
	end
	return buffer
end

--- Adds `source` into `target` at `gain`, up to the shorter of the two.
function Synth.add(target: Buffer, source: Buffer, gain: number?): Buffer
	local g = gain or 1
	local n = math.min(#target.samples, #source.samples)
	for i = 1, n do
		target.samples[i] += source.samples[i] * g
	end
	return target
end

function Synth.scale(buffer: Buffer, gain: number): Buffer
	for i = 1, #buffer.samples do
		buffer.samples[i] *= gain
	end
	return buffer
end

--- Scales the buffer so its loudest sample sits at `peak` (default 0.9).
function Synth.normalize(buffer: Buffer, peak: number?): Buffer
	local target = peak or 0.9
	local maxValue = Synth.peak(buffer)
	if maxValue > 1e-8 then
		Synth.scale(buffer, target / maxValue)
	end
	return buffer
end

--- Gentle saturation for peaks that survive normalisation; keeps output below 1.
function Synth.softclip(buffer: Buffer): Buffer
	for i = 1, #buffer.samples do
		local x = buffer.samples[i]
		buffer.samples[i] = x / (1 + math.abs(x))
	end
	return buffer
end

return Synth
