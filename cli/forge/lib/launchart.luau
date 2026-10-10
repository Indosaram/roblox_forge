--!strict
-- launchart: deterministic store art for a pack. Renders two 512x512 icons and
-- two 1920x1080 thumbnails from the pack's procedural meshes with the framework
-- rasterizer plus the Pixels painters. Pure Luau (no Roblox APIs, no
-- math.random), so `forge gen launchart` writes byte-identical PNGs on every run.

local Pixels = require("../../../core/domain/procgen/Pixels")
local Icons = require("../../../core/domain/procgen/Icons")
local rasterize = require("./rasterize")
local procgen = require("./procgen")

local M = {}

-- Version of the store-art rendering recipe (this module plus the painters it
-- calls). Bump it whenever a change alters the PNG bytes a job renders to.
M.RECIPE_VERSION = "1"

export type Resolved = procgen.Resolved

local ICON_SIZE = 512
local THUMB_WIDTH = 1920
local THUMB_HEIGHT = 1080

local function rgb(r: number, g: number, b: number): Pixels.Color
	return { r = r, g = g, b = b, a = 1 }
end

local function cloneSorted(entries: { Resolved }, compare: (Resolved, Resolved) -> boolean): { Resolved }
	local sorted = table.clone(entries)
	table.sort(sorted, compare)
	return sorted
end

--- Splits resolved procgen entries into creature portrait sources and egg
--- sources, each sorted by key so a render never depends on document order.
function M.split(entries: { Resolved }): ({ Resolved }, { Resolved })
	local creatures: { Resolved } = {}
	local eggs: { Resolved } = {}
	for _, entry in entries do
		if entry.kind == "creature" then
			table.insert(creatures, entry)
		elseif entry.archetype == "egg" then
			table.insert(eggs, entry)
		end
	end
	local byKey = function(a: Resolved, b: Resolved): boolean
		return a.key < b.key
	end
	table.sort(creatures, byKey)
	table.sort(eggs, byKey)
	return creatures, eggs
end

--- Picks the rarest creature to obtain: the one with the lowest hatch weight
--- across every egg pool, breaking ties by the highest income then by key. Falls
--- back to the first creature when econ.yml has no pools.
function M.rarestKey(econDoc: any, creatures: { Resolved }): string?
	if #creatures == 0 then
		return nil
	end

	local minWeight: { [string]: number } = {}
	local income: { [string]: number } = {}
	if type(econDoc) == "table" then
		if type(econDoc.eggs) == "table" then
			for _, egg in econDoc.eggs do
				if type(egg) == "table" and type(egg.pool) == "table" then
					for _, pooled in egg.pool do
						if
							type(pooled) == "table"
							and type(pooled.id) == "string"
							and type(pooled.weight) == "number"
						then
							local current = minWeight[pooled.id]
							if current == nil or pooled.weight < current then
								minWeight[pooled.id] = pooled.weight
							end
						end
					end
				end
			end
		end
		if type(econDoc.kaiju) == "table" then
			for _, kaiju in econDoc.kaiju do
				if type(kaiju) == "table" and type(kaiju.id) == "string" then
					income[kaiju.id] = if type(kaiju.coinsPerSecond) == "number" then kaiju.coinsPerSecond else 0
				end
			end
		end
	end

	local best: string? = nil
	local bestWeight = math.huge
	for _, entry in creatures do
		local weight = minWeight[entry.key]
		if weight ~= nil then
			local gain = income[entry.key] or 0
			local bestGain = if best ~= nil then (income[best] or 0) else -1
			if
				weight < bestWeight
				or (
					weight == bestWeight
					and (gain > bestGain or (gain == bestGain and best ~= nil and entry.key < best))
				)
			then
				bestWeight = weight
				best = entry.key
			end
		end
	end
	return best or creatures[1].key
end

local function findCreature(creatures: { Resolved }, key: string?): Resolved?
	if key ~= nil then
		for _, entry in creatures do
			if entry.key == key then
				return entry
			end
		end
	end
	return creatures[1]
