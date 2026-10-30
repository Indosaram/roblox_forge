--!strict
-- L12 biome look (R11-1..R11-9): per-biome terrain material colours, inland material grading,
-- day grade / water colour, and the coast shallows + foam line of the twenty biome islands
-- (rw.aN.sM). Pure data and functions: RoleWorld applies the terrain side, SkyCycle the light.
-- Every other role (onboarding, explore, frontier, harbor, town, home) keeps the global look, and
-- grading never runs inside the arrival ring (L10b owns the spawn screen: patches, cards, labels).
local B1b = require("./BiomeKitsB1b")

local M = {}

type RGB = { number }

-- Grading never touches ground nearer than this to an arrival point or a spawn (studs).
M.RING = 176
-- ... nor nearer than this to authored ground (paths, nodes, anchors: field.clear).
M.CLEAR = 96

export type Look = {
	biome: string,
	-- Terrain material -> colour (SetMaterialColor), applied once per role build.
	terrain: { [string]: RGB },
	-- Base material -> graded material by rule (see M.grade).
	high: { material: string, from: number }?,
	patch: { material: string, share: number, scale: number }?,
	streak: { material: string, share: number }?,
	-- Biome2: path-side band (inside CLEAR of authored ground but outside the arrival ring) graded to
	-- `material` where the noise share allows (grassland: warm ochre meadow, not olive/mud).
	verge: { material: string, share: number }?,
	-- Day light: replaces DAY.water / grade tint, adds to grade saturation/contrast and to the
	-- day Atmosphere density/haze (scaled by daylight, so night fog caps are untouched).
	water: RGB,
	tint: RGB,
	saturation: number,
	contrast: number,
	density: number,
	haze: number,
	-- Optional day air colour (replaces the dressing palette fog by day) and exposure offset.
	air: RGB?,
	exposure: number?,
	transparency: number,
	-- Coast: depth of the outer shallow shelf under the sea (studs) and the foam (Salt) colour.
	shelf: number,
	foam: RGB,
}

local function rgb(r: number, g: number, b: number): RGB
	return { r, g, b }
end

-- L10 grades these five place-wide for the spawn screen (RoleWorld); a biome look never recolours
-- them, it only paints them into the far ground as patches. MaterialColors are place-wide.
M.RESERVED = table.freeze({ Ground = true, Limestone = true, LeafyGrass = true, Grass = true, Pavement = true })

local function colours(kit: string?, over: { [string]: RGB }): { [string]: RGB }
	local out: { [string]: RGB } = {}
	local data = if kit then B1b.kits[kit] else nil
	for _, source in { if data then data.terrain else {}, over } do
		for key, value in source do
			if not M.RESERVED[key] then
				out[key] = value
			end
		end
	end
	return out
end

