--!strict
-- Icons: deterministic 2D icon painters built on Pixels. Pure Luau (no Roblox
-- APIs, no math.random), so the same code renders the CLI's .ppm previews under
-- Lune and the live ImageLabels on the client.
--
-- A spec mirrors an entry from games/<pack>/assets/procgen.yml: body/accent/eye
-- colors in either accepted color form, plus a stable seed. Every painter
-- returns a square Pixels canvas with a transparent background.

local Pixels = require("./Pixels")

local Icons = {}

export type Spec = {
	body: any,
	accent: any,
	eye: any?,
	seed: number?,
	archetype: string?,
	scale: number?,
}

local DEFAULT_SIZE = 128

local BLACK: Pixels.Color = { r = 0, g = 0, b = 0, a = 1 }
local WHITE: Pixels.Color = { r = 1, g = 1, b = 1, a = 1 }

local function shade(color: Pixels.Color, amount: number, target: Pixels.Color): Pixels.Color
	return Pixels.mix(color, target, amount)
end

local function expectSize(size: number?): number
	local value = size or DEFAULT_SIZE
	if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
		error("invalid icon size")
	end
	return value
end

--- Lays a vertical gradient disc with a 1px anti-aliased edge.
local function gradientDisc(
	canvas: Pixels.Canvas,
	cx: number,
	cy: number,
	radius: number,
	top: Pixels.Color,
	bottom: Pixels.Color
): ()
	local minX = math.max(0, math.floor(cx - radius - 1))
	local maxX = math.min(canvas.width - 1, math.ceil(cx + radius + 1))
	local minY = math.max(0, math.floor(cy - radius - 1))
	local maxY = math.min(canvas.height - 1, math.ceil(cy + radius + 1))
	local topY = cy - radius
	local span = radius * 2
	for py = minY, maxY do
		local dy = py + 0.5 - cy
		for px = minX, maxX do
			local dx = px + 0.5 - cx
			local dist = math.sqrt(dx * dx + dy * dy)
			local coverage = math.clamp(radius + 0.5 - dist, 0, 1)
			if coverage > 0 then
				local t = math.clamp(((py + 0.5) - topY) / span, 0, 1)
				canvas:blend(px, py, Pixels.mix(top, bottom, t), coverage)
			end
		end
	end
end

--- Draws one diamond (|nx| + |ny| <= 1) centered at (cx, cy) with the given
--- half-extent, used for the coin/badge motifs.
local function diamond(canvas: Pixels.Canvas, cx: number, cy: number, extent: number, color: any): ()
	local minX = math.max(0, math.floor(cx - extent - 1))
	local maxX = math.min(canvas.width - 1, math.ceil(cx + extent + 1))
	local minY = math.max(0, math.floor(cy - extent - 1))
	local maxY = math.min(canvas.height - 1, math.ceil(cy + extent + 1))
	for py = minY, maxY do
		local ny = math.abs(py + 0.5 - cy) / extent
		for px = minX, maxX do
			local nx = math.abs(px + 0.5 - cx) / extent
			local coverage = math.clamp((1 - (nx + ny)) * extent + 0.5, 0, 1)
			if coverage > 0 then
				canvas:blend(px, py, color, coverage)
			end
		end
	end
end