end

--- RGB-portrait render of one creature mesh on a transparent canvas. Raises
--- the ambient/key light over the rasterizer's defaults and adds a cool
--- fill light from the opposite side, so a creature reads clearly as a store
--- thumbnail instead of the flat art-review lighting.
local function portrait(entry: Resolved, size: number, pitch: number, margin: number): Pixels.Canvas
	local mesh = procgen.buildMesh(entry)
	return rasterize.render(mesh, {
		width = size,
		height = size,
		pitch = pitch,
		margin = margin,
		background = { r = 0, g = 0, b = 0, a = 0 },
		ambient = 0.62,
		light = { x = -0.32, y = 0.68, z = 0.72 },
		fillLight = { direction = { x = 0.55, y = 0.1, z = -0.4 }, intensity = 0.32 },
	})
end

local function radialFill(canvas: Pixels.Canvas, cx: number, cy: number, radius: number, inner: any, outer: any): ()
	for py = 0, canvas.height - 1 do
		local dy = py + 0.5 - cy
		for px = 0, canvas.width - 1 do
			local dx = px + 0.5 - cx
			local t = math.clamp(math.sqrt(dx * dx + dy * dy) / radius, 0, 1)
			canvas:set(px, py, Pixels.mix(inner, outer, t))
		end
	end
end

local function glow(canvas: Pixels.Canvas, cx: number, cy: number, radius: number, color: any): ()
	local minX = math.max(0, math.floor(cx - radius))
	local maxX = math.min(canvas.width - 1, math.ceil(cx + radius))
	local minY = math.max(0, math.floor(cy - radius))
	local maxY = math.min(canvas.height - 1, math.ceil(cy + radius))
	for py = minY, maxY do
		local dy = py + 0.5 - cy
		for px = minX, maxX do
			local dx = px + 0.5 - cx
			local distance = math.sqrt(dx * dx + dy * dy)
			if distance < radius then
				local t = 1 - distance / radius
				canvas:blend(px, py, color, t * t)
			end
		end
	end
end

--- Soft screen-space vignette: darkens toward the corners without ever going
--- near-black at the edges, so it reads as a lens falloff, not a black crop.
local function vignette(canvas: Pixels.Canvas, strength: number): ()
	local cx, cy = canvas.width * 0.5, canvas.height * 0.5
	local maxRadius = math.sqrt(cx * cx + cy * cy)
	for py = 0, canvas.height - 1 do
		local dy = py + 0.5 - cy
		for px = 0, canvas.width - 1 do
			local dx = px + 0.5 - cx
			local t = math.clamp(math.sqrt(dx * dx + dy * dy) / maxRadius, 0, 1)
			canvas:blend(px, py, { r = 0, g = 0, b = 0, a = 1 }, strength * t * t)
		end
	end
end
--- Dims a rendered portrait to `brightness` of its lit colour (instead of
--- flattening it to a near-black silhouette) and adds a strong horizontal
--- warm/cool rim: a warm tint over the canvas's left half fading to a cool
--- tint over the right half, so the creature reads as a lit figure against
--- the icon's red/blue split instead of a black blob.
local function dimAndRim(canvas: Pixels.Canvas, brightness: number, warm: Pixels.Color, cool: Pixels.Color): ()
	local data = canvas.data
	local width = canvas.width
	for py = 0, canvas.height - 1 do
		for px = 0, canvas.width - 1 do
			local i = (py * width + px) * 4 + 1
			if data[i + 3] > 0 then
				data[i] *= brightness
				data[i + 1] *= brightness
				data[i + 2] *= brightness
				-- t = 0 at the left edge (warmest) to 1 at the right edge (coolest),
				-- matching the red-left / blue-right icon split.
				local t = (px + 0.5) / width
				local rim = Pixels.mix(warm, cool, t)
				-- Strongest at the horizontal extremes, easing toward the centre so
				-- the rim reads as a directional light rather than a flat tint.
				local edge = math.abs(t - 0.5) * 2
				local rimStrength = 0.22 + 0.4 * edge
				canvas:blend(px, py, rim, rimStrength)
			end
		end
	end
