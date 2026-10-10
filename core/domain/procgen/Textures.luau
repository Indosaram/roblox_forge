--!strict
-- Textures: deterministic 2D surface painters built on Pixels, in the same
-- pure-Luau, no-math.random style as the creature/prop mesh generators. Colors
-- accept either form Pixels does (0..1 tables or 0..255 arrays).

local Pixels = require("./Pixels")

local Textures = {}

export type Spec = {
	body: any,
	accent: any,
	seed: number?,
}

local DEFAULT_SIZE = 128
local BLACK: Pixels.Color = { r = 0, g = 0, b = 0, a = 1 }
local WHITE: Pixels.Color = { r = 1, g = 1, b = 1, a = 1 }

local function expectSize(size: number?): number
	local value = size or DEFAULT_SIZE
	if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
		error("invalid texture size")
	end
	return value
end

--- Reptile scales: a shaded body base, fine value noise for the hide, then
--- staggered rows of accent scale rings with soft highlights.
function Textures.scales(spec: Spec, size: number?, seed: number?): Pixels.Canvas
	local s = expectSize(size)
	local useSeed = seed or spec.seed or 0
	local canvas = Pixels.new(s, s)
	local body = Pixels.toColor(spec.body)
	local accent = Pixels.toColor(spec.accent)

	canvas:fill(Pixels.mix(body, BLACK, 0.25))
	canvas:noise(useSeed, math.max(2, s / 16), Pixels.mix(body, BLACK, 0.4), Pixels.mix(body, WHITE, 0.15))

	local rows = 6
	local cols = 6
	local cell = s / rows
	local rng = Pixels.rng(useSeed)
	local highlight = Pixels.mix(body, WHITE, 0.45)
	for row = 0, rows - 1 do
		local yBase = (row + 0.5) * cell
		local offset = if row % 2 == 1 then cell * 0.5 else 0
		for col = 0, cols do
			local jitterX = (rng() - 0.5) * cell * 0.12
			local jitterY = (rng() - 0.5) * cell * 0.12
			local x = col * cell + offset + jitterX
			local y = yBase + jitterY
			canvas:ring(x, y, cell * 0.52, { r = accent.r, g = accent.g, b = accent.b, a = 0.4 }, cell * 0.13)
			canvas:circle(
				x,
				y - cell * 0.14,
				cell * 0.3,
				{ r = highlight.r, g = highlight.g, b = highlight.b, a = 0.22 },
				true
			)
		end
	end
	return canvas
end

--- Tileable ground noise. `palette` is either `{ colorA, colorB }` or a table
--- with `base`/`detail` (aliases `body`/`accent`). Two tileable octaves keep
--- the texture seamless when repeated across a map.
function Textures.ground(palette: any, size: number?, seed: number?): Pixels.Canvas
	local s = expectSize(size)
	local useSeed = seed or 0
	local base: Pixels.Color
	local detail: Pixels.Color
	if typeof(palette) == "table" and palette[1] ~= nil then
		base = Pixels.toColor(palette[1])
		detail = Pixels.toColor(palette[2] or palette[1])
	elseif typeof(palette) == "table" then
		base = Pixels.toColor(palette.base or palette.body or { r = 0.35, g = 0.32, b = 0.28, a = 1 })
		detail = Pixels.toColor(palette.detail or palette.accent or { r = 0.52, g = 0.47, b = 0.4, a = 1 })
	else
		base = { r = 0.35, g = 0.32, b = 0.28, a = 1 }
		detail = { r = 0.52, g = 0.47, b = 0.4, a = 1 }
	end

	local canvas = Pixels.new(s, s)
	canvas:fill(base)
	canvas:noise(useSeed, math.max(2, s / 8), base, detail)
	canvas:noise(
		useSeed + 101,
		math.max(2, s / 16),
		{ r = base.r, g = base.g, b = base.b, a = 0.55 },
		{ r = detail.r, g = detail.g, b = detail.b, a = 0.55 }
	)
	return canvas
end

return Textures
