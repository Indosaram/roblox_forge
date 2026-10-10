--!strict
-- wav: minimal deterministic 16-bit PCM mono WAV encoder. Takes a buffer of
-- samples in [-1, 1] and returns the RIFF/WAVE bytes. Pure Lua/Luau buffers, no
-- compression, no metadata chunks, so the same samples always encode to the
-- same bytes.

local M = {}

export type MonoBuffer = { samples: { number }, sampleRate: number }

M.HEADER_BYTES = 44
local HEADER_BYTES = M.HEADER_BYTES

--- Rounds a float sample to a signed 16-bit integer, clamping to full scale.
function M.toPcm(value: number): number
	if value >= 1 then
		return 32767
	end
	if value <= -1 then
		return -32768
	end
	if value < 0 then
		return math.floor(value * 32768 + 0.5)
	end
	return math.floor(value * 32767 + 0.5)
end

local function writeAscii(out: buffer, offset: number, text: string): ()
	for i = 1, #text do
		buffer.writeu8(out, offset + i - 1, string.byte(text, i))
	end
end

--- Encodes a mono buffer as a 44-byte-header 16-bit PCM WAV.
function M.encode(source: MonoBuffer): buffer
	local samples = source.samples
	local count = #samples
	local dataBytes = count * 2
	local out = buffer.create(HEADER_BYTES + dataBytes)

	writeAscii(out, 0, "RIFF")
	buffer.writeu32(out, 4, 36 + dataBytes)
	writeAscii(out, 8, "WAVE")

	writeAscii(out, 12, "fmt ")
	buffer.writeu32(out, 16, 16)
	buffer.writeu16(out, 20, 1)
	buffer.writeu16(out, 22, 1)
	buffer.writeu32(out, 24, source.sampleRate)
	buffer.writeu32(out, 28, source.sampleRate * 2)
	buffer.writeu16(out, 32, 2)
	buffer.writeu16(out, 34, 16)

	writeAscii(out, 36, "data")
	buffer.writeu32(out, 40, dataBytes)

	local offset = HEADER_BYTES
	for i = 1, count do
		buffer.writei16(out, offset, M.toPcm(samples[i]))
		offset += 2
	end
	return out
end

return M
