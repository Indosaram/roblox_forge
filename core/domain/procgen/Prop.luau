--!strict
-- Prop: deterministic procedural prop meshes (egg, crystal, rock, tree, crate).
-- Pure Luau (no Roblox APIs, no math.random). Uses MeshBuilder and reduces the
-- tessellation density until the mesh fits the spec's polyBudget.

local MeshBuilder = require("./MeshBuilder")

local Prop = {}

export type Kind = "egg" | "crystal" | "rock" | "tree" | "crate"

export type Spec = {
	scale: number,
	body: MeshBuilder.Color,
	accent: MeshBuilder.Color,
	-- Leaf colour for the tree canopy. Optional so old packs keep a green tree.
	foliage: MeshBuilder.Color?,
	polyBudget: number,
}

type Builder = MeshBuilder.Builder
type Rng = () -> number

local MAX_SEGMENTS = 24
local MIN_SEGMENTS = 3

local function vec(x: number, y: number, z: number): MeshBuilder.Vec3
	return { x = x, y = y, z = z }
end

-- Fresh green (90, 170, 70) the tree falls back to when the spec omits foliage.
local DEFAULT_FOLIAGE: MeshBuilder.Color = { r = 90 / 255, g = 170 / 255, b = 70 / 255 }

local function mix(a: MeshBuilder.Color, b: MeshBuilder.Color, t: number): MeshBuilder.Color
	return {
		r = a.r + (b.r - a.r) * t,
		g = a.g + (b.g - a.g) * t,
		b = a.b + (b.b - a.b) * t,
	}
end

local function lighten(color: MeshBuilder.Color, t: number): MeshBuilder.Color
	return mix(color, { r = 1, g = 1, b = 1 }, t)
end

local function darken(color: MeshBuilder.Color, t: number): MeshBuilder.Color
	return mix(color, { r = 0, g = 0, b = 0 }, t)
end

local function clamp01(value: number): number
	if value < 0 then
		return 0
	elseif value > 1 then
		return 1
	end
	return value
end

-- Replaces the skinned surface's baked vertical shading with a ramp that runs
-- dark at the bottom to light at the top (foliage), while keeping its per-vertex
-- crease occlusion. The bake is a scalar times the base colour, so the baked red
-- channel divided by the base red recovers that scalar.
local function retintVertical(
	mesh: MeshBuilder.MeshData,
	base: MeshBuilder.Color,
	low: MeshBuilder.Color,
	high: MeshBuilder.Color
): ()
	local minY = mesh.bounds.min.y
	local span = mesh.bounds.max.y - minY
	if span <= 1e-9 or base.r <= 1e-9 then
		return
	end
	for index = 1, #mesh.colors do
		local shade = mesh.colors[index].r / base.r
		local target = mix(low, high, (mesh.vertices[index].y - minY) / span)
		mesh.colors[index] = {
			r = clamp01(target.r * shade),
			g = clamp01(target.g * shade),
			b = clamp01(target.b * shade),
		}
	end
end

local function validate(spec: Spec): ()
	if type(spec) ~= "table" then
		error("invalid spec")
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

-- A smooth, taller-than-wide egg (1.3:1) with a zigzag band of accent spots.
-- The body alone is 528 triangles at 24 segments, so the CLI's segment search
-- keeps the full smooth tessellation and spends the remaining budget on spots.
local function buildEgg(b: Builder, spec: Spec, seg: number, rng: Rng): ()
	local s = spec.scale
	local rx = 0.66 * s
	local ry = rx * 1.3
	local centerY = ry + 0.05 * s
	b:addEllipsoid(vec(0, centerY, 0), vec(rx, ry, rx), spec.body, seg)

	-- Zigzag band of accent spots around the shoulders, not a polar crown.
	local spots = 8 + math.floor(rng() * 2)
	for i = 1, spots do
		local theta = (i - 0.5) / spots * math.pi * 2 + rng() * 0.15
		local phi = (if i % 2 == 0 then 0.98 else 0.74) + rng() * 0.08
		local spot = vec(
			rx * math.cos(theta) * math.sin(phi),
			centerY + ry * math.cos(phi),
			rx * math.sin(theta) * math.sin(phi)
		)
		b:addEllipsoid(spot, vec(0.11 * s, 0.11 * s, 0.11 * s), spec.accent, 4)
	end
end

