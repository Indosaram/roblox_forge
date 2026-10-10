--!strict
-- Pure geometry helpers for WorldBuilder. No Roblox APIs: every result is a
-- plain table so the same math runs under Lune for the specs.

export type Vec = { x: number, y: number, z: number }

export type Ground = {
	cells: number,
	cellSize: number,
	originX: number,
	originZ: number,
}

export type Trim = { size: Vec, position: Vec }
export type PathSpan = { size: Vec, position: Vec, yaw: number }

local WorldBuilderMath = {}

-- Center of grid cell (gx, gz); the grid grows in +x/+z from the origin corner.
function WorldBuilderMath.groundCellPosition(ground: Ground, gx: number, gz: number): { x: number, z: number }
	local half = ground.cellSize / 2
	return {
		x = ground.originX + gx * ground.cellSize + half,
		z = ground.originZ + gz * ground.cellSize + half,
	}
end

-- Checkerboard variant (1 or 2) for ground cell (gx, gz).
function WorldBuilderMath.groundCellVariant(gx: number, gz: number): number
	return ((gx + gz) % 2) + 1
end

-- Four neon trim strips along the base platform edges.
function WorldBuilderMath.platformTrims(center: Vec, half: number): { Trim }
	return {
		{ size = { x = half * 2, y = 0.4, z = 1 }, position = { x = center.x, y = 1.3, z = center.z - half } },
		{ size = { x = half * 2, y = 0.4, z = 1 }, position = { x = center.x, y = 1.3, z = center.z + half } },
		{ size = { x = 1, y = 0.4, z = half * 2 }, position = { x = center.x - half, y = 1.3, z = center.z } },
		{ size = { x = 1, y = 0.4, z = half * 2 }, position = { x = center.x + half, y = 1.3, z = center.z } },
	}
end

-- Radial slab from the near arena rim to the inward edge of the axis-aligned
-- square platform. Local X runs along the segment; yaw rotates it into world space.
-- Touching/overlapping footprints need no bridge (and no zero-sized FillBlock/Part).
function WorldBuilderMath.pathBetween(center: Vec, half: number, arenaRadius: number, arenaCenter: Vec?): PathSpan?
	local origin = arenaCenter or { x = 0, y = 0, z = 0 }
	local dx, dz = center.x - origin.x, center.z - origin.z
	local distance = math.sqrt(dx * dx + dz * dz)
	if distance == 0 then
		return nil
	end
	local ux, uz = dx / distance, dz / distance
	local innerRadius = distance - half / math.max(math.abs(ux), math.abs(uz))
	if innerRadius <= arenaRadius then
		return nil
	end
	local midpoint = (innerRadius + arenaRadius) / 2
	return {
		size = { x = innerRadius - arenaRadius, y = 0.2, z = 12 },
		position = { x = origin.x + ux * midpoint, y = 0.1, z = origin.z + uz * midpoint },
		yaw = -math.atan2(uz, ux),
	}
end

-- Arena floor diameter from its radius.
function WorldBuilderMath.arenaFloorSize(radius: number): number
	return radius * 2
end

-- ---------------------------------------------------------------------------
-- Terrain generation: deterministic value noise and pure column/segment math.
-- Nothing here touches Roblox APIs so the same math runs under Lune specs.

export type TerrainSpec = {
	half: number,
	flatHalf: number,
	cellSize: number,
	baseY: number,
	hillHeight: number,
	waterLevel: number,
	waterDepth: number,
	noiseScale: number,
	seed: number,
	columnDepth: number,
}

export type TerrainColumn = {
	x: number,
	z: number,
	top: number,
	bottom: number,
	kind: string,
	waterTop: number?,
}

export type Segment = { size: Vec, position: Vec }

export type StandPlacement = { x: number, z: number, angle: number }

-- Classic GLSL-style hash. Deterministic across any IEEE-754 platform.
local function hash2(ix: number, iz: number, seed: number): number
	local v = math.sin(ix * 127.1 + iz * 311.7 + seed * 74.7) * 43758.5453123
	return v - math.floor(v)
end

-- Hermite interpolation of the 0..1 domain weight.
function WorldBuilderMath.smoothstep(edge0: number, edge1: number, x: number): number
	if edge0 == edge1 then
		return if x < edge0 then 0 else 1
	end
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Deterministic 2D value noise in [0, 1).
function WorldBuilderMath.valueNoise2D(x: number, z: number, seed: number): number
	local x0 = math.floor(x)
	local z0 = math.floor(z)
	local fx = x - x0
	local fz = z - z0
	local u = fx * fx * (3 - 2 * fx)
	local v = fz * fz * (3 - 2 * fz)
	local n00 = hash2(x0, z0, seed)
	local n10 = hash2(x0 + 1, z0, seed)
	local n01 = hash2(x0, z0 + 1, seed)
	local n11 = hash2(x0 + 1, z0 + 1, seed)
	local nx0 = n00 + (n10 - n00) * u
	local nx1 = n01 + (n11 - n01) * u
	return nx0 + (nx1 - nx0) * v