--- An egg portrait: a tapered shell gradient, deterministic accent speckles,
--- and a soft specular highlight.
function Icons.egg(spec: Spec, size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	local body = Pixels.toColor(spec.body)
	local accent = Pixels.toColor(spec.accent)
	local seed = spec.seed or 0

	local top = s * 0.10
	local bottom = s * 0.92
	local centerY = (top + bottom) / 2
	local halfH = (bottom - top) / 2
	local cx = s * 0.5
	local baseW = s * 0.35
	local dark = shade(body, 0.4, BLACK)
	local light = Pixels.mix(body, accent, 0.4)

	for py = math.max(0, math.floor(top - 1)), math.min(s - 1, math.ceil(bottom + 1)) do
		local ny = (centerY - (py + 0.5)) / halfH
		if math.abs(ny) <= 1 then
			local limit = baseW * math.sqrt(1 - ny * ny) * (1 - 0.16 * ny)
			local minX = math.max(0, math.floor(cx - limit - 1))
			local maxX = math.min(s - 1, math.ceil(cx + limit + 1))
			for px = minX, maxX do
				local coverage = math.clamp(limit - math.abs(px + 0.5 - cx) + 0.5, 0, 1)
				if coverage > 0 then
					local t = math.clamp((py + 0.5 - top) / (bottom - top), 0, 1)
					canvas:blend(px, py, Pixels.mix(dark, light, t), coverage)
				end
			end
		end
	end

	local rng = Pixels.rng(seed)
	local spots = 4 + math.floor(rng() * 3)
	for _ = 1, spots do
		local ny = -0.6 + rng() * 1.2
		local limit = baseW * math.sqrt(math.max(0, 1 - ny * ny)) * (1 - 0.16 * ny)
		local px = cx + (rng() - 0.5) * limit * 1.1
		local py = centerY - ny * halfH
		canvas:circle(px, py, s * 0.045, { r = accent.r, g = accent.g, b = accent.b, a = 0.85 }, true)
	end

	canvas:circle(cx - baseW * 0.4, top + halfH * 0.55, s * 0.09, { r = 1, g = 1, b = 1, a = 0.3 }, true)
	return canvas
end

--- A creature portrait: a shaded disc with an accent rim, eyes, and a
--- highlight. The silhouette color comes from the spec body/accent/eye.
function Icons.creature(spec: Spec, size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	local body = Pixels.toColor(spec.body)
	local accent = Pixels.toColor(spec.accent)
	local eye = Pixels.toColor(spec.eye or WHITE)

	local cx = s * 0.5
	local cy = s * 0.5
	local radius = s * 0.44
	local top = shade(body, 0.22, WHITE)
	local bottom = shade(body, 0.42, BLACK)

	gradientDisc(canvas, cx, cy, radius, top, bottom)
	canvas:ring(cx, cy, radius * 0.97, accent, s * 0.055)

	local eyeRadius = s * 0.08
	local eyeX = s * 0.15
	local eyeY = cy - s * 0.05
	canvas:circle(cx - eyeX, eyeY, eyeRadius, eye, true)
	canvas:circle(cx + eyeX, eyeY, eyeRadius, eye, true)
	canvas:circle(cx - eyeX, eyeY, eyeRadius * 0.45, shade(body, 0.6, BLACK), true)
	canvas:circle(cx + eyeX, eyeY, eyeRadius * 0.45, shade(body, 0.6, BLACK), true)

	canvas:ring(cx, cy, radius * 0.62, { r = accent.r, g = accent.g, b = accent.b, a = 0.28 }, s * 0.04)
	canvas:circle(cx - radius * 0.38, cy - radius * 0.42, s * 0.1, { r = 1, g = 1, b = 1, a = 0.22 }, true)
	return canvas
end

--- A gold coin: banded radial disc, dark rim, bright inner ring, and a diamond
--- motif. No spec; used for currency labels.
function Icons.coin(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	local cx = s * 0.5
	local cy = s * 0.5
	local radius = s * 0.44

	local dark = { r = 0.62, g = 0.38, b = 0.04, a = 1 }
	local mid = { r = 0.95, g = 0.72, b = 0.15, a = 1 }
	local bright = { r = 1, g = 0.93, b = 0.58, a = 1 }

	canvas:circle(cx, cy, radius, dark, true)
	for i = 1, 10 do
		local f = i / 10
		canvas:circle(cx, cy, radius * (1 - 0.45 * f), Pixels.mix(dark, bright, f), true)
	end
	canvas:ring(cx, cy, radius * 0.99, { r = 0.45, g = 0.26, b = 0.02, a = 0.9 }, s * 0.07)
	canvas:ring(cx, cy, radius * 0.8, { r = 1, g = 0.95, b = 0.6, a = 0.5 }, s * 0.03)
	diamond(canvas, cx, cy, radius * 0.42, mid)
	diamond(canvas, cx, cy, radius * 0.24, bright)
	canvas:circle(cx - radius * 0.35, cy - radius * 0.42, s * 0.1, { r = 1, g = 1, b = 1, a = 0.25 }, true)
	return canvas
end

local RARITY_COLORS: { [string]: { number } } = {
	common = { 150, 150, 160 },
	uncommon = { 80, 200, 120 },
	rare = { 70, 140, 255 },
	epic = { 170, 90, 235 },
	legendary = { 255, 180, 50 },
	mythic = { 255, 90, 120 },
}

--- A circular rarity badge tinted by the rarity name (case-insensitive),
--- falling back to the common grey for unknown rarities.
function Icons.rarityBadge(rarity: string, size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	local key = string.lower(tostring(rarity))
	local rgb = RARITY_COLORS[key] or RARITY_COLORS.common
	local base: Pixels.Color = { r = rgb[1] / 255, g = rgb[2] / 255, b = rgb[3] / 255, a = 1 }
	local dark = shade(base, 0.42, BLACK)
	local light = shade(base, 0.35, WHITE)

	local cx = s * 0.5
	local cy = s * 0.5
	local radius = s * 0.42
	canvas:circle(cx, cy, radius, dark, true)
	for i = 1, 8 do
		local f = i / 8
		canvas:circle(cx, cy, radius * (1 - 0.5 * f), Pixels.mix(dark, light, f), true)
	end
	canvas:ring(cx, cy, radius * 0.99, shade(base, 0.55, BLACK), s * 0.06)
	diamond(canvas, cx, cy, radius * 0.46, { r = 1, g = 1, b = 1, a = 0.85 })
	diamond(canvas, cx, cy, radius * 0.28, light)
	return canvas
end

-- ---------------------------------------------------------------------------
-- Glossy HUD glyphs
--
-- Each painter below draws the same "plate" (soft shadow, dark border, vertical
-- gradient body, top sheen) and then a white pictogram on top, so one call
-- yields a mobile-game icon at 64..128px. Every coordinate is a fraction of the
-- requested size and the code stays pure/deterministic for Lune previews.
-- ---------------------------------------------------------------------------

local function softShadow(
	canvas: Pixels.Canvas,
	x: number,
	y: number,
	width: number,
	height: number,
	radius: number,
	spread: number,
	alpha: number
): ()
	local layers = 4
	for i = layers, 1, -1 do
		local f = i / layers
		local grow = spread * f
		canvas:roundRect(
			x - grow,
			y - grow + spread * 0.35,
			width + grow * 2,
			height + grow * 2,
			radius + grow,
			{ r = 0, g = 0, b = 0, a = alpha * (1 - f * 0.7) }
		)
	end
end

--- Vertical-gradient rounded rectangle matching Pixels.roundRect's coverage so
--- the plate body reads as one smooth shell instead of banded strips.
local function roundedGradient(
	canvas: Pixels.Canvas,
	x: number,
	y: number,
	width: number,
	height: number,
	radius: number,
	top: Pixels.Color,
	bottom: Pixels.Color
): ()
	local minX = math.max(0, math.floor(x - 1))
	local maxX = math.min(canvas.width - 1, math.ceil(x + width + 1))
	local minY = math.max(0, math.floor(y - 1))
	local maxY = math.min(canvas.height - 1, math.ceil(y + height + 1))
	local centerX = x + width / 2
	local centerY = y + height / 2
	local halfW = width / 2
	local halfH = height / 2
	local r = math.clamp(radius, 0, math.min(halfW, halfH))
	for py = minY, maxY do
		local dy = math.abs(py + 0.5 - centerY) - (halfH - r)
		for px = minX, maxX do
			local dx = math.abs(px + 0.5 - centerX) - (halfW - r)
			local qx = math.max(dx, 0)
			local qy = math.max(dy, 0)
			local signed = math.sqrt(qx * qx + qy * qy) + math.min(math.max(dx, dy), 0) - r
			local coverage = math.clamp(0.5 - signed, 0, 1)
			if coverage > 0 then
				local t = math.clamp((py + 0.5 - y) / height, 0, 1)
				canvas:blend(px, py, Pixels.mix(top, bottom, t), coverage)
			end
		end
	end
end

--- Shared glossy plate: soft drop shadow, dark outline, gradient shell, sheen.
local function plate(
	canvas: Pixels.Canvas,
	s: number,
	top: Pixels.Color,
	bottom: Pixels.Color,
	border: Pixels.Color
): ()
	local pad = s * 0.13
	local x = pad
	local y = pad
	local w = s - pad * 2
	local h = s - pad * 2
	local radius = w * 0.27
	softShadow(canvas, x, y, w, h, radius, s * 0.06, 0.22)
	local edge = math.max(1, s * 0.028)
	canvas:roundRect(x - edge, y - edge, w + edge * 2, h + edge * 2, radius + edge, border)
	roundedGradient(canvas, x, y, w, h, radius, top, bottom)
	canvas:roundRect(x + w * 0.12, y + h * 0.1, w * 0.5, h * 0.16, h * 0.08, { r = 1, g = 1, b = 1, a = 0.28 })
end

local function line(
	canvas: Pixels.Canvas,
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	thickness: number,
	color: any
): ()
	local dx = x1 - x0
	local dy = y1 - y0
	local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) * 1.5))
	for i = 0, steps do
		local t = i / steps
		canvas:circle(x0 + dx * t, y0 + dy * t, thickness / 2, color, true)
	end
end

local function angleWithin(angle: number, a0: number, a1: number): boolean
	local span = (a1 - a0) % (math.pi * 2)
	local rel = (angle - a0) % (math.pi * 2)
	return rel <= span
end

local function arc(
	canvas: Pixels.Canvas,
	cx: number,
	cy: number,
	radius: number,
	thickness: number,
	a0: number,
	a1: number,
	color: any
): ()
	local half = thickness / 2
	local minX = math.max(0, math.floor(cx - radius - half - 1))
	local maxX = math.min(canvas.width - 1, math.ceil(cx + radius + half + 1))
	local minY = math.max(0, math.floor(cy - radius - half - 1))
	local maxY = math.min(canvas.height - 1, math.ceil(cy + radius + half + 1))
	for py = minY, maxY do
		local dy = py + 0.5 - cy
		for px = minX, maxX do
			local dx = px + 0.5 - cx
			local dist = math.sqrt(dx * dx + dy * dy)
			local band = math.abs(dist - radius)
			if band <= half + 0.5 and angleWithin(math.atan2(dy, dx), a0, a1) then
				canvas:blend(px, py, color, math.clamp(half + 0.5 - band, 0, 1))
			end
		end
	end
end

local function pieSlice(
	canvas: Pixels.Canvas,
	cx: number,
	cy: number,
	radius: number,
	a0: number,
	a1: number,
	color: any
): ()
	local minX = math.max(0, math.floor(cx - radius - 1))
	local maxX = math.min(canvas.width - 1, math.ceil(cx + radius + 1))
	local minY = math.max(0, math.floor(cy - radius - 1))
	local maxY = math.min(canvas.height - 1, math.ceil(cy + radius + 1))
	for py = minY, maxY do
		local dy = py + 0.5 - cy
		for px = minX, maxX do
			local dx = px + 0.5 - cx
			local dist = math.sqrt(dx * dx + dy * dy)
			if dist <= radius + 0.5 and angleWithin(math.atan2(dy, dx), a0, a1) then
				canvas:blend(px, py, color, math.clamp(radius + 0.5 - dist, 0, 1))
			end
		end
	end
end

local function scaledPoints(points: { { number } }, s: number): { { number } }
	local out: { { number } } = {}
	for _, p in points do
		table.insert(out, { p[1] * s, p[2] * s })
	end
	return out
end

local function scalePoints(points: { { number } }, cx: number, cy: number, k: number): { { number } }
	local out: { { number } } = {}
	for _, p in points do
		table.insert(out, { cx + (p[1] - cx) * k, cy + (p[2] - cy) * k })
	end
	return out
end

local function offsetPoints(points: { { number } }, dx: number, dy: number): { { number } }
	local out: { { number } } = {}
	for _, p in points do
		table.insert(out, { p[1] + dx, p[2] + dy })
	end
	return out
end

--- Fills a convex polygon with anti-aliased edges. Points may be listed in
--- either winding; the routine orients them so the interior is to the left.
local function polygon(canvas: Pixels.Canvas, points: { { number } }, color: any): ()
	local area = 0
	for i = 1, #points do
		local a = points[i]
		local b = points[(i % #points) + 1]
		area += a[1] * b[2] - b[1] * a[2]
	end
	local oriented: { { number } } = points
	if area < 0 then
		oriented = {}
		for i = #points, 1, -1 do
			table.insert(oriented, points[i])
		end
	end

	local minX, maxX = oriented[1][1], oriented[1][1]
	local minY, maxY = oriented[1][2], oriented[1][2]
	for _, p in oriented do
		minX = math.min(minX, p[1])
		maxX = math.max(maxX, p[1])
		minY = math.min(minY, p[2])
		maxY = math.max(maxY, p[2])
	end
	local x0 = math.max(0, math.floor(minX - 1))
	local x1 = math.min(canvas.width - 1, math.ceil(maxX + 1))
	local y0 = math.max(0, math.floor(minY - 1))
	local y1 = math.min(canvas.height - 1, math.ceil(maxY + 1))
	for py = y0, y1 do
		for px = x0, x1 do
			local x = px + 0.5
			local y = py + 0.5
			local maxOut = -math.huge
			for i = 1, #oriented do
				local a = oriented[i]
				local b = oriented[(i % #oriented) + 1]
				local ex = b[1] - a[1]
				local ey = b[2] - a[2]
				local len = math.sqrt(ex * ex + ey * ey)
				if len > 0 then
					local cross = ex * (y - a[2]) - ey * (x - a[1])
					maxOut = math.max(maxOut, -cross / len)
				end
			end
			local coverage = math.clamp(0.5 - maxOut, 0, 1)
			if coverage > 0 then
				canvas:blend(px, py, color, coverage)
			end
		end
	end
end

local RED_TOP: Pixels.Color = { r = 0.98, g = 0.5, b = 0.38, a = 1 }
local RED_BOTTOM: Pixels.Color = { r = 0.66, g = 0.12, b = 0.16, a = 1 }
local RED_BORDER: Pixels.Color = { r = 0.42, g = 0.06, b = 0.1, a = 1 }
local PURPLE_TOP: Pixels.Color = { r = 0.74, g = 0.56, b = 1, a = 1 }
local PURPLE_BOTTOM: Pixels.Color = { r = 0.42, g = 0.2, b = 0.72, a = 1 }
local PURPLE_BORDER: Pixels.Color = { r = 0.25, g = 0.1, b = 0.45, a = 1 }
local GOLD_TOP: Pixels.Color = { r = 1, g = 0.85, b = 0.44, a = 1 }
local GOLD_BOTTOM: Pixels.Color = { r = 0.84, g = 0.53, b = 0.1, a = 1 }
local GOLD_BORDER: Pixels.Color = { r = 0.5, g = 0.3, b = 0.02, a = 1 }
local GREEN_TOP: Pixels.Color = { r = 0.58, g = 0.94, b = 0.6, a = 1 }
local GREEN_BOTTOM: Pixels.Color = { r = 0.17, g = 0.58, b = 0.3, a = 1 }
local GREEN_BORDER: Pixels.Color = { r = 0.06, g = 0.3, b = 0.14, a = 1 }
local BLUE_TOP: Pixels.Color = { r = 0.55, g = 0.84, b = 1, a = 1 }
local BLUE_BOTTOM: Pixels.Color = { r = 0.14, g = 0.43, b = 0.78, a = 1 }
local BLUE_BORDER: Pixels.Color = { r = 0.06, g = 0.2, b = 0.44, a = 1 }
local SLATE_TOP: Pixels.Color = { r = 0.62, g = 0.67, b = 0.8, a = 1 }
local SLATE_BOTTOM: Pixels.Color = { r = 0.28, g = 0.32, b = 0.42, a = 1 }
local SLATE_BORDER: Pixels.Color = { r = 0.12, g = 0.14, b = 0.2, a = 1 }

--- A crossable sword, for the raid control.
function Icons.raid(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, RED_TOP, RED_BOTTOM, RED_BORDER)
	local gold: Pixels.Color = { r = 1, g = 0.85, b = 0.42, a = 1 }
	line(canvas, s * 0.42, s * 0.58, s * 0.72, s * 0.28, s * 0.1, WHITE)
	polygon(canvas, { { s * 0.8, s * 0.2 }, { s * 0.62, s * 0.3 }, { s * 0.72, s * 0.42 } }, WHITE)
	line(canvas, s * 0.34, s * 0.44, s * 0.54, s * 0.62, s * 0.07, gold)
	line(canvas, s * 0.44, s * 0.56, s * 0.34, s * 0.66, s * 0.06, gold)
	canvas:circle(s * 0.32, s * 0.68, s * 0.05, gold, true)
	return canvas
end

--- Two arrows feeding one fuse arrow, for the merge controls.
function Icons.merge(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, PURPLE_TOP, PURPLE_BOTTOM, PURPLE_BORDER)
	line(canvas, s * 0.28, s * 0.7, s * 0.45, s * 0.5, s * 0.08, WHITE)
	line(canvas, s * 0.72, s * 0.7, s * 0.55, s * 0.5, s * 0.08, WHITE)
	line(canvas, s * 0.5, s * 0.64, s * 0.5, s * 0.4, s * 0.1, WHITE)
	polygon(canvas, { { s * 0.5, s * 0.24 }, { s * 0.34, s * 0.44 }, { s * 0.66, s * 0.44 } }, WHITE)
	return canvas
end

--- A shopping bag, for the store control.
function Icons.store(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, GOLD_TOP, GOLD_BOTTOM, GOLD_BORDER)
	local accent: Pixels.Color = { r = 0.86, g = 0.6, b = 0.15, a = 1 }
	arc(canvas, s * 0.5, s * 0.44, s * 0.13, s * 0.07, -math.pi, 0, WHITE)
	canvas:roundRect(s * 0.28, s * 0.42, s * 0.44, s * 0.4, s * 0.07, WHITE)
	canvas:roundRect(s * 0.28, s * 0.58, s * 0.44, s * 0.05, 0, accent)
	canvas:circle(s * 0.5, s * 0.68, s * 0.04, accent, true)
	return canvas
end

--- A pie chart, for the odds control.
function Icons.odds(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, BLUE_TOP, BLUE_BOTTOM, BLUE_BORDER)
	local cx = s * 0.5
	local cy = s * 0.52
	local radius = s * 0.3
	local a0 = -math.pi / 2
	local a1 = a0 + math.pi * 2 * 0.36
	local a2 = a1 + math.pi * 2 * 0.34
	pieSlice(canvas, cx, cy, radius, a0, a1, { r = 1, g = 0.83, b = 0.35, a = 1 })
	pieSlice(canvas, cx, cy, radius, a1, a2, { r = 0.45, g = 0.85, b = 1, a = 1 })
	pieSlice(canvas, cx, cy, radius, a2, a0 + math.pi * 2, { r = 0.72, g = 0.55, b = 1, a = 1 })
	line(canvas, cx, cy, cx + math.cos(a1) * radius, cy + math.sin(a1) * radius, s * 0.03, WHITE)
	line(canvas, cx, cy, cx + math.cos(a2) * radius, cy + math.sin(a2) * radius, s * 0.03, WHITE)
	canvas:ring(cx, cy, radius, WHITE, s * 0.035)
	canvas:circle(cx, cy, s * 0.06, WHITE, true)
	return canvas
end

--- A person with a plus, for the invite control.
function Icons.invite(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, PURPLE_TOP, PURPLE_BOTTOM, PURPLE_BORDER)
	canvas:circle(s * 0.42, s * 0.36, s * 0.12, WHITE, true)
	canvas:roundRect(s * 0.24, s * 0.54, s * 0.36, s * 0.26, s * 0.13, WHITE)
	canvas:roundRect(s * 0.64, s * 0.43, s * 0.2, s * 0.055, s * 0.025, WHITE)
	canvas:roundRect(s * 0.715, s * 0.355, s * 0.05, s * 0.2, s * 0.025, WHITE)
	return canvas
end

--- A check mark, for quest rows and claim controls.
function Icons.quest(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, GREEN_TOP, GREEN_BOTTOM, GREEN_BORDER)
	line(canvas, s * 0.3, s * 0.52, s * 0.44, s * 0.66, s * 0.09, WHITE)
	line(canvas, s * 0.44, s * 0.66, s * 0.72, s * 0.34, s * 0.09, WHITE)
	return canvas
end

--- Three bars, for the HUD collapse toggle.
function Icons.menu(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, SLATE_TOP, SLATE_BOTTOM, SLATE_BORDER)
	for i = 0, 2 do
		canvas:roundRect(s * 0.28, s * (0.34 + i * 0.13), s * 0.44, s * 0.07, s * 0.035, WHITE)
	end
	return canvas
end

--- A shield with a check, for the siege shield product.
function Icons.shield(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, BLUE_TOP, BLUE_BOTTOM, BLUE_BORDER)
	local shape: { { number } } = {
		{ s * 0.3, s * 0.28 },
		{ s * 0.7, s * 0.28 },
		{ s * 0.7, s * 0.5 },
		{ s * 0.5, s * 0.78 },
		{ s * 0.3, s * 0.5 },
	}
	polygon(canvas, shape, WHITE)
	polygon(canvas, scalePoints(shape, s * 0.5, s * 0.5, 0.78), { r = 0.16, g = 0.42, b = 0.72, a = 1 })
	line(canvas, s * 0.4, s * 0.5, s * 0.48, s * 0.58, s * 0.06, WHITE)
	line(canvas, s * 0.48, s * 0.58, s * 0.62, s * 0.4, s * 0.06, WHITE)
	return canvas
end

--- A lightning bolt, for hatch speed-ups.
function Icons.speed(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, GOLD_TOP, GOLD_BOTTOM, GOLD_BORDER)
	local bolt: { { number } } = {
		{ 0.64, 0.16 },
		{ 0.3, 0.55 },
		{ 0.48, 0.55 },
		{ 0.38, 0.86 },
		{ 0.7, 0.45 },
		{ 0.52, 0.45 },
	}
	local absolute = scaledPoints(bolt, s)
	polygon(canvas, offsetPoints(absolute, s * 0.035, s * 0.04), { r = 0.3, g = 0.2, b = 0.02, a = 0.55 })
	polygon(canvas, absolute, WHITE)
	return canvas
end

--- A four-leaf clover, for luck boosts.
function Icons.luck(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, GREEN_TOP, GREEN_BOTTOM, GREEN_BORDER)
	local leaf: Pixels.Color = { r = 1, g = 1, b = 1, a = 1 }
	canvas:circle(s * 0.38, s * 0.4, s * 0.115, leaf, true)
	canvas:circle(s * 0.62, s * 0.4, s * 0.115, leaf, true)
	canvas:circle(s * 0.38, s * 0.62, s * 0.115, leaf, true)
	canvas:circle(s * 0.62, s * 0.62, s * 0.115, leaf, true)
	canvas:circle(s * 0.5, s * 0.5, s * 0.07, { r = 0.3, g = 0.7, b = 0.35, a = 1 }, true)
	line(canvas, s * 0.5, s * 0.62, s * 0.43, s * 0.84, s * 0.05, { r = 0.3, g = 0.7, b = 0.35, a = 1 })
	return canvas
end

--- A padlock, for the auto-lock product.
function Icons.lock(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, SLATE_TOP, SLATE_BOTTOM, SLATE_BORDER)
	local keyhole: Pixels.Color = { r = 0.24, g = 0.27, b = 0.36, a = 1 }
	arc(canvas, s * 0.5, s * 0.5, s * 0.14, s * 0.08, -math.pi, 0, WHITE)
	canvas:roundRect(s * 0.3, s * 0.48, s * 0.4, s * 0.32, s * 0.06, WHITE)
	canvas:circle(s * 0.5, s * 0.6, s * 0.05, keyhole, true)
	canvas:rect(s * 0.475, s * 0.6, s * 0.05, s * 0.1, keyhole)
	return canvas
end

--- A crown, for the VIP slot pass.
function Icons.vip(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, PURPLE_TOP, PURPLE_BOTTOM, PURPLE_BORDER)
	polygon(canvas, { { s * 0.28, s * 0.56 }, { s * 0.3, s * 0.3 }, { s * 0.44, s * 0.52 } }, WHITE)
	polygon(canvas, { { s * 0.42, s * 0.56 }, { s * 0.5, s * 0.24 }, { s * 0.58, s * 0.56 } }, WHITE)
	polygon(canvas, { { s * 0.56, s * 0.52 }, { s * 0.7, s * 0.3 }, { s * 0.72, s * 0.56 } }, WHITE)
	canvas:roundRect(s * 0.28, s * 0.54, s * 0.44, s * 0.14, s * 0.04, WHITE)
	canvas:circle(s * 0.36, s * 0.61, s * 0.03, { r = 0.45, g = 0.85, b = 1, a = 1 }, true)
	canvas:circle(s * 0.5, s * 0.61, s * 0.035, { r = 1, g = 0.83, b = 0.3, a = 1 }, true)
	canvas:circle(s * 0.64, s * 0.61, s * 0.03, { r = 0.45, g = 0.85, b = 1, a = 1 }, true)
	canvas:circle(s * 0.5, s * 0.22, s * 0.04, { r = 1, g = 0.83, b = 0.3, a = 1 }, true)
	return canvas
end

local function coinAt(canvas: Pixels.Canvas, cx: number, cy: number, radius: number): ()
	local dark: Pixels.Color = { r = 0.62, g = 0.38, b = 0.04, a = 1 }
	local mid: Pixels.Color = { r = 0.98, g = 0.78, b = 0.22, a = 1 }
	local bright: Pixels.Color = { r = 1, g = 0.95, b = 0.6, a = 1 }
	canvas:circle(cx, cy, radius, dark, true)
	canvas:circle(cx, cy, radius * 0.78, mid, true)
	canvas:ring(cx, cy, radius * 0.9, bright, radius * 0.14)
	diamond(canvas, cx, cy, radius * 0.4, bright)
end

--- Two stacked coins, for the 2x coins pass.
function Icons.coins2x(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, GREEN_TOP, GREEN_BOTTOM, GREEN_BORDER)
	coinAt(canvas, s * 0.4, s * 0.6, s * 0.17)
	coinAt(canvas, s * 0.6, s * 0.42, s * 0.17)
	return canvas
end

--- A generic hexagon token, deliberately not the Roblox mark.
function Icons.robux(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, BLUE_TOP, BLUE_BOTTOM, BLUE_BORDER)
	local hex: { { number } } = {}
	for i = 0, 5 do
		local angle = -math.pi / 2 + i * math.pi / 3
		table.insert(hex, { s * 0.5 + math.cos(angle) * s * 0.3, s * 0.52 + math.sin(angle) * s * 0.3 })
	end
	polygon(canvas, hex, WHITE)
	polygon(canvas, scalePoints(hex, s * 0.5, s * 0.52, 0.7), { r = 0.16, g = 0.42, b = 0.55, a = 1 })
	diamond(canvas, s * 0.5, s * 0.52, s * 0.12, WHITE)
	return canvas
end

--- A trophy, for the guaranteed kaiju pack.
function Icons.trophy(size: number?): Pixels.Canvas
	local s = expectSize(size)
	local canvas = Pixels.new(s, s)
	plate(canvas, s, GOLD_TOP, GOLD_BOTTOM, GOLD_BORDER)
	canvas:roundRect(s * 0.36, s * 0.26, s * 0.28, s * 0.22, s * 0.06, WHITE)
	polygon(
		canvas,
		{ { s * 0.36, s * 0.44 }, { s * 0.64, s * 0.44 }, { s * 0.56, s * 0.6 }, { s * 0.44, s * 0.6 } },
		WHITE
	)
	arc(canvas, s * 0.36, s * 0.34, s * 0.1, s * 0.045, math.pi / 2, math.pi * 1.5, WHITE)
	arc(canvas, s * 0.64, s * 0.34, s * 0.1, s * 0.045, -math.pi / 2, math.pi / 2, WHITE)
	canvas:rect(s * 0.47, s * 0.6, s * 0.06, s * 0.1, WHITE)
	canvas:roundRect(s * 0.36, s * 0.7, s * 0.28, s * 0.07, s * 0.03, WHITE)
	diamond(canvas, s * 0.5, s * 0.35, s * 0.05, { r = 1, g = 0.8, b = 0.25, a = 1 })
	return canvas
end

local GENERATORS: { [string]: (number?) -> Pixels.Canvas } = {
	raid = Icons.raid,
	merge = Icons.merge,
	store = Icons.store,
	odds = Icons.odds,
	invite = Icons.invite,
	quest = Icons.quest,
	menu = Icons.menu,
	shield = Icons.shield,
	speed = Icons.speed,
	luck = Icons.luck,
	lock = Icons.lock,
	vip = Icons.vip,
	coins2x = Icons.coins2x,
	robux = Icons.robux,
	trophy = Icons.trophy,
	coin = Icons.coin,
}

--- Paints one named glyph, or nil for an unknown kind. Every key of
--- Icons.kinds() is a pure (number?) -> Canvas painter.
function Icons.glyph(kind: string, size: number?): Pixels.Canvas?
	local painter = GENERATORS[kind]
	if painter == nil then
		return nil
	end
	return painter(size)
end

--- Sorted list of every glyph key accepted by Icons.glyph.
function Icons.kinds(): { string }
	local keys: { string } = {}
	for key in pairs(GENERATORS) do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

return Icons