local function buildCrystal(b: Builder, spec: Spec, seg: number, rng: Rng): ()
	local s = spec.scale
	b:addEllipsoid(vec(0, 0.25 * s, 0), vec(0.55 * s, 0.3 * s, 0.55 * s), spec.body, math.max(4, seg - 2))

	local shards = 3 + math.floor(rng() * 3)
	for i = 1, shards do
		local angle = (i - 1) / shards * math.pi * 2 + rng() * 0.3
		local radius = (0.12 + rng() * 0.25) * s
		local base = vec(math.cos(angle) * radius, 0.35 * s, math.sin(angle) * radius)
		local height = (0.9 + rng() * 0.9) * s
		local lean = (rng() - 0.5) * 0.4 * s
		local color = if i % 2 == 0 then spec.accent else spec.body
		b:addCone(base, vec(base.x + lean, base.y + height, base.z + lean * 0.5), (0.13 + rng() * 0.1) * s, color, seg)
	end
end

-- Two or three merged stone lumps on a flat base, each a slightly different
-- grey, with a moss cap in the accent colour growing on top.
local function buildRock(b: Builder, spec: Spec, seg: number, rng: Rng): ()
	local s = spec.scale
	local lumps = 2 + math.floor(rng() * 2)
	local mossSeg = math.max(4, math.floor(seg * 0.6))
	local tops: { { x: number, y: number, z: number, rx: number, ry: number, rz: number } } = {}
	for i = 1, lumps do
		local ox = (rng() - 0.5) * 0.5 * s
		local oz = (rng() - 0.5) * 0.5 * s
		local rx = (0.42 + rng() * 0.24) * s
		local rz = (0.42 + rng() * 0.24) * s
		local ry = (0.28 + rng() * 0.12) * s
		local cy = ry * 0.95
		local tone = if i % 2 == 0 then lighten(spec.body, 0.09) else darken(spec.body, 0.1)
		b:addEllipsoid(vec(ox, cy, oz), vec(rx, ry, rz), tone, seg)
		table.insert(tops, { x = ox, y = cy, z = oz, rx = rx, ry = ry, rz = rz })
	end
	-- A wide, shallow slab flattens the base so the rock sits stably.
	b:addEllipsoid(vec(0, 0.1 * s, 0), vec(0.68 * s, 0.14 * s, 0.68 * s), darken(spec.body, 0.22), math.max(4, seg - 2))
	-- Moss caps the top of every lump in the accent colour.
	for _, lump in tops do
		b:addEllipsoid(
			vec(lump.x, lump.y + lump.ry * 0.62, lump.z),
			vec(lump.rx * 0.72, lump.ry * 0.5, lump.rz * 0.72),
			spec.accent,
			mossSeg
		)
	end
end

-- A tapered trunk with two branch stubs under a domed canopy of overlapping leaf
-- clusters skinned into one soft mass. The crown is tinted from a deep green at
-- the bottom to a lighter green at the top.
local function buildTree(b: Builder, spec: Spec, seg: number, rng: Rng): ()
	local s = spec.scale
	local bark = spec.body
	local foliage = spec.foliage or DEFAULT_FOLIAGE

	-- Tapered trunk: a rounded cone that widens to the root and narrows on top.
	b:addCone(vec(0, 0, 0), vec(0, 1.7 * s, 0), 0.2 * s, bark, seg)

	-- Two short branch stubs angling out into the canopy.
	local stubSeg = math.max(4, math.floor(seg / 2))
	for _, side in { -1, 1 } do
		local base = vec(side * 0.05 * s, (0.95 + rng() * 0.35) * s, (rng() - 0.5) * 0.2 * s)
		local reach = (0.42 + rng() * 0.18) * s
		local tip = vec(base.x + side * reach, base.y + (0.3 + rng() * 0.22) * s, base.z + (rng() - 0.5) * 0.3 * s)
		b:addCone(base, tip, 0.075 * s, bark, stubSeg)
	end

	-- Canopy: 3-5 overlapping leaf clusters skinned into one soft crown.
	local clusters = 3 + math.floor(rng() * 3)
	local canopyBottom = 1.5 * s
	local canopyHeight = 0.95 * s
	local prims: { MeshBuilder.Primitive } = {}
	for i = 1, clusters do
		local angle = (i - 1) / clusters * math.pi * 2 + rng() * 0.7
		local ring = (0.2 + rng() * 0.28) * s
		local center = vec(math.cos(angle) * ring, canopyBottom + rng() * canopyHeight, math.sin(angle) * ring)
		table.insert(prims, {
			kind = "ellipsoid",
			center = center,
			radii = vec((0.4 + rng() * 0.14) * s, (0.32 + rng() * 0.1) * s, (0.4 + rng() * 0.14) * s),
			color = foliage,
		})
	end
	local canopy = MeshBuilder.skinned(prims, math.max(3, math.floor(seg / 4)), { blend = 0.6 })
	retintVertical(canopy, foliage, darken(foliage, 0.28), lighten(foliage, 0.16))
	b:addMesh(canopy)

	-- Two or three fruit dots tucked into the foliage.
	local fruit = 2 + math.floor(rng() * 2)
	for _ = 1, fruit do
		local angle = rng() * math.pi * 2
		local radius = (0.34 + rng() * 0.16) * s
		local center = vec(math.cos(angle) * radius, (1.7 + rng() * 0.55) * s, math.sin(angle) * radius)
		b:addEllipsoid(center, vec(0.09 * s, 0.09 * s, 0.09 * s), spec.accent, 4)
	end