end

-- Surface height of the generated terrain at (x, z). The play plateau stays
-- exactly flat at spec.baseY, so bases, arena, spawns, and prompts are safe.
function WorldBuilderMath.terrainSurfaceY(x: number, z: number, spec: TerrainSpec): number
	local d = math.max(math.abs(x), math.abs(z))
	if d <= spec.flatHalf then
		return spec.baseY
	end

	local n = WorldBuilderMath.valueNoise2D(x * spec.noiseScale, z * spec.noiseScale, spec.seed)
	local n2 = WorldBuilderMath.valueNoise2D(
		x * spec.noiseScale * 2.17 + 11.3,
		z * spec.noiseScale * 2.17 - 4.7,
		spec.seed + 917
	)
	local blend = n * 0.65 + n2 * 0.35

	-- Hills grow out of the plateau, then the far ring sinks under the water line.
	local rise = WorldBuilderMath.smoothstep(spec.flatHalf, spec.flatHalf + (spec.half - spec.flatHalf) * 0.55, d)
	local lakeStart = spec.half - (spec.half - spec.flatHalf) * 0.4
	local sink = WorldBuilderMath.smoothstep(lakeStart, spec.half, d)

	local y = spec.baseY + rise * (blend - 0.4) * spec.hillHeight
	local floorY = spec.waterLevel - spec.waterDepth
	return y + (floorY - y) * sink
end

-- One FillBlock column per terrain cell: a solid column plus an optional water cap.
function WorldBuilderMath.terrainColumns(spec: TerrainSpec): { TerrainColumn }
	local cols: { TerrainColumn } = {}
	local count = math.ceil((spec.half * 2) / spec.cellSize)
	local start = -spec.half + spec.cellSize / 2
	for ix = 0, count - 1 do
		local x = start + ix * spec.cellSize
		for iz = 0, count - 1 do
			local z = start + iz * spec.cellSize
			local top = WorldBuilderMath.terrainSurfaceY(x, z, spec)
			local kind = if top > spec.baseY + spec.hillHeight * 0.55 then "rock" else "grass"
			local waterTop: number? = if top < spec.waterLevel then spec.waterLevel else nil
			table.insert(cols, {
				x = x,
				z = z,
				top = top,
				bottom = top - spec.columnDepth,
				kind = kind,
				waterTop = waterTop,
			})
		end
	end
	return cols
end

-- Fence posts and rails around three sides of a square base. The side whose
-- outward normal points along `openDir` is left open as the gate to the arena.
function WorldBuilderMath.fenceSegments(
	center: Vec,
	half: number,
	height: number,
	spacing: number,
	openDir: Vec
): { Segment }
	local segments: { Segment } = {}
	local sides = {
		{ axis = "x", sign = -1 },
		{ axis = "x", sign = 1 },
		{ axis = "z", sign = -1 },
		{ axis = "z", sign = 1 },
	}
	for _, side in sides do
		local open = if side.axis == "x" then side.sign * openDir.x else side.sign * openDir.z
		if open > 0.5 then
			continue
		end

		local n = math.max(2, math.floor((half * 2) / spacing))
		for i = 0, n do
			local t = -half + (half * 2) * (i / n)
			local px = if side.axis == "x" then center.x + side.sign * half else center.x + t
			local pz = if side.axis == "x" then center.z + t else center.z + side.sign * half
			table.insert(segments, {
				size = { x = 0.6, y = height, z = 0.6 },
				position = { x = px, y = height / 2, z = pz },
			})
		end

		local span = half * 2
		if side.axis == "x" then
			table.insert(segments, {
				size = { x = 0.5, y = 0.5, z = span },
				position = { x = center.x + side.sign * half, y = height * 0.9, z = center.z },
			})
			table.insert(segments, {
				size = { x = 0.5, y = 0.5, z = span },
				position = { x = center.x + side.sign * half, y = height * 0.5, z = center.z },
			})
		else
			table.insert(segments, {
				size = { x = span, y = 0.5, z = 0.5 },
				position = { x = center.x, y = height * 0.9, z = center.z + side.sign * half },
			})
			table.insert(segments, {
				size = { x = span, y = 0.5, z = 0.5 },
				position = { x = center.x, y = height * 0.5, z = center.z + side.sign * half },
			})
		end
	end
	return segments
