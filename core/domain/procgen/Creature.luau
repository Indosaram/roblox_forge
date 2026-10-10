--!strict
-- Creature: deterministic procedural creature meshes for the framework's four
-- archetypes, in a chibi toy-kaiju art direction. Pure Luau (no Roblox APIs, no
-- math.random).
--
-- Every archetype's organic core (body, head, neck, limbs, tail) is one smooth
-- MeshBuilder.skinned surface over a smooth-min union SDF, so the creature reads
-- as a single continuous vinyl toy rather than a pile of segments. The head is
-- deliberately 40-55% of the body height and pinched off the torso by a thin
-- neck, so a head is obvious at play distance. Big glossy eyes (white sclera +
-- near-black pupil + white specular highlight), accent spikes/fins/horns,
-- snouts and mouths stay crisp separate primitives on top and keep their colour
-- regardless of the pack palette. The marching resolution is reduced until the
-- combined mesh fits the spec's polyBudget.

local MeshBuilder = require("./MeshBuilder")

local Creature = {}

export type Archetype = "quad" | "serpent" | "titan" | "biped"

export type Spec = {
	archetype: Archetype,
	scale: number,
	body: MeshBuilder.Color,
	accent: MeshBuilder.Color,
	eye: MeshBuilder.Color,
	polyBudget: number,
}

type Builder = MeshBuilder.Builder
type Rng = () -> number
type Vec3 = MeshBuilder.Vec3
type Color = MeshBuilder.Color
type Primitive = MeshBuilder.Primitive

local MAX_RESOLUTION = 48
local MIN_RESOLUTION = 5
local ACCENT_SEGMENTS = 8
local EYE_SEGMENTS = 12
local PUPIL_SEGMENTS = 10
local HIGHLIGHT_SEGMENTS = 6
local BELLY_LIGHTEN = 0.35
local BELLY_ACCENT = 0.35

-- Eyes are palette-independent: white sclera, near-black pupil, white glint.
local SCLERA: Color = { r = 1, g = 1, b = 1 }
local PUPIL: Color = { r = 0.05, g = 0.05, b = 0.08 }

local ARCHETYPES: { [string]: boolean } = {
	quad = true,
	serpent = true,
	titan = true,
	biped = true,
}

