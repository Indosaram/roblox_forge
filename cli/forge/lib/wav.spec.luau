--!strict
-- Specs for the WAV encoder: header layout, PCM clamping, sample count, and
-- byte determinism. Pure Lune buffers, no filesystem.

local wav = require("./wav")

local function ascii(data: buffer, offset: number, length: number): string
	local chars: { string } = {}
	for i = 0, length - 1 do
		table.insert(chars, string.char(buffer.readu8(data, offset + i)))
	end
	return table.concat(chars)
end

local function mono(samples: { number }, sampleRate: number): wav.MonoBuffer
	return { samples = samples, sampleRate = sampleRate }
end

return {
	["encodes a valid RIFF/WAVE header"] = function()
		local data = wav.encode(mono({ 0, 0, 0 }, 22050))
		assert(buffer.len(data) == wav.HEADER_BYTES + 6, "header plus two bytes per sample")
		assert(ascii(data, 0, 4) == "RIFF", "starts with RIFF")
		assert(ascii(data, 8, 4) == "WAVE", "WAVE marker")
		assert(ascii(data, 12, 4) == "fmt ", "fmt chunk")
		assert(buffer.readu32(data, 16) == 16, "fmt chunk is 16 bytes")
		assert(buffer.readu16(data, 20) == 1, "PCM format")
		assert(buffer.readu16(data, 22) == 1, "mono")
		assert(buffer.readu32(data, 24) == 22050, "sample rate")
		assert(buffer.readu32(data, 28) == 22050 * 2, "byte rate")
		assert(buffer.readu16(data, 32) == 2, "block align")
		assert(buffer.readu16(data, 34) == 16, "16-bit samples")
		assert(ascii(data, 36, 4) == "data", "data chunk")
		assert(buffer.readu32(data, 40) == 6, "data size")
		assert(buffer.readu32(data, 4) == 36 + 6, "RIFF size covers the data")
	end,

	["clamps and rounds samples to signed 16-bit"] = function()
		assert(wav.toPcm(0) == 0, "zero stays zero")
		assert(wav.toPcm(2) == 32767, "above full scale clamps high")
		assert(wav.toPcm(-2) == -32768, "below full scale clamps low")
		assert(wav.toPcm(0.5) == 16384, "positive half scale")
		assert(wav.toPcm(-0.5) == -16384, "negative half scale")
	end,

	["writes little-endian sample bytes"] = function()
		local data = wav.encode(mono({ 1, -1 }, 44100))
		assert(buffer.readi16(data, wav.HEADER_BYTES) == 32767, "first sample reads back")
		assert(buffer.readi16(data, wav.HEADER_BYTES + 2) == -32768, "second sample reads back")
	end,

	["encoding is deterministic"] = function()
		local samples: { number } = {}
		for i = 1, 100 do
			samples[i] = math.sin(i * 0.1) * 0.7
		end
		local a = wav.encode(mono(samples, 44100))
		local b = wav.encode(mono(samples, 44100))
		assert(buffer.len(a) == buffer.len(b), "same length")
		for i = 0, buffer.len(a) - 1 do
			assert(buffer.readu8(a, i) == buffer.readu8(b, i), "byte " .. i .. " matches")
		end
	end,
}
