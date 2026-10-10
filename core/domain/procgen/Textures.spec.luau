--!strict
-- Specs for Textures: size, non-empty alpha, and determinism of the scale and
-- tileable-ground painters.

local Textures = require("./Textures")

local SPEC: Textures.Spec = { body = { 40, 170, 170 }, accent = { 120, 240, 220 }, seed = 104 }

local function assertNonEmpty(canvas: any, label: string): ()
	local painted = false
	for i = 4, #canvas.data, 4 do
		if canvas.data[i] > 0 then
			painted = true
			break
		end
	end
	assert(painted, label .. " must paint at least one pixel")
end

local function sameData(a: any, b: any): boolean
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
	["scales paints a square, non-empty, deterministic texture"] = function()
		local canvas = Textures.scales(SPEC, 64)
		assert(canvas.width == 64 and canvas.height == 64, "scales texture is square")
		assertNonEmpty(canvas, "scales texture")
		assert(sameData(canvas, Textures.scales(SPEC, 64)), "scales texture repeats")
	end,

	["ground paints tileable noise from an array palette"] = function()
		local canvas = Textures.ground({ { 40, 40, 40 }, { 120, 120, 120 } }, 64, 7)
		assert(canvas.width == 64 and canvas.height == 64, "ground texture is square")
		assertNonEmpty(canvas, "ground texture")
		assert(sameData(canvas, Textures.ground({ { 40, 40, 40 }, { 120, 120, 120 } }, 64, 7)), "ground repeats")
	end,

	["ground accepts a named palette"] = function()
		local canvas =
			Textures.ground({ base = { r = 0.2, g = 0.2, b = 0.2 }, detail = { r = 0.6, g = 0.6, b = 0.6 } }, 32, 1)
		assertNonEmpty(canvas, "named-palette ground texture")
	end,
}
