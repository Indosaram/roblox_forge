--!strict
-- Specs for Pixels: canvas bounds, alpha blending, deterministic noise, the
-- RGBA8 buffer layout, and the PPM header.

local Pixels = require("./Pixels")

local function alphaAt(canvas: Pixels.Canvas, x: number, y: number): number
	local _, _, _, a = canvas:get(x, y)
	return a
end

local function sameData(a: Pixels.Canvas, b: Pixels.Canvas): boolean
	if #a.data ~= #b.data then
		return false
	end
	for i = 1, #a.data do
		if a.data[i] ~= b.data[i] then
			return false
		end
	end
	return true
end

return {
	["new makes an empty RGBA canvas"] = function()
		local canvas = Pixels.new(4, 3)
		assert(canvas.width == 4 and canvas.height == 3, "dimensions round-trip")
		assert(#canvas.data == 4 * 3 * 4, "data holds one RGBA quad per pixel")
		local r, g, b, a = canvas:get(0, 0)
		assert(r == 0 and g == 0 and b == 0 and a == 0, "a new canvas is transparent black")
	end,

	["new rejects non-positive or fractional dimensions"] = function()
		assert(not pcall(Pixels.new, 0, 4), "zero width rejected")
		assert(not pcall(Pixels.new, 4, -1), "negative height rejected")
		assert(not pcall(Pixels.new, 1.5, 4), "fractional width rejected")
	end,

	["set and get round-trip channels"] = function()
		local canvas = Pixels.new(2, 2)
		canvas:set(1, 1, { r = 0.25, g = 0.5, b = 0.75, a = 1 })
		local r, g, b, a = canvas:get(1, 1)
		assert(r == 0.25 and g == 0.5 and b == 0.75 and a == 1, "channels round-trip")
	end,

	["get outside the canvas is transparent"] = function()
		local canvas = Pixels.new(2, 2)
		assert(alphaAt(canvas, 5, 5) == 0, "out-of-bounds get is transparent")
		assert(alphaAt(canvas, -1, 0) == 0, "negative coordinates are transparent")
	end,

	["circle stays inside its bounding box"] = function()
		local canvas = Pixels.new(16, 16)
		canvas:circle(4, 4, 3, { r = 1, g = 0, b = 0, a = 1 }, false)
		assert(alphaAt(canvas, 4, 4) == 1, "the center is painted")
		assert(alphaAt(canvas, 12, 12) == 0, "far pixels stay clear")
		assert(alphaAt(canvas, 4, 125) == 0, "y outside the canvas is clear")
	end,

	["circle clips at the canvas edge"] = function()
		local canvas = Pixels.new(8, 8)
		canvas:circle(0, 0, 5, { r = 1, g = 1, b = 1, a = 1 }, false)
		assert(alphaAt(canvas, 0, 0) == 1, "the clipped corner is painted")
		assert(alphaAt(canvas, 7, 7) == 0, "the opposite corner stays clear")
	end,

	["rect fills exactly its bounds"] = function()
		local canvas = Pixels.new(8, 8)
		canvas:rect(2, 3, 3, 2, { r = 1, g = 1, b = 1, a = 1 })
		assert(alphaAt(canvas, 2, 3) == 1, "top-left is inside")
		assert(alphaAt(canvas, 4, 4) == 1, "bottom-right is inside")
		assert(alphaAt(canvas, 5, 3) == 0, "one past the right edge is outside")
		assert(alphaAt(canvas, 2, 5) == 0, "one past the bottom edge is outside")
	end,

	["roundRect rounds corners and keeps the edges"] = function()
		local canvas = Pixels.new(16, 16)
		canvas:roundRect(2, 2, 12, 12, 4, { r = 1, g = 1, b = 1, a = 1 })
		assert(alphaAt(canvas, 8, 8) > 0.9, "the center is filled")
		assert(alphaAt(canvas, 2, 2) < 0.5, "the corner is rounded away")
		assert(alphaAt(canvas, 8, 3) > 0.9, "the top edge is filled")
	end,

	["blit alpha-blends source over destination"] = function()
		local dst = Pixels.new(2, 2)
		dst:fill({ r = 0, g = 0, b = 0, a = 1 })
		local src = Pixels.new(2, 2)
		src:fill({ r = 1, g = 1, b = 1, a = 0.5 })
		dst:blit(src, 0, 0)
		local r, _, _, a = dst:get(0, 0)
		assert(math.abs(r - 0.5) < 1e-6, "50% white over black is mid grey")
		assert(math.abs(a - 1) < 1e-6, "opaque destination keeps alpha 1")
	end,

	["noise is deterministic for a seed and varies between seeds"] = function()
		local function render(seed: number): Pixels.Canvas
			local canvas = Pixels.new(16, 16)
			canvas:noise(seed, 4, { r = 0, g = 0, b = 0, a = 1 }, { r = 1, g = 1, b = 1, a = 1 })
			return canvas
		end
		assert(sameData(render(7), render(7)), "the same seed repeats")
		assert(not sameData(render(7), render(8)), "a different seed changes the field")
	end,

	["noise wraps one lattice period so it tiles"] = function()
		-- 41px wide at scale 8 gives a 5-cell lattice; pixel 40 is exactly one
		-- period past pixel 0, so the field must match.
		local canvas = Pixels.new(41, 16)
		canvas:noise(3, 8, { r = 0, g = 0, b = 0, a = 1 }, { r = 1, g = 1, b = 1, a = 1 })
		for y = 0, 15 do
			local left = canvas:get(0, y)
			local wrapped = canvas:get(40, y)
			assert(left == wrapped, "column 0 and column 40 must match (y=" .. tostring(y) .. ")")
		end
	end,

	["toBuffer packs RGBA8 in width*height*4 bytes"] = function()
		local canvas = Pixels.new(3, 2)
		canvas:fill({ r = 1, g = 0, b = 0, a = 1 })
		local buf = canvas:toBuffer()
		assert(buffer.len(buf) == 3 * 2 * 4, "buffer length is w*h*4")
		assert(buffer.readu8(buf, 0) == 255, "red is 255")
		assert(buffer.readu8(buf, 1) == 0, "green is 0")
		assert(buffer.readu8(buf, 2) == 0, "blue is 0")
		assert(buffer.readu8(buf, 3) == 255, "alpha is 255")
	end,

	["toPPM writes a P6 header and RGB bytes"] = function()
		local canvas = Pixels.new(2, 1)
		canvas:set(0, 0, { r = 1, g = 0, b = 0, a = 1 })
		canvas:set(1, 0, { r = 0, g = 1, b = 0, a = 1 })
		local ppm = canvas:toPPM()
		assert(string.sub(ppm, 1, 11) == "P6\n2 1\n255\n", "header is P6 with dimensions and maxval")
		assert(#ppm == 11 + 2 * 3, "one RGB triple per pixel follows the header")
		assert(
			string.byte(ppm, 12) == 255 and string.byte(ppm, 13) == 0 and string.byte(ppm, 14) == 0,
			"first pixel is red"
		)
		assert(
			string.byte(ppm, 15) == 0 and string.byte(ppm, 16) == 255 and string.byte(ppm, 17) == 0,
			"second pixel is green"
		)
	end,

	["stripes and linearGradient fill the canvas"] = function()
		local canvas = Pixels.new(8, 8)
		canvas:stripes({ r = 1, g = 1, b = 1, a = 1 }, { r = 0, g = 0, b = 0, a = 1 }, 2)
		assert(alphaAt(canvas, 0, 0) == 1, "the first band is painted")
		assert(canvas.data[1] == 1, "the first band is white")
		assert(canvas.data[(3 * 8 + 2) * 4 + 1] == 0, "the second band is black")

		local gradient = Pixels.new(8, 8)
		gradient:linearGradient(0, 0, 8, 8, { r = 0, g = 0, b = 0, a = 1 }, { r = 1, g = 1, b = 1, a = 1 })
		local top = gradient:get(0, 0)
		local bottom = gradient:get(0, 7)
		assert(bottom > top, "a vertical gradient brightens downward")
	end,
}
