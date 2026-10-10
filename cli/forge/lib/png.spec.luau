--!strict
-- Specs for the minimal PNG encoder: signature/chunk structure, zlib stored
-- header, and byte-stable output for identical canvases.

local Png = require("./png")
local Pixels = require("../../../core/domain/procgen/Pixels")

local SIGNATURE = string.char(137, 80, 78, 71, 13, 10, 26, 10)

local function someCanvas(): any
	local canvas = Pixels.new(3, 2)
	canvas:fill({ r = 0.2, g = 0.4, b = 0.6, a = 1 })
	canvas:set(1, 1, { r = 1, g = 0, b = 0, a = 1 })
	return canvas
end

return {
	["encodes a PNG signature and IHDR for the canvas size"] = function()
		local text = buffer.tostring(Png.encode(someCanvas()))
		assert(string.sub(text, 1, 8) == SIGNATURE, "PNG signature must lead the file")
		assert(string.sub(text, 13, 16) == "IHDR", "IHDR must follow the signature")
		assert(string.byte(text, 25) == 8, "bit depth is 8")
		assert(string.byte(text, 26) == 6, "colour type is RGBA")
		-- width/height are big-endian integers 17..20 and 21..24.
		assert(string.byte(text, 20) == 3, "width is encoded")
		assert(string.byte(text, 24) == 2, "height is encoded")
	end,

	["starts the IDAT with a stored zlib header and ends with IEND"] = function()
		local text = buffer.tostring(Png.encode(someCanvas()))
		assert(string.sub(text, 38, 41) == "IDAT", "IDAT chunk follows IHDR")
		assert(string.byte(text, 42) == 0x78 and string.byte(text, 43) == 0x01, "zlib header is stored deflate")
		local last = #text
		assert(
			string.sub(text, last - 11, last)
				== string.char(0, 0, 0, 0) .. "IEND" .. string.char(0xAE, 0x42, 0x60, 0x82),
			"IEND chunk with its fixed CRC closes the file"
		)
	end,

	["reproduces identical bytes for identical canvases"] = function()
		local first = buffer.tostring(Png.encode(someCanvas()))
		local second = buffer.tostring(Png.encode(someCanvas()))
		assert(first == second, "the same canvas must encode to the same bytes")
		assert(#first > 0, "the file is not empty")
	end,
}