end

-- A closed wooden crate: a solid body box wearing four proud side panels with
-- vertical plank grooves, dark corner posts and a two-tone plank lid.
local function buildCrate(b: Builder, spec: Spec, _seg: number, rng: Rng): ()
	local s = spec.scale
	local plank = spec.body
	local trim = spec.accent
	local groove = darken(plank, 0.4)
	local lightPlank = lighten(plank, 0.1)

	-- Solid body so the crate reads closed rather than as an open frame.
	b:addBox(vec(0, 0.5 * s, 0), vec(1.0 * s, 1.0 * s, 1.0 * s), plank)

	-- Four side panels stand proud of the body, one per ±x / ±z face, with two
	-- vertical plank grooves apiece. Sizes wobble a little per seed so no two
	-- crates are identical.
	local face = 0.5 * s
	local panelT = 0.06 * s
	local panelW = (0.8 + rng() * 0.08) * s
	local panelH = (0.72 + rng() * 0.1) * s
	local panelY = 0.52 * s
	local grooveT = 0.012 * s
	local grooveAt = 0.24 + rng() * 0.1
	local grooveOut = face + panelT + grooveT * 0.4
	for _, sign in { -1, 1 } do
		b:addBox(vec(sign * (face + panelT * 0.5), panelY, 0), vec(panelT, panelH, panelW), plank)
		for _, g in { -1, 1 } do
			b:addBox(
				vec(sign * grooveOut, panelY, g * panelW * grooveAt),
				vec(grooveT, panelH * 0.88, grooveT * 1.6),
				groove
			)
		end
		b:addBox(vec(0, panelY, sign * (face + panelT * 0.5)), vec(panelW, panelH, panelT), plank)
		for _, g in { -1, 1 } do
			b:addBox(
				vec(g * panelW * grooveAt, panelY, sign * grooveOut),
				vec(grooveT * 1.6, panelH * 0.88, grooveT),
				groove
			)
		end
	end

	-- Dark corner posts frame every edge.
	local post = (0.14 + rng() * 0.04) * s
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			b:addBox(vec(sx * 0.46 * s, 0.5 * s, sz * 0.46 * s), vec(post, 1.06 * s, post), trim)
		end
	end

	-- Lid: a dark slab with lighter planks laid across the top and two dark rails.
	b:addBox(vec(0, 1.03 * s, 0), vec(1.14 * s, 0.08 * s, 1.14 * s), trim)
	local lidPlanks = 2 + math.floor(rng() * 2)
	for i = 1, lidPlanks do
		local px = (i - (lidPlanks + 1) / 2) * 0.34 * s
		b:addBox(vec(px, 1.08 * s, 0), vec(0.32 * s, 0.04 * s, 1.16 * s), lightPlank)
	end
	for _, sz in { -1, 1 } do
		b:addBox(vec(0, 1.09 * s, sz * 0.46 * s), vec(1.16 * s, 0.05 * s, 0.1 * s), trim)
	end
end

local BUILDERS: { [string]: (Builder, Spec, number, Rng) -> () } = {
	egg = buildEgg,
	crystal = buildCrystal,
	rock = buildRock,
	tree = buildTree,
	crate = buildCrate,
}

function Prop.generate(kind: Kind, spec: Spec, seed: number): MeshBuilder.MeshData
	validate(spec)
	local build = BUILDERS[kind]
	if build == nil then
		error("invalid kind")
	end
	for segments = MAX_SEGMENTS, MIN_SEGMENTS, -1 do
		local builder = MeshBuilder.new()
		build(builder, spec, segments, MeshBuilder.rng(seed))
		local mesh = builder:build()
		if mesh.triangleCount <= spec.polyBudget then
			return mesh
		end
	end
	local builder = MeshBuilder.new()
	build(builder, spec, MIN_SEGMENTS, MeshBuilder.rng(seed))
	local mesh = builder:build()
	-- Even the coarsest tessellation (MIN_SEGMENTS) can still exceed a tiny
	-- polyBudget. Flag it instead of silently handing back an over-budget mesh.
	mesh.overBudget = true
	return mesh
end

return Prop