local function vec(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

local function mix(a: Color, b: Color, t: number): Color
	return { r = a.r + (b.r - a.r) * t, g = a.g + (b.g - a.g) * t, b = a.b + (b.b - a.b) * t }
end

local function lighten(color: Color, t: number): Color
	return mix(color, { r = 1, g = 1, b = 1 }, t)
end

local function darken(color: Color, t: number): Color
	return mix(color, { r = 0, g = 0, b = 0 }, t)
end

local function ellipsoid(center: Vec3, radii: Vec3, color: Color): Primitive
	return { kind = "ellipsoid", center = center, radii = radii, color = color }
end

local function capsule(a: Vec3, b: Vec3, radius: number, color: Color): Primitive
	return { kind = "capsule", a = a, b = b, radius = radius, color = color }
end

local function cone(base: Vec3, tip: Vec3, radius: number, color: Color): Primitive
	return { kind = "cone", base = base, tip = tip, radius = radius, color = color }
end

local function validate(spec: Spec): ()
	if type(spec) ~= "table" then
		error("invalid spec")
	end
	if not ARCHETYPES[spec.archetype] then
		error("invalid archetype")
	end
	if type(spec.scale) ~= "number" or spec.scale ~= spec.scale or spec.scale <= 0 or spec.scale == math.huge then
		error("invalid scale")
	end
	if
		type(spec.polyBudget) ~= "number"
		or spec.polyBudget ~= spec.polyBudget
		or spec.polyBudget < 1
		or spec.polyBudget == math.huge
	then
		error("invalid polyBudget")
	end
end

-- Lighter, accent-tinted belly the skinned surface paints onto down-facing
-- faces, matching the darker back gradient baked in MeshBuilder.shadeVertex.
local function bellyTint(body: Color, accent: Color): Color
	return mix(lighten(body, BELLY_LIGHTEN), accent, BELLY_ACCENT)
end

-- Full gloss on a real kaiju budget; a cheaper but still readable face when the
-- mesh has to squeeze under a small budget.
local FULL_DETAIL_BUDGET = 1500

local function eyeDetail(budget: number): (number, number, number)
	if budget >= FULL_DETAIL_BUDGET then
		return EYE_SEGMENTS, PUPIL_SEGMENTS, HIGHLIGHT_SEGMENTS
	end
	return 5, 4, 3
end

local function accentDetail(budget: number): number
	if budget >= FULL_DETAIL_BUDGET then
		return ACCENT_SEGMENTS
	end
	return 5
end

-- Two big glossy eyes on the front of a head sphere of radius `headRadius`. The
-- eye radius is ~18% of the head's width, and the sclera is pushed out along
-- +z so it bulges proud of the muzzle instead of sinking into it.
--
-- The pupil is a rounded lens centred forward of the sclera's own centre so its
-- whole rim clears the sclera surface. An older build sank a near-sphere into
-- the sclera with only its nose poking out; the sclera's coarse facets there
-- pierced that nose in a star, which is what read as a '+' cross. Keeping the
-- pupil proud of the sclera removes the intersection entirely.
local function addEyes(
	b: Builder,
	head: Vec3,
	headRadius: number,
	scleraSeg: number,
	pupilSeg: number,
	glintSeg: number
): ()
	local eyeRadius = headRadius * 0.36
	local spread = headRadius * 0.44
	local forward = headRadius * 0.85
	for _, side in { -1, 1 } do
		local cx = head.x + side * spread
		local cy = head.y - headRadius * 0.04
		local cz = head.z + forward
		b:addEllipsoid(vec(cx, cy, cz), vec(eyeRadius, eyeRadius * 1.06, eyeRadius * 0.98), SCLERA, scleraSeg)
		-- Rounded pupil lens, centred on the sclera and pushed forward so its
		-- full rim stays outside the sclera instead of intersecting it.
		b:addEllipsoid(
			vec(cx, cy, cz + eyeRadius * 0.9),
			vec(eyeRadius * 0.5, eyeRadius * 0.54, eyeRadius * 0.3),
			PUPIL,
			pupilSeg
		)
		-- White specular highlight riding on the pupil's upper inner corner.
		b:addEllipsoid(
			vec(cx - side * eyeRadius * 0.18, cy + eyeRadius * 0.22, cz + eyeRadius * 1.02),
			vec(eyeRadius * 0.15, eyeRadius * 0.15, eyeRadius * 0.13),
			SCLERA,
			glintSeg
		)
	end
end

-- A small dark mouth line sitting just proud of a snout centered at `snout`.
local function addMouth(b: Builder, snout: Vec3, width: number): ()
	b:addEllipsoid(snout, vec(width, width * 0.28, width * 0.7), PUPIL, 5)
end

local function buildQuad(b: Builder, spec: Spec, resolution: number, rng: Rng): ()
	local s = spec.scale
	local body = spec.body
	local accent = spec.accent
	local accentSeg = accentDetail(spec.polyBudget)
	local scleraSeg, pupilSeg, glintSeg = eyeDetail(spec.polyBudget)
	local head = vec(0, 1.82 * s, 0.62 * s)
	local snout = vec(0, 1.6 * s, 1.24 * s)
	local prims: { Primitive } = {
		ellipsoid(vec(0, 0.98 * s, -0.05 * s), vec(0.6 * s, 0.5 * s, 0.82 * s), body),
		-- thin neck so the head reads as a separate chibi head
		capsule(vec(0, 1.28 * s, 0.28 * s), vec(0, 1.62 * s, 0.5 * s), 0.23 * s, body),
		ellipsoid(head, vec(0.52 * s, 0.5 * s, 0.54 * s), body),
		ellipsoid(vec(0, 1.66 * s, 1.02 * s), vec(0.27 * s, 0.2 * s, 0.28 * s), body),
		-- fat tapering tail
		capsule(vec(0, 0.96 * s, -0.7 * s), vec(0, 0.86 * s, -1.28 * s), 0.34 * s, body),
		capsule(vec(0, 0.86 * s, -1.28 * s), vec(0, 0.72 * s, -1.72 * s), 0.22 * s, body),
		cone(vec(0, 0.72 * s, -1.72 * s), vec(0, 0.62 * s, -2.12 * s), 0.18 * s, body),
	}
	for _, side in { -1, 1 } do
		for _, z in { 0.42 * s, -0.42 * s } do
			table.insert(
				prims,
				capsule(vec(side * 0.42 * s, 0.78 * s, z), vec(side * 0.5 * s, 0.16 * s, z + 0.04 * s), 0.25 * s, body)
			)
			table.insert(
				prims,
				ellipsoid(vec(side * 0.5 * s, 0.14 * s, z + 0.1 * s), vec(0.3 * s, 0.15 * s, 0.36 * s), body)
			)
		end
	end
	b:addMesh(MeshBuilder.skinned(prims, resolution, { bellyColor = bellyTint(body, accent) }))

	-- Accent back spikes, roughly double the old size.
	local spikes = 4 + math.floor(rng() * 2)
	for i = 1, spikes do
		local t = (i - 0.5) / spikes
		local z = (0.5 - 1.1 * t) * s
		local baseY = (1.42 - 0.1 * (2 * t - 1) ^ 2) * s
		local h = (0.55 + 0.24 * rng()) * s
		b:addCone(vec(0, baseY, z), vec(0, baseY + h, z - 0.12 * s), 0.23 * s, accent, accentSeg)
	end
	b:addCone(vec(0, 2.16 * s, 0.44 * s), vec(0, 2.66 * s, 0.28 * s), 0.13 * s, accent, accentSeg)
	addMouth(b, snout, 0.13 * s)
	addEyes(b, head, 0.52 * s, scleraSeg, pupilSeg, glintSeg)
end

local function buildSerpent(b: Builder, spec: Spec, resolution: number, rng: Rng): ()
	local s = spec.scale
	local body = spec.body
	local accent = spec.accent
	local scleraSeg, pupilSeg, glintSeg = eyeDetail(spec.polyBudget)
	local span = (3.4 + rng() * 0.5) * s
	local amplitude = (0.5 + rng() * 0.2) * s
	local phase = rng() * math.pi * 2
	local count = 13

	-- 1.5 S-curves of horizontal undulation with the head end reared up.
	local function spine(t: number): Vec3
		return vec(amplitude * math.sin(t * math.pi * 3 + phase), (0.62 + 0.95 * (1 - t) ^ 2) * s, (0.5 - t) * span)
	end

	local prims: { Primitive } = {}
	local prevPoint: Vec3? = nil
	local prevRadius = 0
	for k = 1, count do
		local t = (k - 1) / (count - 1)
		local p = spine(t)
		-- Body radius stays >= 30% of the head radius: a thick toy snake, not a worm.
		local radius = (0.3 - 0.1 * t) * s
		if prevPoint ~= nil then
			table.insert(prims, capsule(prevPoint, p, (prevRadius + radius) * 0.5, body))
		end
		prevPoint = p
		prevRadius = radius
	end

	local headStart = spine(0)
	local head = vec(headStart.x, headStart.y + 0.12 * s, headStart.z + 0.55 * s)
	table.insert(prims, ellipsoid(head, vec(0.6 * s, 0.58 * s, 0.66 * s), body))
	table.insert(
		prims,
		ellipsoid(
			vec(headStart.x, headStart.y - 0.28 * s, headStart.z + 0.78 * s),
			vec(0.44 * s, 0.24 * s, 0.46 * s),
			darken(mix(body, accent, 0.25), 0.18)
		)
	)
	local tail = spine(1)
	table.insert(
		prims,
		cone(vec(tail.x, tail.y, tail.z), vec(tail.x, tail.y - 0.08 * s, tail.z - 0.55 * s), 0.16 * s, body)
	)
	b:addMesh(MeshBuilder.skinned(prims, resolution, { bellyColor = bellyTint(body, accent) }))

	-- Accent dorsal fins along the back plus head frills and a tail fin.
	local fins = 5
	for i = 1, fins do
		local t = 0.08 + (i - 1) * 0.17
		local p = spine(t)
		local rr = (0.3 - 0.1 * t) * s
		local h = (0.36 + 0.18 * rng()) * s
		b:addEllipsoid(vec(p.x, p.y + rr + h * 0.4, p.z), vec(0.05 * s, h * 0.5, 0.2 * s), accent, 5)
	end
	for _, side in { -1, 1 } do
		b:addEllipsoid(
			vec(head.x + side * 0.52 * s, head.y + 0.06 * s, head.z - 0.14 * s),
			vec(0.05 * s, 0.3 * s, 0.26 * s),
			accent,
			5
		)
	end
	b:addEllipsoid(vec(tail.x, tail.y + 0.24 * s, tail.z - 0.28 * s), vec(0.05 * s, 0.3 * s, 0.2 * s), accent, 5)
	addEyes(b, head, 0.6 * s, scleraSeg, pupilSeg, glintSeg)
end

local function buildTitan(b: Builder, spec: Spec, resolution: number, rng: Rng): ()
	local s = spec.scale
	local body = spec.body
	local accent = spec.accent
	local accentSeg = accentDetail(spec.polyBudget)
	local scleraSeg, pupilSeg, glintSeg = eyeDetail(spec.polyBudget)
	local head = vec(0, 2.78 * s, 0.12 * s)
	local snout = vec(0, 2.42 * s, 0.94 * s)
	local prims: { Primitive } = {
		ellipsoid(vec(0, 1.55 * s, 0), vec(0.88 * s, 0.72 * s, 0.64 * s), body),
		capsule(vec(0, 2.12 * s, 0.02 * s), vec(0, 2.36 * s, 0.08 * s), 0.4 * s, body),
		ellipsoid(head, vec(0.72 * s, 0.7 * s, 0.74 * s), body),
		ellipsoid(vec(0, 2.5 * s, 0.6 * s), vec(0.34 * s, 0.26 * s, 0.34 * s), body),
		capsule(vec(0, 1.35 * s, -0.45 * s), vec(0, 1.0 * s, -1.05 * s), 0.42 * s, body),
		capsule(vec(0, 1.0 * s, -1.05 * s), vec(0, 0.82 * s, -1.5 * s), 0.24 * s, body),
		cone(vec(0, 0.82 * s, -1.5 * s), vec(0, 0.72 * s, -1.85 * s), 0.18 * s, body),
	}
	local lean = (rng() - 0.5) * 0.16
	for _, side in { -1, 1 } do
		-- stubby thick legs and feet
		table.insert(
			prims,
			capsule(vec(side * 0.44 * s, 0.95 * s, 0), vec(side * 0.48 * s, 0.2 * s, 0.04 * s), 0.33 * s, body)
		)
		table.insert(prims, ellipsoid(vec(side * 0.5 * s, 0.16 * s, 0.28 * s), vec(0.4 * s, 0.18 * s, 0.52 * s), body))
		-- arms
		table.insert(
			prims,
			capsule(
				vec(side * 0.72 * s, 1.9 * s, 0.02 * s),
				vec(side * (1.0 + lean) * s, 1.05 * s, 0.3 * s),
				0.24 * s,
				body
			)
		)
		table.insert(
			prims,
			ellipsoid(vec(side * (1.06 + lean) * s, 1.0 * s, 0.36 * s), vec(0.28 * s, 0.24 * s, 0.3 * s), body)
		)
	end
	b:addMesh(MeshBuilder.skinned(prims, resolution, { bellyColor = bellyTint(body, accent) }))

	local hornSpread = 0.3 + rng() * 0.12
	for _, side in { -1, 1 } do
		b:addCone(
			vec(side * 0.32 * s, 3.28 * s, 0.02 * s),
			vec(side * (0.32 + hornSpread) * s, 3.95 * s, -0.2 * s),
			0.16 * s,
			accent,
			accentSeg
		)
	end

	local plates = 4
	for i = 1, plates do
		local t = (i - 0.5) / plates
		local z = (0.28 - 0.95 * t) * s
		local y = (2.2 - 0.5 * t) * s
		local h = (0.42 + 0.2 * rng()) * s
		b:addCone(vec(0, y, z), vec(0, y + h, z - 0.14 * s), 0.22 * s, accent, accentSeg)
	end
	addMouth(b, snout, 0.2 * s)
	addEyes(b, head, 0.72 * s, scleraSeg, pupilSeg, glintSeg)
end

local function buildBiped(b: Builder, spec: Spec, resolution: number, rng: Rng): ()
	local s = spec.scale
	local body = spec.body
	local accent = spec.accent
	local accentSeg = accentDetail(spec.polyBudget)
	local scleraSeg, pupilSeg, glintSeg = eyeDetail(spec.polyBudget)
	local head = vec(0, 1.95 * s, 0.12 * s)
	local snout = vec(0, 1.72 * s, 0.66 * s)
	local prims: { Primitive } = {
		ellipsoid(vec(0, 1.15 * s, 0), vec(0.6 * s, 0.55 * s, 0.52 * s), body),
		capsule(vec(0, 1.5 * s, 0.02 * s), vec(0, 1.66 * s, 0.06 * s), 0.28 * s, body),
		ellipsoid(head, vec(0.5 * s, 0.5 * s, 0.52 * s), body),
		ellipsoid(vec(0, 1.8 * s, 0.5 * s), vec(0.24 * s, 0.18 * s, 0.24 * s), body),
		capsule(vec(0, 0.95 * s, -0.42 * s), vec(0, 0.62 * s, -1.05 * s), 0.24 * s, body),
		cone(vec(0, 0.62 * s, -1.05 * s), vec(0, 0.54 * s, -1.35 * s), 0.14 * s, body),
	}
	local armSpread = 0.1 + rng() * 0.18
	for _, side in { -1, 1 } do
		table.insert(
			prims,
			capsule(vec(side * 0.24 * s, 0.72 * s, 0), vec(side * 0.28 * s, 0.16 * s, 0.03 * s), 0.22 * s, body)
		)
		table.insert(prims, ellipsoid(vec(side * 0.3 * s, 0.14 * s, 0.16 * s), vec(0.26 * s, 0.14 * s, 0.34 * s), body))
		table.insert(
			prims,
			capsule(
				vec(side * 0.5 * s, 1.3 * s, 0),
				vec(side * (0.62 + armSpread) * s, 0.92 * s, 0.1 * s),
				0.14 * s,
				body
			)
		)
		table.insert(
			prims,
			ellipsoid(vec(side * (0.66 + armSpread) * s, 0.88 * s, 0.12 * s), vec(0.16 * s, 0.14 * s, 0.18 * s), body)
		)
	end
	b:addMesh(MeshBuilder.skinned(prims, resolution, { bellyColor = bellyTint(body, accent) }))

	for _, side in { -1, 1 } do
		b:addCone(
			vec(side * 0.18 * s, 2.32 * s, 0.0 * s),
			vec(side * 0.3 * s, 2.72 * s, -0.1 * s),
			0.1 * s,
			accent,
			accentSeg
		)
	end
	addMouth(b, snout, 0.12 * s)
	addEyes(b, head, 0.5 * s, scleraSeg, pupilSeg, glintSeg)
end

local BUILDERS: { [string]: (Builder, Spec, number, Rng) -> () } = {
	quad = buildQuad,
	serpent = buildSerpent,
	titan = buildTitan,
	biped = buildBiped,
}

function Creature.generate(spec: Spec, seed: number): MeshBuilder.MeshData
	validate(spec)
	local build = BUILDERS[spec.archetype]
	if build == nil then
		error("invalid archetype")
	end
	local function fits(resolution: number): boolean
		local builder = MeshBuilder.new()
		build(builder, spec, resolution, MeshBuilder.rng(seed))
		return builder:build().triangleCount <= spec.polyBudget
	end

	-- Triangle count grows with resolution, so binary-search the finest grid
	-- that still fits the budget instead of rebuilding every resolution.
	local lo, hi = MIN_RESOLUTION, MAX_RESOLUTION
	local best: number? = nil
	while lo <= hi do
		local mid = (lo + hi) // 2
		if fits(mid) then
			best = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end

	local builder = MeshBuilder.new()
	build(builder, spec, best or MIN_RESOLUTION, MeshBuilder.rng(seed))
	local mesh = builder:build()
	-- Even the coarsest resolution the binary search tried (MIN_RESOLUTION,
	-- when `best` never fit) can still exceed polyBudget for a tiny budget.
	-- Flag it instead of silently handing back an over-budget mesh.
	if mesh.triangleCount > spec.polyBudget then
		mesh.overBudget = true
	end
	return mesh
end

return Creature