end

--- Icon A: the rarest kaiju portrait over a radial team-colour field with an
--- egg in the foreground.
function M.iconA(creatures: { Resolved }, eggs: { Resolved }, rarestKey: string?): Pixels.Canvas
	local s = ICON_SIZE
	local canvas = Pixels.new(s, s)
	radialFill(canvas, s * 0.5, s * 0.42, s * 0.78, rgb(1, 0.66, 0.33), rgb(0.23, 0.03, 0.09))
	glow(canvas, s * 0.5, s * 0.52, s * 0.62, { r = 1, g = 0.62, b = 0.25, a = 0.22 })

	local creature = findCreature(creatures, rarestKey)
	if creature ~= nil then
		canvas:blit(portrait(creature, s, 0.15, 0.16), 0, 0)
	end

	local egg = eggs[1]
	if egg ~= nil then
		glow(canvas, s * 0.72, s * 0.8, s * 0.22, { r = 1, g = 0.85, b = 0.4, a = 0.4 })
		canvas:blit(Icons.egg(egg.spec, 190), s * 0.56, s * 0.6)
	end

	canvas:linearGradient(
		0,
		s * 0.82,
		s,
		s * 0.18,
		{ r = 0, g = 0, b = 0, a = 0 },
		{ r = 0.18, g = 0.05, b = 0.08, a = 0.4 }
	)
	vignette(canvas, 0.16)
	return canvas
end

--- The rarest creature's portrait as it appears behind icon B's eggs: real
--- body/accent colours dimmed to ~70% brightness with a warm rim light on
--- the red (left) side and a cool rim light on the blue (right) side, over a
--- transparent background. Exposed separately from `iconB` so specs can
--- measure the creature's own luminance without the icon's opaque
--- background gradient swamping the average.
function M.iconBCreature(creatures: { Resolved }, rarestKey: string?): Pixels.Canvas?
	local creature = findCreature(creatures, rarestKey)
	if creature == nil then
		return nil
	end
	local art = portrait(creature, ICON_SIZE, 0.16, 0.2)
	dimAndRim(art, 0.7, { r = 1, g = 0.45, b = 0.28, a = 1 }, { r = 0.32, g = 0.56, b = 1, a = 1 })
	return art
end

--- Icon B: the two eggs in front of a lit, rim-lit kaiju over a red/blue
--- split. The creature behind the eggs is the rarest one (matching iconA),
--- rendered in its real colours at ~70% brightness with a warm rim on the
--- red side and a cool rim on the blue side, so it reads as a lit figure
--- instead of a black silhouette.
function M.iconB(creatures: { Resolved }, eggs: { Resolved }, rarestKey: string?): Pixels.Canvas
	local s = ICON_SIZE
	local canvas = Pixels.new(s, s)
	canvas:linearGradient(0, 0, s * 0.5, s, rgb(0.6, 0.13, 0.17), rgb(0.16, 0.02, 0.05))
	canvas:linearGradient(s * 0.5, 0, s * 0.5, s, rgb(0.12, 0.24, 0.67), rgb(0.02, 0.05, 0.16))
	glow(canvas, s * 0.5, s * 0.46, s * 0.5, { r = 1, g = 0.86, b = 0.5, a = 0.16 })

	local art = M.iconBCreature(creatures, rarestKey)
	if art ~= nil then
		canvas:blit(art, 0, 0)
	end

	local first = eggs[1]
	local second = eggs[2] or eggs[1]
	if first ~= nil then
		canvas:blit(Icons.egg(first.spec, 210), 48, 268)
	end
	if second ~= nil then
		canvas:blit(Icons.egg(second.spec, 210), 254, 268)
	end

	canvas:linearGradient(0, s * 0.84, s, s * 0.16, { r = 0, g = 0, b = 0, a = 0 }, { r = 0, g = 0, b = 0, a = 0.28 })
	vignette(canvas, 0.14)
	return canvas
