--!strict
-- png: minimal deterministic PNG (8-bit RGBA, filter 0) encoder for a
-- core/domain/procgen/Pixels canvas. The deflate stream uses "stored"
-- (uncompressed) blocks, so the bytes never depend on a compressor build:
-- zlib header + stored blocks + Adler32, wrapped in CRC32-checked PNG chunks.
-- Pure Luau, no image library, no network, no math.random.

local M = {}

local SIGNATURE = { 137, 80, 78, 71, 13, 10, 26, 10 }
local IEND_CRC = 0xAE426082
local STORED_MAX = 65535

local CRC_TABLE: { number } = table.create(256, 0)
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		if bit32.band(c, 1) == 1 then
			c = bit32.bxor(0xEDB88320, bit32.rshift(c, 1))
		else
			c = bit32.rshift(c, 1)
		end
	end
	CRC_TABLE[n] = c
end

local function crc32(data: buffer, offset: number, length: number): number
	local crc = 0xFFFFFFFF
	for i = offset, offset + length - 1 do
		local index = bit32.band(bit32.bxor(crc, buffer.readu8(data, i)), 0xFF)
		crc = bit32.bxor(CRC_TABLE[index], bit32.rshift(crc, 8))
	end
	return bit32.bxor(crc, 0xFFFFFFFF)
end

local function adler32(data: buffer, offset: number, length: number): number
	local a = 1
	local b = 0
	for i = offset, offset + length - 1 do
		a = (a + buffer.readu8(data, i)) % 65521
		b = (b + a) % 65521
	end
	return b * 65536 + a
end

local function writeU8(buf: buffer, offset: number, value: number): ()
	buffer.writeu8(buf, offset, value % 256)
end

local function writeU16LE(buf: buffer, offset: number, value: number): ()
	buffer.writeu8(buf, offset, value % 256)
	buffer.writeu8(buf, offset + 1, math.floor(value / 256) % 256)
end

local function writeU32BE(buf: buffer, offset: number, value: number): ()
	buffer.writeu8(buf, offset, math.floor(value / 16777216) % 256)
	buffer.writeu8(buf, offset + 1, math.floor(value / 65536) % 256)
	buffer.writeu8(buf, offset + 2, math.floor(value / 256) % 256)
	buffer.writeu8(buf, offset + 3, value % 256)
end

local function writeAscii(buf: buffer, offset: number, text: string): ()
	for i = 1, #text do
		buffer.writeu8(buf, offset + i - 1, string.byte(text, i))
	end
end

local function toByte(value: number): number
	return math.clamp(math.floor(value * 255 + 0.5), 0, 255)
end

--- Encodes an RGBA Pixels canvas as PNG bytes. Rows are stored top-to-bottom
--- with filter type 0 and no interlace; the zlib stream is a single CMF/FLG
--- header followed by uncompressed deflate blocks.
function M.encode(canvas: any): buffer
	local width = canvas.width
	local height = canvas.height
	local stride = 1 + width * 4
	local rawLen = height * stride

	local raw = buffer.create(rawLen)
	local data = canvas.data
	for y = 0, height - 1 do
		local rowOffset = y * stride
		buffer.writeu8(raw, rowOffset, 0)
		local sourceBase = y * width * 4
		for i = 0, width * 4 - 1 do
			buffer.writeu8(raw, rowOffset + 1 + i, toByte(data[sourceBase + i + 1]))
		end
	end

	local blocks = math.max(1, math.ceil(rawLen / STORED_MAX))
	local idatLen = 2 + rawLen + blocks * 5 + 4
	local total = 8 + 25 + (12 + idatLen) + 12
	local buf = buffer.create(total)

	for i = 1, #SIGNATURE do
		buffer.writeu8(buf, i - 1, SIGNATURE[i])
	end

	-- IHDR
	local offset = 8
	writeU32BE(buf, offset, 13)
	offset += 4
	writeAscii(buf, offset, "IHDR")
	offset += 4
	writeU32BE(buf, offset, width)
	offset += 4
	writeU32BE(buf, offset, height)
	offset += 4
	writeU8(buf, offset, 8)
	writeU8(buf, offset + 1, 6)
	writeU8(buf, offset + 2, 0)
	writeU8(buf, offset + 3, 0)
	writeU8(buf, offset + 4, 0)
	offset += 5
	writeU32BE(buf, offset, crc32(buf, offset - 17, 17))
	offset += 4

	-- IDAT (zlib: header, stored deflate blocks, Adler32)
	writeU32BE(buf, offset, idatLen)
	offset += 4
	local typeOffset = offset
	writeAscii(buf, offset, "IDAT")
	offset += 4
	writeU8(buf, offset, 0x78)
	writeU8(buf, offset + 1, 0x01)
	offset += 2
	local position = 0
	while position < rawLen do
		local length = math.min(STORED_MAX, rawLen - position)
		local final = if position + length >= rawLen then 1 else 0
		writeU8(buf, offset, final)
		writeU16LE(buf, offset + 1, length)
		writeU16LE(buf, offset + 3, bit32.band(bit32.bnot(length), 0xFFFF))
		offset += 5
		for i = 0, length - 1 do
			buffer.writeu8(buf, offset + i, buffer.readu8(raw, position + i))
		end
		offset += length
		position += length
	end
	writeU32BE(buf, offset, adler32(raw, 0, rawLen))
	offset += 4
	writeU32BE(buf, offset, crc32(buf, typeOffset, offset - typeOffset))
	offset += 4

	-- IEND
	writeU32BE(buf, offset, 0)
	offset += 4
	writeAscii(buf, offset, "IEND")
	offset += 4
	writeU32BE(buf, offset, IEND_CRC)
	offset += 4

	return buf
end

return M