end

-- Evenly spaced arena stands, offset so none sits on the base-to-arena paths.
function WorldBuilderMath.standPlacements(center: Vec, radius: number, count: number): { StandPlacement }
	local stands: { StandPlacement } = {}
	for i = 0, count - 1 do
		local angle = (i + 0.5) * (math.pi * 2 / count)
		table.insert(stands, {
			x = center.x + math.cos(angle) * radius,
			z = center.z + math.sin(angle) * radius,
			angle = angle,
		})
	end
	return stands
end

-- ---------------------------------------------------------------------------
-- Decoration scatter: deterministic Poisson-disk-ish rejection sampling.

export type ScatterRegion = {
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

-- An annulus around (x, z): points with `inner <= distance <= outer` are inside
-- it. Exclusions use inner = 0 (a solid disc); attractors sample within the ring.
export type ScatterZone = {
	x: number,
	z: number,
	inner: number,
	outer: number,
}

export type ScatterBand = {
	kind: string,
	count: number,
	minSpacing: number,
	scaleMin: number,
	scaleMax: number,
	-- Vertical squash of the generated scale, as a fraction of its size. Props
	-- pivot at their base, so this also sets how tall they read.
	yFactor: number?,
	-- When present, `attractorChance` of samples land in an annulus around one of
	-- these zones (arena rim, base perimeters) instead of anywhere in the region.
	attractors: { ScatterZone }?,
	attractorChance: number?,
	-- Bias sampling toward a band `edgeWidth` wide around the region border,
	-- which produces groves along the map edge. 0 = uniform, 1 = always edge.
	edgeBias: number?,
	edgeWidth: number?,
}

export type ScatterSpec = {
	region: ScatterRegion,
	bands: { ScatterBand },
	exclusions: { ScatterZone },
	maxAttempts: number,
}

export type ScatterPoint = {
	kind: string,
	position: Vec,
	scale: Vec,
	seed: number,
}

-- Deterministic scalar hash in [0, 1): the fractional part of a scaled sine, the
-- same trick valueNoise2D uses. Pure, so the same spec and seed always produce
-- the same scatter.
local function hashUnit(n: number, seed: number): number
	local v = math.sin(n * 12.9898 + seed * 78.233) * 43758.5453123
	return v - math.floor(v)
end

local function sampler(seed: number): () -> number
	local n = 0
	return function(): number
		n += 1
		return hashUnit(n, seed)
	end
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function insideZone(x: number, z: number, zone: ScatterZone): boolean
	local dx = x - zone.x
	local dz = z - zone.z
	local d = math.sqrt(dx * dx + dz * dz)
	return d >= zone.inner and d <= zone.outer
end

local function isExcluded(x: number, z: number, zones: { ScatterZone }): boolean
	for _, zone in zones do
		if insideZone(x, z, zone) then
			return true
		end
	end
	return false
end

local function sampleXZ(rng: () -> number, region: ScatterRegion, band: ScatterBand): (number, number)
	local edgeBias = band.edgeBias or 0
	local edgeWidth = band.edgeWidth or 0
	if edgeBias > 0 and rng() < edgeBias then
		local side = math.floor(rng() * 4)
		local t = rng()
		local depth = rng() * edgeWidth
		if side == 0 then
			return lerp(region.minX, region.maxX, t), region.minZ + depth
		elseif side == 1 then
			return lerp(region.minX, region.maxX, t), region.maxZ - depth
		elseif side == 2 then
			return region.minX + depth, lerp(region.minZ, region.maxZ, t)
		end
		return region.maxX - depth, lerp(region.minZ, region.maxZ, t)
	end

	local attractors = band.attractors
	local chance = band.attractorChance or 0
	if attractors and #attractors > 0 and rng() < chance then
		local zone = attractors[math.floor(rng() * #attractors) + 1]
		local angle = rng() * math.pi * 2
		local radius = lerp(zone.inner, zone.outer, rng())
		local x = math.clamp(zone.x + math.cos(angle) * radius, region.minX, region.maxX)
		local z = math.clamp(zone.z + math.sin(angle) * radius, region.minZ, region.maxZ)
		return x, z
	end

	return lerp(region.minX, region.maxX, rng()), lerp(region.minZ, region.maxZ, rng())
end

-- Poisson-disk-ish rejection sampling: each proposal is rejected when it lands
-- in an exclusion zone or closer to an already placed point than the larger of
-- the two bands' min spacing. Returns at most `count` points per band; with the
-- default attempt budget the bands fill completely.
function WorldBuilderMath.scatter(spec: ScatterSpec, seed: number): { ScatterPoint }
	local points: { ScatterPoint } = {}
	local spacings: { number } = {}

	for bandIndex, band in spec.bands do
		local rng = sampler(seed + bandIndex * 101.7)
		local placed = 0
		local attempts = 0
		while placed < band.count and attempts < spec.maxAttempts do
			attempts += 1
			local x, z = sampleXZ(rng, spec.region, band)
			if isExcluded(x, z, spec.exclusions) then
				continue
			end

			local size = lerp(band.scaleMin, band.scaleMax, rng())
			local sx = size * (0.82 + 0.18 * rng())
			local sz = size * (0.82 + 0.18 * rng())
			local sy = size * (band.yFactor or 0.8) * (0.85 + 0.15 * rng())
			-- Props scale to their largest axis, so normalize it onto `size`: the
			-- rendered prop then lands exactly in [scaleMin, scaleMax] and +y lands
			-- the base-pivoted prop's foot near the ground.
			local norm = size / math.max(sx, sy, sz)
			sx *= norm
			sy *= norm
			sz *= norm

			local clear = true
			for i, point in points do
				local dx = x - point.position.x
				local dz = z - point.position.z
				local need = math.max(band.minSpacing, spacings[i])
				if dx * dx + dz * dz < need * need then
					clear = false
					break
				end
			end
			if not clear then
				continue
			end

			local yaw = rng() * math.pi * 2
			table.insert(points, {
				kind = band.kind,
				-- +y holds the placeholder's bottom on the ground for base-pivoted props.
				position = { x = x, y = sy / 2, z = z },
				scale = { x = sx, y = sy, z = sz },
				seed = yaw,
			})
			table.insert(spacings, band.minSpacing)
			placed += 1
		end
	end

	return points
end

-- ---------------------------------------------------------------------------
-- Flower patches and bleachers (pure placement geometry).

export type FlowerPetal = { position: Vec, size: Vec, tone: number }

-- Three petals ringed around a patch center; the builder turns each into a Ball.
function WorldBuilderMath.flowerPatch(center: Vec, radius: number, seed: number): { FlowerPetal }
	local petalRadius = math.max(0.25, radius * 0.24)
	local reach = radius * 0.42
	local petals: { FlowerPetal } = {}
	for i = 1, 3 do
		local angle = seed + (i - 1) * (math.pi * 2 / 3)
		table.insert(petals, {
			position = {
				x = center.x + math.cos(angle) * reach,
				y = center.y + 0.35 + (i - 1) * 0.05,
				z = center.z + math.sin(angle) * reach,
			},
			size = { x = petalRadius * 2, y = petalRadius * 2, z = petalRadius * 2 },
			tone = i,
		})
	end
	return petals
end

export type BleacherPiece = { role: string, size: Vec, offset: Vec }

-- Local geometry for one three-step bleacher, measured from its ground pivot.
-- Local +z faces the arena, so the tiers step up and back (toward -z) and every
-- row sees over the one in front.
function WorldBuilderMath.bleacherPieces(): { BleacherPiece }
	local pieces: { BleacherPiece } = {}
	for tier = 1, 3 do
		local z = 1.5 - (tier - 1) * 3
		local height = tier * 2
		table.insert(pieces, {
			role = "step",
			size = { x = 18, y = height, z = 3 },
			offset = { x = 0, y = height / 2, z = z },
		})
		table.insert(pieces, {
			role = "seat",
			size = { x = 18, y = 0.4, z = 3 },
			offset = { x = 0, y = height + 0.2, z = z },
		})
		table.insert(pieces, {
			role = "trim",
			size = { x = 18, y = 0.25, z = 0.25 },
			offset = { x = 0, y = height + 0.5, z = z + 1.35 },
		})
	end

	local backZ = 1.5 - 2 * 3 - 1.5
	for _, sx in { -1, 1 } do
		table.insert(pieces, {
			role = "rail",
			size = { x = 0.6, y = 7, z = 0.6 },
			offset = { x = sx * 8.5, y = 3.5, z = backZ },
		})
	end
	table.insert(pieces, {
		role = "rail",
		size = { x = 18, y = 0.5, z = 0.5 },
		offset = { x = 0, y = 6.5, z = backZ },
	})
	for _, sx in { -1, 1 } do
		table.insert(pieces, {
			role = "rail",
			size = { x = 0.5, y = 0.5, z = 6 },
			offset = { x = sx * 8.75, y = 6.5, z = -3 },
		})
	end

	return pieces
end

return WorldBuilderMath