end

--- Thumbnail: all six creatures lined up in front of an arena gradient and a
--- ground plane. `variant` "a" is the red arena, "b" the blue arena. The sky
--- and ground gradients bottom out at a lit floor (never near-black) and a
--- soft vignette replaces the old hard black gradient at the frame edges, so
--- the thumbnail reads bright at store-listing size.
function M.thumbnail(creatures: { Resolved }, variant: string): Pixels.Canvas
	local w = THUMB_WIDTH
	local h = THUMB_HEIGHT
	local red = variant ~= "b"
	local canvas = Pixels.new(w, h)
	local groundY = 720

	-- The ground floor and sky bottom are lit to at least 25% of the team
	-- accent colour's luminance (red ~0.52, blue ~0.59), so the bottom of the
	-- frame never reads as near-black.
	local skyTop = if red then rgb(0.62, 0.32, 0.32) else rgb(0.3, 0.4, 0.64)
	local skyBottom = if red then rgb(0.52, 0.34, 0.34) else rgb(0.32, 0.42, 0.6)
	canvas:linearGradient(0, 0, w, groundY + 40, skyTop, skyBottom)
	glow(
		canvas,
		w * 0.5,
		groundY - 40,
		w * 0.6,
		if red then { r = 1, g = 0.55, b = 0.42, a = 0.28 } else { r = 0.55, g = 0.72, b = 1, a = 0.28 }
	)

	local groundTop = if red then rgb(0.46, 0.3, 0.3) else rgb(0.28, 0.36, 0.52)
	local groundBottom = if red then rgb(0.38, 0.26, 0.28) else rgb(0.24, 0.3, 0.46)
	canvas:linearGradient(0, groundY, w, h - groundY, groundTop, groundBottom)
	canvas:rect(
		0,
		groundY - 2,
		w,
		3,
		if red then { r = 1, g = 0.55, b = 0.42, a = 0.45 } else { r = 0.55, g = 0.72, b = 1, a = 0.45 }
	)

	local sorted = cloneSorted(creatures, function(a: Resolved, b: Resolved): boolean
		if a.spec.scale == b.spec.scale then
			return a.key < b.key
		end
		return a.spec.scale < b.spec.scale
	end)

	local count = #sorted
	if count == 0 then
		return canvas
	end

	local margin = 90
	local gap = 28
	local rawTotal = 0
	local rawSizes: { number } = {}
	for i, entry in sorted do
		local raw = 200 + 70 * entry.spec.scale
		rawSizes[i] = raw
		rawTotal += raw
	end
	local available = w - margin * 2 - gap * (count - 1)
	local factor = if rawTotal > available then available / rawTotal else 1
	local total = 0
	local sizes: { number } = {}
	for i = 1, count do
		sizes[i] = math.max(1, math.floor(rawSizes[i] * factor))
		total += sizes[i]
	end

	local baseline = groundY + 168
	local startX = margin + (available - total) / 2
	local x = startX
	for i, entry in sorted do
		local size = sizes[i]
		local cx = x + size / 2
		canvas:circle(cx, baseline + 8, size * 0.34, { r = 0, g = 0, b = 0, a = 0.35 })
		canvas:circle(cx, baseline + 4, size * 0.24, { r = 0, g = 0, b = 0, a = 0.4 })
		local body = entry.spec.body
		glow(canvas, cx, baseline - size * 0.5, size * 0.72, { r = body.r, g = body.g, b = body.b, a = 0.5 })
		x += size + gap
	end

	x = startX
	for i, entry in sorted do
		local size = sizes[i]
		canvas:blit(portrait(entry, size, 0.16, 0.1), x, baseline - size)
		x += size + gap
	end

	vignette(canvas, 0.12)
	return canvas
end

return M