-- Ground colours sampled from the R11 frames (median of the open ground, 60x40 downsample):
-- R11-8 grassland 160/112/79, R11-7 desert 200/142/108, R11-2 jungle 101/52/70 (red dirt under
-- a lilac haze), R11-3 swamp 43/33/38, R11-6 snow 180/181/185, R11-4 volcano 72/51/63.
-- Salt is the foam line (only the coast writes it).
-- stylua: ignore start
M.looks = table.freeze({
	grassland = {
		-- Terrace lane (R11-8 warm ochre): the far meadow is Mud tinted dry ochre (Grass stays the L10
		-- spawn-screen colour place-wide), with olive Grass left in noise holes; pond beds are under water.
		terrain = colours(nil, { Rock = rgb(118, 112, 100), Sand = rgb(196, 180, 146), Salt = rgb(236, 238, 228),
			Mud = rgb(84, 54, 38) }),
		patch = { material = "Mud", share = 0.42, scale = 90 },
		verge = { material = "Mud", share = 0.62 },
		water = rgb(66, 132, 140), tint = rgb(255, 236, 204), saturation = -0.02, contrast = 0.02,
		density = 0.02, haze = 0.3, transparency = 0.4, shelf = 3, foam = rgb(236, 238, 228),
	},
	desert = {
		terrain = colours("desert", { Sand = rgb(196, 140, 98), Sandstone = rgb(170, 112, 74),
			Rock = rgb(150, 104, 76), Salt = rgb(242, 234, 220) }),
		patch = { material = "Sandstone", share = 0.26, scale = 110 },
		high = { material = "Sandstone", from = 30 },
		water = rgb(76, 150, 150), tint = rgb(255, 230, 198), saturation = 0.02, contrast = 0.04,
		density = 0.04, haze = 0.8, transparency = 0.45, shelf = 2.5, foam = rgb(242, 234, 220),
	},
	tropical = {
		terrain = colours(nil, { Mud = rgb(116, 64, 54), Rock = rgb(96, 86, 80), Sand = rgb(214, 204, 178),
			Salt = rgb(240, 244, 238) }),
		patch = { material = "Mud", share = 0.2, scale = 70 },
		water = rgb(52, 146, 146), tint = rgb(252, 232, 226), saturation = -0.04, contrast = 0.04,
		density = 0.1, haze = 1.6, transparency = 0.5, air = rgb(196, 176, 190), shelf = 2, foam = rgb(240, 244, 238),
	},
	swamp = {
		-- Biome2 (R11-3 ground 43/33/38): darker, wetter mud; olive LeafyGrass only in small patches.
		terrain = colours("swamp", { Mud = rgb(56, 48, 40), Rock = rgb(78, 80, 70), Sand = rgb(124, 116, 92),
			Salt = rgb(170, 172, 142) }),
		patch = { material = "LeafyGrass", share = 0.2, scale = 60 },
		water = rgb(78, 84, 56), tint = rgb(214, 220, 200), saturation = -0.26, contrast = 0.08,
		density = 0.16, haze = 2.4, transparency = 0.2, air = rgb(150, 156, 144), exposure = -0.25, shelf = 4, foam = rgb(170, 172, 142),
	},
	snow = {
		terrain = colours("tundra", { Snow = rgb(218, 222, 226), Glacier = rgb(168, 194, 206),
			Rock = rgb(108, 108, 104), Ice = rgb(176, 202, 214), Sand = rgb(150, 146, 136), Salt = rgb(240, 246, 250) }),
		patch = { material = "Rock", share = 0.12, scale = 80 },
		high = { material = "Glacier", from = 44 },
		water = rgb(64, 104, 122), tint = rgb(234, 242, 255), saturation = -0.12, contrast = 0.04,
		density = 0.05, haze = 0.8, transparency = 0.35, shelf = 3, foam = rgb(240, 246, 250),
	},
	volcano = {
		terrain = colours("volcano", { Basalt = rgb(58, 50, 50), Slate = rgb(84, 70, 70), Rock = rgb(74, 66, 64),
			CrackedLava = rgb(160, 66, 32), Sand = rgb(104, 92, 94), Salt = rgb(200, 196, 188) }),
		-- Biome2 (R11-4 ash-grey/maroon ground): soft ash (Sand tinted ash) patches over the basalt.
		patch = { material = "Sand", share = 0.4, scale = 70 },
		streak = { material = "CrackedLava", share = 0.05 },
		water = rgb(70, 82, 80), tint = rgb(255, 224, 214), saturation = -0.1, contrast = 0.06,
		density = 0.1, haze = 1.4, transparency = 0.3, shelf = 3, foam = rgb(200, 196, 188),
	},
} :: any)
-- stylua: ignore end

--- The look of a biome island, nil for every other role (they keep the global look).
function M.of(layout: any): Look?
	if type(layout) ~= "table" or not string.match(layout.id or "", "^rw%.a%d+%.s%d+$") then
		return nil
	end
	local biome = if table.find(layout.biomes, "volcano") then "volcano" else layout.biomes[1]
	local look = M.looks[biome]
	if not look then
		return nil
	end
	local out = table.clone(look)
	out.biome = biome
	return out :: any
end

--- Graded write material for a land column at (x, z) whose base material is `material`.
--- Only the biome's base ground grades (sand, rock cliffs, mud beds and dirt trails stay);
--- `away` is false inside the arrival ring or near authored ground, where nothing changes.
function M.grade(look: Look, material: string, base: string, x: number, z: number, top: number, away: boolean): string
	if not away or material ~= base then
		return material
	end
	if look.high and top >= look.high.from + math.noise(x / 60, z / 60, 3.1) * 6 then
		return look.high.material
	end
	local streak = look.streak
	if streak and math.abs(math.noise(x / 140, z / 40, 7.7)) < streak.share then
		return streak.material
	end
	local patch = look.patch
	if patch then
		-- math.noise is roughly symmetric in [-0.5, 0.5]: the upper `share` of it is the patch.
		local n = math.noise(x / patch.scale, z / patch.scale, 1.3) + 0.25 * math.noise(x / 23, z / 23, 4.2)
		if n > 0.5 - patch.share * 1.6 then
			return patch.material
		end
	end
	return material
