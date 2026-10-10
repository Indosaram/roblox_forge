--!strict
-- Specs for Synth: deterministic PRNG, oscillator shapes, ADSR, filters,
-- delay/reverb, and buffer mixing. Synth is pure Luau, so these run under Lune.

local Synth = require("./Synth")

local function nearly(a: number, b: number, epsilon: number?): boolean
	return math.abs(a - b) < (epsilon or 1e-9)
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

local function sineBuffer(freq: number, duration: number, sampleRate: number): Synth.Buffer
	local buffer = Synth.buffer(duration, sampleRate)
	Synth.addVoice(buffer, {
		start = 0,
		duration = duration,
		freq = freq,
		shape = "sine",
		amp = 1,
		env = { attack = 0.001, decay = 0, sustain = 1, release = 0 },
	})
	return buffer
end

return {
	["rng is deterministic and stays in range"] = function()
		local a = Synth.rng(1234)
		local b = Synth.rng(1234)
		for _ = 1, 100 do
			local value = a.next()
			assert(value == b.next(), "same seed produces the same stream")
			assert(value >= 0 and value < 1, "next() is in [0, 1)")
		end
	end,

	["rng int and range are bounded"] = function()
		local rng = Synth.rng(99)
		for _ = 1, 200 do
			local i = rng.int(2, 5)
			assert(i >= 2 and i <= 5 and i % 1 == 0, "int stays integral and in range")
			local r = rng.range(-3, 3)
			assert(r >= -3 and r <= 3, "range stays in range")
			local s = rng.sign()
			assert(s == 1 or s == -1, "sign is +/-1")
		end
	end,

	["different seeds desync the stream"] = function()
		local a = Synth.rng(1)
		local b = Synth.rng(2)
		local differs = false
		for _ = 1, 10 do
			if a.next() ~= b.next() then
				differs = true
				break
			end
		end
		assert(differs, "different seeds must produce different values")
	end,

	["oscillator shapes are bounded and correct at anchors"] = function()
		assert(nearly(Synth.osc("sine", 0), 0), "sine(0) is 0")
		assert(nearly(Synth.osc("sine", 0.25), 1), "sine(1/4) is 1")
		assert(nearly(Synth.osc("sine", 0.75), -1), "sine(3/4) is -1")
		assert(Synth.osc("square", 0.2) == 1 and Synth.osc("square", 0.7) == -1, "square is bipolar")
		assert(nearly(Synth.osc("saw", 0), -1) and nearly(Synth.osc("saw", 0.5), 0), "saw ramps")
		assert(nearly(Synth.osc("triangle", 0.5), 1), "triangle peaks at 1/2")
		for _, shape in { "sine", "square", "saw", "triangle" } do
			for step = 0, 99 do
				local value = Synth.osc(shape, step / 100)
				assert(math.abs(value) <= 1.0000001, shape .. " stays within [-1, 1]")
			end
		end
	end,

	["adsr rises, sustains, and releases to zero"] = function()
		local env = { attack = 0.1, decay = 0.1, sustain = 0.5, release = 0.2 }
		assert(nearly(Synth.adsrAt(0.05, 1, env), 0.5), "mid-attack is half")
		assert(nearly(Synth.adsrAt(0.1, 1, env), 1), "attack peak is 1")
		assert(nearly(Synth.adsrAt(0.2, 1, env), 0.5), "decay reaches sustain")
		assert(nearly(Synth.adsrAt(0.5, 1, env), 0.5), "sustain holds")
		assert(nearly(Synth.adsrAt(0.9, 1, env), 0.25), "mid-release is half sustain")
		assert(nearly(Synth.adsrAt(1.2, 1, env), 0), "past the end is silent")
	end,

	["addVoice is deterministic and bounded"] = function()
		local function render(): Synth.Buffer
			local buffer = Synth.buffer(0.5, 22050)
			Synth.addVoice(buffer, {
				start = 0.1,
				duration = 0.3,
				freq = 440,
				shape = "saw",
				amp = 0.8,
				env = { attack = 0.02, decay = 0.05, sustain = 0.6, release = 0.1 },
			})
			return buffer
		end
		local a = render()
		local b = render()
		assert(sameSamples(a, b), "the same voice renders identically")
		assert(Synth.peak(a) > 0.1 and Synth.peak(a) <= 0.8, "voice amplitude is respected and bounded")
		assert(nearly(a.samples[1], 0), "a voice starting later leaves the head silent")
	end,

	["noise voice uses its rng deterministically"] = function()
		local function render(): Synth.Buffer
			local buffer = Synth.buffer(0.1, 22050)
			Synth.addVoice(buffer, {
				start = 0,
				duration = 0.1,
				freq = 1,
				shape = "noise",
				amp = 1,
				env = { attack = 0, decay = 0, sustain = 1, release = 0 },
				rng = Synth.rng(7),
			})
			return buffer
		end
		assert(sameSamples(render(), render()), "noise is deterministic for a seed")
		local buffer = render()
		assert(Synth.peak(buffer) > 0.5 and Synth.peak(buffer) <= 1.0000001, "noise fills [-1, 1]")
	end,

	["lowpass attenuates a high tone more than a low tone"] = function()
		local function energyAfter(cutoff: number): number
			local buffer = sineBuffer(4000, 0.25, 22050)
			Synth.lowpass(buffer, cutoff)
			local sum = 0
			for i = 100, #buffer.samples do
				sum += math.abs(buffer.samples[i])
			end
			return sum
		end
		assert(energyAfter(200) < energyAfter(8000), "a low cutoff removes more high-frequency energy")
	end,

	["highpass attenuates a low tone"] = function()
		local buffer = sineBuffer(80, 0.25, 22050)
		local before = Synth.peak(buffer)
		Synth.highpass(buffer, 1500)
		local after = 0
		for i = 100, #buffer.samples do
			after = math.max(after, math.abs(buffer.samples[i]))
		end
		assert(after < before * 0.5, "a high cutoff removes low-frequency energy")
	end,

	["delay adds a later echo"] = function()
		local buffer = Synth.buffer(1, 22050)
		buffer.samples[1] = 1
		Synth.delay(buffer, { time = 0.25, feedback = 0, mix = 1 })
		local echoIndex = math.floor(0.25 * 22050) + 1
		assert(buffer.samples[echoIndex] > 0.5, "the echo appears one delay later")
		assert(nearly(buffer.samples[echoIndex - 10], 0), "nothing echoes before its time")
	end,

	["reverb adds tail but stays bounded"] = function()
		local buffer = sineBuffer(440, 0.5, 22050)
		Synth.reverb(buffer, { room = 0.7, mix = 0.4 })
		local peak = Synth.peak(buffer)
		assert(peak > 0.5, "reverb keeps the signal")
		assert(peak <= 3, "reverb does not explode")
	end,

	["add, scale, and normalize mix buffers"] = function()
		local a = Synth.buffer(0.01, 1000)
		local b = Synth.buffer(0.01, 1000)
		for i = 1, #a.samples do
			a.samples[i] = 0.5
			b.samples[i] = 0.25
		end
		Synth.add(a, b, 2)
		assert(nearly(a.samples[1], 1), "add applies gain")
		Synth.scale(a, 0.5)
		assert(nearly(a.samples[1], 0.5), "scale multiplies")
		Synth.normalize(a, 0.8)
		assert(nearly(Synth.peak(a), 0.8), "normalize hits the requested peak")
	end,
}