end

--- Biome2: graded material of a path-side cell (inside CLEAR of authored ground) on a look with a
--- `verge` rule. Only grass and trampled ground change, and only where `away` (outside the arrival
--- ring: L10b owns the spawn screen); a noise share keeps some grass in holes.
M.VERGE_FROM = table.freeze({ Grass = true, Ground = true, LeafyGrass = true })
function M.verge(look: Look, material: string, x: number, z: number, away: boolean): string
	local rule = look.verge
	if not rule or not away or not M.VERGE_FROM[material] then
		return material
	end
	local n = math.noise(x / 40, z / 40, 2.7) + 0.3 * math.noise(x / 13, z / 13, 6.1)
	return if n > 0.5 - rule.share * 1.6 then rule.material else material
end

--- True when (x, z) is outside every arrival/spawn ring of `layout` (`arrivals` from BiomeKits).
--- The ring edge is pushed out by up to RING_JITTER studs of noise (never in), so the graded far
--- ground meets the spawn screen along a ragged line, not a circle of 8-stud cells.
M.RING_JITTER = 40
function M.away(layout: any, arrivals: { { x: number, z: number } }, x: number, z: number): boolean
	local ring = M.RING + (math.noise(x / 53, z / 53, 5.9) + 0.5) * M.RING_JITTER
	ring = math.max(ring, M.RING)
	for _, at in arrivals do
		if (x - at.x) ^ 2 + (z - at.z) ^ 2 < ring * ring then
			return false
		end
	end
	for _, spawn in layout.spawns do
		if (x - spawn.position.x) ^ 2 + (z - spawn.position.z) ^ 2 < ring * ring then
			return false
		end
	end
	return true
end

--- Coast shallows and foam along a coast contour (ArchipelagoTerrain coast: point(angle, inset),
--- unit). Land columns reach ~12 studs past the contour. Returns sand shelf balls just outside them, stepping down from 1 stud under the
--- sea to `look.shelf` under it (light shallows instead of a wall into the -12 seabed), and Salt foam
--- strips filling the top 4-stud water voxel (Studio, L12: a thinner or narrower Salt write leaves
--- the voxel water): a solid line at the waterline and a broken surf line 10 studs out. `sea` is the
--- water surface. Deterministic: samples step by arc length.
function M.coast(look: Look, coast: any, sea: number): { shelf: { any }, foam: { any } }
	local shelf, foam = {}, {}
	local function ring(outward: number, step: number, visit: (number, number, number, number, number) -> ())
		local px, pz = math.huge, math.huge
		local index = 0
		for s = 0, 2880 do
			local x, z = coast.point(s * math.pi / 1440, -outward / coast.unit)
			if math.sqrt((x - px) ^ 2 + (z - pz) ^ 2) >= step then
				if px ~= math.huge then
					index += 1
					visit(index, px, pz, x, z)
				end
				px, pz = x, z
			end
		end
	end
	for _, row in
		{
			{ out = 14, top = 0.6, r = 12 },
			{ out = 26, top = (0.6 + look.shelf) / 2, r = 14 },
			{ out = 40, top = look.shelf, r = 16 },
		}
	do
		ring(row.out, row.r, function(_, ax, az, bx, bz)
			table.insert(shelf, { x = (ax + bx) / 2, y = sea - row.top - row.r, z = (az + bz) / 2, radius = row.r })
		end)
	end
	for _, row in { { out = 4, width = 6, keep = 1 }, { out = 14, width = 5, keep = 0.5 } } do
		ring(row.out, 12, function(index, ax, az, bx, bz)
			if math.abs(math.noise(index * 0.37, row.out * 0.11, 9.3)) * 2 > row.keep then
				return
			end
			table.insert(foam, {
				x = (ax + bx) / 2,
				z = (az + bz) / 2,
				top = sea,
				length = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2) + 3,
				width = row.width,
				yaw = math.atan2(bx - ax, bz - az),
			})
		end)
	end
	return { shelf = shelf, foam = foam }
end

return M
