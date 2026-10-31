--!strict
-- Saltmeadow town life (R12/R13 "lived-in Durango town"): the pure dressing plan RoleWorld places on
-- rw.town on top of the houses (WorldDressing.TOWN) and set pieces (StructureMeshes.SET_PIECES).
-- * props: decor rows (B3 town kit + the RobangoTownLife package): carts, laundry lines, fish racks,
--   woodpiles, sack piles, rowboats, benches, stalls. `face` turns the row's front (-Z) toward a point.
-- * fires: campfire rings (bld.campfire) with log benches around them and survivors seated on them.
-- * lamps: warm lamp posts (SkyCycle.torch: the SkyDriver strengthens them at dusk and night).
-- * folk: survivor figures (SurvivorAvatar L6 rigs) in an idle pose with a floating role label.
-- * shore: the south bay, so the pier and the cutter stand in water and the rowboats on a beach.
-- Everything is decor (no prompt, no collision); positions are authored, never random.
local M = {}

M.LAYOUT = "rw.town"

-- Footprint radius (studs) of each row for clearance checks (L5 rows.json / town-life bounds).
M.RADIUS = table.freeze({
	["town.handcart"] = 3.4,
	["town.laundry-line"] = 6.2,
	["town.log-bench"] = 2.9,
	["town.rowboat"] = 5.9,
	["town.fish-rack"] = 4.2,
	["town.woodpile"] = 4.5,
	["town.sack-pile"] = 2.8,
	["town.crate-stack"] = 2.2,
	["town.barrel"] = 1.2,
	["town.market-stall"] = 3.6,
	["town.flower-bed"] = 3.4,
	["bld.campfire"] = 3.1,
	["town.lamp-post"] = 1.2,
	["town.parasol"] = 4.2,
	["town.market-canopy"] = 10.5,
	["bld.well"] = 3.4,
	["town.notice-board"] = 3,
	["town.drift-camp-walkway"] = 8,
} :: { [string]: number })

-- Survivor figure poses (SurvivorAvatar.POSES): seated on a bench, carrying a load, working with a
-- raised arm, tending a stall, or standing.
M.POSES = table.freeze({ "sit", "carry", "work", "vend", "stand" })

-- Seat height of town.log-bench (top of the plank, gen_buildings log_bench).
M.SEAT = 1.65
-- Benches stand this far from a campfire centre; two sitters share a bench.
M.BENCH_RING = 6.5

export type Point = { x: number, z: number }
export type Prop = { id: string, row: string, x: number, z: number, yaw: number?, face: Point?, r: number }
export type Folk = {
	id: string,
	label: string,
	pose: string,
	x: number,
	z: number,
	face: Point,
	seat: number?,
}

local function p(x: number, z: number): Point
	return { x = x, z = z }
end

-- Dense core (R12/R13): front cottages at x = +-30 face the main road in two rows (z 270-322 and
-- 404-508) with a market square between them (z 330-395); a back row at x = +-96 faces the back
-- lanes. Beside every front house row a fenced yard (x 46-78 on each side) holds the household's
-- carts, racks, woodpiles and laundry, so the props cluster inside fences instead of dotting the
-- open island. WorldDressing.TOWN owns the houses; this plan owns yards, square, lanes and life.
-- A yard: fence rectangle (x0..x1, z0..z1); its gate gap faces the main road (the near x side).
M.YARDS = table.freeze({
	{ x0 = 46, x1 = 78, z0 = 258, z1 = 334, gate = 283 },
	{ x0 = 46, x1 = 78, z0 = 396, z1 = 446, gate = 421 },
	{ x0 = 46, x1 = 78, z0 = 454, z1 = 520, gate = 469 },
	{ x0 = -78, x1 = -46, z0 = 258, z1 = 334, gate = 309 },
	{ x0 = -78, x1 = -46, z0 = 396, z1 = 446, gate = 417 },
	{ x0 = -78, x1 = -46, z0 = 454, z1 = 520, gate = 487 },
} :: { { x0: number, x1: number, z0: number, z1: number, gate: number } })
-- Fence segment length (town.plot-fence tiles end to end at 8 studs) and the gate gap.
M.FENCE = 8
M.GATE = 8

-- { row, x, z, yaw | face }
local PROPS: { { any } } = {
	-- Harbor front: boats hauled up on the beach (z = nil: on the waterline), fish racks, cargo.
	{ "town.rowboat", -100, nil, 70 },
	{ "town.rowboat", -134, nil, 95 },
	{ "town.rowboat", 112, nil, -80 },
	{ "town.rowboat", 146, nil, -100 },
	{ "town.fish-rack", -50, 572, 10 },
	{ "town.fish-rack", 40, 540, -8 },
	{ "town.sack-pile", -26, 574, 0 },
	{ "town.crate-stack", 24, 578, 25 },
	{ "town.barrel", 30, 571, 0 },
	{ "town.barrel", -32, 566, 0 },
	-- Harbour square at the arrival (R13-5 market, inside the spawn's play-camera frame): two
	-- striped market canopies facing the main road, a parasol cluster, crates, barrels and sacks.
	{ "town.market-canopy", -27, 540, 180 },
	{ "town.market-canopy", 26, 532, 0 },
	{ "town.parasol", -16, 556, 0 },
	{ "town.parasol", 16, 556, 20 },
	{ "town.parasol", -19, 520, 10 },
	{ "town.parasol", 36, 552, 0 },
	{ "town.parasol", -42, 556, 15 },
	{ "town.crate-stack", 44, 520, 30 },
	{ "town.barrel", 40, 545, 0 },
	{ "town.barrel", -36, 556, 0 },
	{ "town.sack-pile", 40, 570, 0 },
	{ "town.crate-stack", -38, 520, -10 },
	-- The arrival well and the notice board on the road (camp landmarks in the first frame).
	{ "bld.well", -21, 564, 20 },
	{ "town.notice-board", 16, 548, p(0, 548) },
	-- Market square (z 330-395): two awning rows facing a central aisle, goods between.
	{ "town.market-stall", -22, 340, p(0, 340) },
	{ "town.market-stall", -22, 352, p(0, 352) },
	{ "town.market-stall", -22, 382, p(0, 382) },
	{ "town.market-stall", 22, 346, p(0, 346) },
	{ "town.market-stall", 22, 372, p(0, 372) },
	{ "town.market-stall", 22, 384, p(0, 384) },
	{ "town.sack-pile", -34, 336, 0 },
	{ "town.crate-stack", 36, 338, 20 },
	{ "town.barrel", -34, 390, 0 },
	{ "town.barrel", 36, 389, 0 },
	-- East yards.
	{ "town.handcart", 62, 266, 10 },
	{ "town.laundry-line", 62, 282, 90 },
	{ "town.woodpile", 70, 304, 0 },
	{ "town.sack-pile", 54, 302, 0 },
	{ "town.fish-rack", 62, 324, 0 },
	{ "town.woodpile", 62, 406, 0 },
	{ "town.crate-stack", 54, 424, 0 },
	{ "town.barrel", 72, 422, 0 },
	{ "town.laundry-line", 62, 438, 0 },
	{ "town.handcart", 62, 466, 80 },
	{ "town.fish-rack", 64, 488, 0 },
	{ "town.sack-pile", 52, 508, 0 },
	{ "town.woodpile", 70, 510, 0 },
	-- West yards.
	{ "town.laundry-line", -62, 268, 0 },
	{ "town.woodpile", -70, 292, 0 },
	{ "town.handcart", -58, 310, 100 },
	{ "town.crate-stack", -70, 326, 15 },
	{ "town.sack-pile", -54, 406, 0 },
	{ "town.fish-rack", -62, 422, 90 },
	{ "town.barrel", -72, 438, 0 },
	{ "town.laundry-line", -62, 468, 90 },
	{ "town.woodpile", -54, 498, 0 },
	{ "town.crate-stack", -70, 494, 0 },
	{ "town.handcart", -64, 512, 0 },
	-- Well square.
	{ "town.sack-pile", -234, 236, 0 },
	{ "town.barrel", -238, 268, 0 },
	{ "town.handcart", -244, 292, 40 },
	{ "town.laundry-line", -180, 292, 30 },
	-- Work yard and clan hall.
	{ "town.woodpile", 216, 340, 90 },
	{ "town.crate-stack", 150, 362, 0 },
	{ "town.woodpile", 260, 252, 0 },
	{ "town.crate-stack", 200, 174, 15 },
}

-- Campfire rings: centre and the angles (degrees) of their benches.
local FIRES: { { any } } = {
	{ "harbor", 70, 550, { 200, 320 } },
	{ "square", -40, 362, { 0, 180 } },
	{ "clan", 176, 246, { 30, 150 } },
	{ "yard", -62, 482, { 0, 180 } },
}

-- Lanterns along the street, the square and the back lanes (each a small warm spot at dusk).
local LAMPS: { Point } = {
	p(-16, 584),
	p(-12, 550),
	p(12, 520),
	p(-16, 500),
	p(16, 468),
	p(-16, 444),
	p(16, 418),
	p(-14, 398),
	p(14, 330),
	p(-16, 314),
	p(16, 286),
	p(-16, 258),
	p(16, 230),
	p(-18, 180),
	p(18, 160),
	p(-118, 280),
	p(118, 280),
	p(-118, 456),
	p(118, 456),
	p(-190, 240),
	p(198, 186),
	p(200, 318),
}

-- { id, label, pose, x, z, face }
local FOLK: { { any } } = {
	{ "harbor.fisher.1", "folk.fisher", "work", -50, 566, p(-50, 572) },
	{ "square.h.vendor.w", "folk.trader", "vend", -28, 540, p(0, 540) },
	{ "square.h.vendor.e", "folk.trader", "vend", 27, 532, p(0, 532) },
	{ "square.h.buyer.1", "folk.villager", "stand", -17, 538, p(-26, 538) },
	{ "square.h.buyer.2", "folk.villager", "stand", -18, 530, p(-26, 532) },
	{ "square.h.buyer.3", "folk.villager", "stand", 16, 534, p(26, 534) },
	{ "square.h.well", "folk.villager", "work", -15, 566, p(-21, 564) },
	{ "square.h.porter", "folk.porter", "carry", 6, 516, p(6, 440) },
	{ "square.h.shade", "folk.villager", "stand", 22, 556, p(16, 556) },
	{ "harbor.fisher.2", "folk.fisher", "work", 40, 546, p(40, 540) },
	{ "harbor.porter.1", "folk.porter", "carry", -10, 560, p(-10, 480) },
	{ "harbor.porter.2", "folk.porter", "carry", 10, 592, p(10, 640) },
	{ "harbor.trader", "folk.trader", "vend", -26, 568, p(-26, 574) },
	{ "square.vendor.1", "folk.trader", "vend", -16, 340, p(0, 340) },
	{ "square.vendor.2", "folk.trader", "vend", 16, 372, p(0, 372) },
	{ "square.vendor.3", "folk.trader", "vend", -16, 382, p(0, 382) },
	{ "square.buyer.1", "folk.villager", "stand", -9, 346, p(-22, 346) },
	{ "square.buyer.2", "folk.villager", "stand", 9, 378, p(22, 378) },
	{ "square.buyer.3", "folk.villager", "stand", 9, 340, p(22, 346) },
	{ "street.porter.1", "folk.porter", "carry", 6, 300, p(6, 420) },
	{ "street.porter.2", "folk.porter", "carry", -6, 470, p(-6, 300) },
	{ "street.walker", "folk.villager", "stand", 7, 452, p(30, 456) },
	{ "yard.e.washer", "folk.villager", "work", 62, 276, p(62, 282) },
	{ "yard.e.woodcutter", "folk.builder", "work", 70, 297, p(70, 304) },
	{ "yard.e.carter", "folk.porter", "carry", 54, 474, p(62, 466) },
	{ "yard.e.fisher", "folk.fisher", "work", 64, 495, p(64, 488) },
	{ "yard.w.washer", "folk.villager", "work", -62, 462, p(-62, 468) },
	{ "yard.w.builder", "folk.builder", "work", -70, 285, p(-70, 292) },
	{ "yard.w.porter", "folk.porter", "carry", -54, 413, p(-54, 406) },
	{ "lane.walker.1", "folk.villager", "stand", 112, 300, p(112, 400) },
	{ "lane.walker.2", "folk.villager", "stand", -112, 430, p(-112, 300) },
	{ "clan.woodcutter", "folk.builder", "work", 260, 245, p(260, 252) },
	{ "well.carrier", "folk.porter", "carry", -198, 272, p(-150, 300) },
	{ "yard.builder", "folk.builder", "work", 164, 352, p(176, 360) },
}

local SITTERS: { [string]: number } = { harbor = 3, square = 3, clan = 3, yard = 3 }

-- Channel bed depth under the bank and the water line under the bank: shallow enough that a
-- survivor wades across and steps out (Roblox auto-steps about 2 studs).
M.CHANNEL_DEPTH = 1.6
M.CHANNEL_WATER = 0.5

--- The south bay's waterline z at `x` (|x| > LANDING): a beach falls 24 studs to it from the grass
--- edge and the sea lies south of it, on an organic curve so the coast never reads as a ruled line.
--- Beside the pier landing the waterline swings south (`corner`), so the landing's grass block meets
--- the bay on a rounded shoulder instead of the straight 8-stud column edge the high view read as a
--- flat strip (D2c R13).
--- The pier landing (|x| <= LANDING) keeps its grass block; the pier and the cutter stand off it.
function M.shore(x: number): number
	local corner = math.max(0, 48 - (math.abs(x) - 60)) * 0.8
	return 574 + 7 * math.sin(x / 90) + 4 * math.sin(x / 37 + 1) + corner
end

-- Half width of the pier landing (the grass block the dock and the arrival stand on).
M.LANDING = 60

-- Town folk figure scale: the play camera frames the 1x player at ~6% of the screen height
-- (QuarterView share 0.06), where a 1x figure read as a ~20 px speck on a phone (p134 v54).
M.FOLK_SCALE = 1.35

-- Night light scale (SkyCycle.FIRE_SCALE) for town lamps and campfires: the SkyCycle night fire
-- light reaches 24 studs, and 21 lamps at full range washed the dusk town into flat beige discs;
-- the lead review still read 0.45 as pale ground discs, so the glow lives in the lantern/flame
-- (bloom on a neon core, RoleWorld) and the PointLight only tints a few studs around it.
-- Night2: the night fire light is now an 8-stud pool, so lamps and town fires get a larger share
-- back (5.6 / 7.2 studs) and read as warm pools on the blue street, not dots.
M.LAMP_LIGHT = 0.7
M.FIRE_LIGHT = 0.9

-- Trampled earth (terrain material only, the ground height never changes): narrow ragged dirt foot
-- paths (3-4 studs, R12) instead of the old 10-46 stud bands that read as dark rectangles, and small
-- worn patches at the square, the fires and the well. RoleWorld wobbles each lane's centre and
-- width with noise and feathers the rim, so no straight edge remains.
M.GROUND =
	table.freeze({
		discs = {
			{ x = -6, z = 540, r = 12 },
			{ x = -40, z = 362, r = 10 },
			{ x = 70, z = 550, r = 8 },
			{ x = 176, z = 246, r = 8 },
			{ x = -62, z = 482, r = 7 },
			{ x = -208, z = 262, r = 11 },
		},
		lanes = {
			{ points = { p(112, 250), p(110, 330), p(114, 400), p(112, 520) }, width = 4 },
			{ points = { p(-112, 250), p(-114, 330), p(-110, 400), p(-112, 520) }, width = 4 },
			{ points = { p(13, 283), p(32, 284), p(46, 283) }, width = 3 },
			{ points = { p(-13, 417), p(-32, 416), p(-46, 417) }, width = 3 },
			{ points = { p(13, 469), p(32, 468), p(46, 469) }, width = 3 },
			{ points = { p(-13, 309), p(-32, 310), p(-46, 309) }, width = 3 },
			{ points = { p(-112, 262), p(-160, 258), p(-196, 262) }, width = 4 },
			{ points = { p(112, 330), p(150, 336), p(168, 346) }, width = 4 },
			{ points = { p(112, 250), p(150, 246), p(168, 246) }, width = 4 },
			{ points = { p(-16, 540), p(-40, 546) }, width = 3 },
			{ points = { p(-12, 534), p(-30, 530), p(-66, 532) }, width = 4 },
		},
	} :: { discs: { { x: number, z: number, r: number } }, lanes: { { points: { Point }, width: number } } })

-- The main street through the core (R13-5 dirt road): the catalog road paint lies under the 6-stud
-- town columns, so the street read as the flat Limestone band of the high view (D2c). TownLife.worn
-- paints it as ragged trodden earth with mud wheel ruts on the real surface.
M.STREET = table.freeze({ points = { p(0, 236), p(-2, 330), p(2, 420), p(0, 520), p(0, 592) }, width = 12 })

-- Ground cover between the yards and houses (B1 grassland rows, placed by RoleWorld as decor kit
-- cards): meadow tufts, bracken, bramble and flower patches; never on a road, lane or yard.
M.COVER_ROWS = table.freeze({
	{ "veg.grassland.meadow", "grass" },
	{ "veg.grassland.bracken", "fern" },
	{ "veg.grassland.meadow", "grass" },
	{ "veg.grassland.flower-patch", "grass" },
	{ "veg.grassland.meadow", "grass" },
	{ "veg.grassland.bracken", "fern" },
})
-- Cover sample grid (studs) over the core and how far it stays from roads, lanes, yards and houses.
M.COVER = table.freeze({ x0 = -150, x1 = 150, z0 = 240, z1 = 540, step = 7, clear = 3 })

-- Marsh water channels (R12/R13-5: water between the yards, crossed by plank bridges): shallow
-- ditches (the bed 2.4 studs under the water line, so a survivor wades, never swims) with mud
-- banks, running from the south bay up behind the back rows. Centres wobble by noise in RoleWorld
-- (TownLife.channelCells), so no bank is a ruled line.
M.CHANNEL_WIDTH = 8
M.CHANNEL_BANK = 3
M.CHANNELS = table.freeze({
	{ p(-72, 540), p(-86, 532), p(-120, 530), p(-142, 506), p(-140, 420), p(-146, 330), p(-140, 240) },
	{ p(146, 548), p(140, 520), p(142, 430), p(136, 336), p(140, 236) },
} :: { { Point } })
-- Plank footbridges (town.footbridge, 14 studs along its local Z) where a lane or plank path
-- crosses a channel; the yaw turns the span across the channel.
M.BRIDGES = table.freeze({
	{ x = -79, z = 536, yaw = 150 },
	{ x = -112, z = 530, yaw = 0 },
	{ x = -141, z = 259, yaw = 90 },
	{ x = 137, z = 334, yaw = 90 },
	{ x = 140, z = 247, yaw = 90 },
} :: { { x: number, z: number, yaw: number } })
-- Plank walkways (town.drift-camp-walkway, 16 studs along local Z) on the square's west path.
M.PLANKS = table.freeze({
	{ x = -44, z = 531, yaw = 90 },
	{ x = -60, z = 532, yaw = 90 },
} :: { { x: number, z: number, yaw: number } })

-- Distance from (x, z) to the nearest channel centre line.
function M.channelDistance(x: number, z: number): number
	local best = math.huge
	for _, line in M.CHANNELS do
		for index = 2, #line do
			local a, b = line[index - 1], line[index]
			local dx, dz = b.x - a.x, b.z - a.z
			local t = math.clamp(((x - a.x) * dx + (z - a.z) * dz) / math.max(dx * dx + dz * dz, 1e-9), 0, 1)
			best = math.min(best, math.sqrt((x - a.x - dx * t) ^ 2 + (z - a.z - dz * t) ^ 2))
		end
	end
	return best
end

--- Channel water samples (every 3 studs along each centre line): centre and radius, the centre
--- swaying a stud or two and the radius breathing, so the banks read as a natural ditch.
function M.channelCells(): { { x: number, z: number, r: number, top: number? } }
	local out: { { x: number, z: number, r: number, top: number? } } = {}
	for _, line in M.CHANNELS do
		for index = 2, #line do
			local a, b = line[index - 1], line[index]
			local dx, dz = b.x - a.x, b.z - a.z
			local length = math.sqrt(dx * dx + dz * dz)
			for s = 0, length, 3 do
				local x, z = a.x + dx * s / length, a.z + dz * s / length
				local sway = math.noise(x / 31, z / 31, 4.2) * 3
				local r = M.CHANNEL_WIDTH / 2 * (0.8 + 0.4 * (0.5 + 0.5 * math.noise(x / 13, z / 13, 9.4)))
				table.insert(out, { x = x - dz / length * sway, z = z + dx / length * sway, r = r })
			end
		end
	end
	return out
end

-- A rowboat lies this far up the beach from the waterline (its stern reaches the water).
M.BOAT_UP = 4

export type Plan = { props: { Prop }, fires: { Prop }, lamps: { Point }, folk: { Folk } }

--- The town-life plan for `layout` (only rw.town has one).
function M.plan(layout: any): Plan
	local out: Plan = { props = {}, fires = {}, lamps = {}, folk = {} }
	if layout.id ~= M.LAYOUT then
		return out
	end
	for index, entry in PROPS do
		local row, x, z, turn = entry[1], entry[2], entry[3], entry[4]
		z = z or M.shore(x) - M.BOAT_UP
		table.insert(out.props, {
			id = "life." .. index .. "." .. row,
			row = row,
			x = x,
			z = z,
			yaw = if type(turn) == "number" then turn else nil,
			face = if type(turn) == "table" then turn else nil,
			r = assert(M.RADIUS[row], row),
		})
	end
	for _, fire in FIRES do
		local name, cx, cz, angles = fire[1], fire[2], fire[3], fire[4]
		table.insert(
			out.fires,
			{ id = "fire." .. name, row = "bld.campfire", x = cx, z = cz, r = M.RADIUS["bld.campfire"] }
		)
		local seats = SITTERS[name]
		local seated = 0
		for b, angle in angles do
			local a = math.rad(angle)
			local bx, bz = cx + math.cos(a) * M.BENCH_RING, cz + math.sin(a) * M.BENCH_RING
			local centre = p(cx, cz)
			table.insert(out.props, {
				id = "fire." .. name .. ".bench." .. b,
				row = "town.log-bench",
				x = bx,
				z = bz,
				face = centre,
				r = M.RADIUS["town.log-bench"],
			})
			-- Two sitters per bench along its length (the tangent), facing the fire.
			local tx, tz = -math.sin(a), math.cos(a)
			for _, side in { -1.3, 1.3 } do
				if seated < seats then
					seated += 1
					table.insert(out.folk, {
						id = "fire." .. name .. ".sitter." .. seated,
						label = "folk.villager",
						pose = "sit",
						x = bx + tx * side,
						z = bz + tz * side,
						face = centre,
						seat = M.SEAT,
					})
				end
			end
		end
	end
	for _, lamp in LAMPS do
		table.insert(out.lamps, lamp)
	end
	for _, entry in FOLK do
		table.insert(out.folk, {
			id = entry[1],
			label = entry[2],
			pose = entry[3],
			x = entry[4],
			z = entry[5],
			face = entry[6],
		})
	end
	return out
end

-- Cheap deterministic hash in [0, 1) (Lune and Roblox agree; no math.noise).
local function hash(x: number, z: number, salt: number): number
	local v = math.sin(x * 12.9898 + z * 78.233 + salt * 37.719) * 43758.5453
	return v - math.floor(v)
end
M.hash = hash

export type Cover = { key: string, family: string, x: number, z: number, yaw: number, scale: number }

--- Ground cover cards between the yards and houses of the core: a jittered grid over M.COVER,
--- kept `M.COVER.clear` studs off every road (`layout.paths`), lane, yard fence and `blockers`
--- ({ x, z, r }: houses, set pieces, props, fires). Deterministic: no seed, the same town every time.
function M.cover(layout: any, blockers: { { x: number, z: number, r: number } }): { Cover }
	local out: { Cover } = {}
	local box, clear = M.COVER, M.COVER.clear
	local function segment(x: number, z: number, a: any, b: any): number
		local dx, dz = b.x - a.x, b.z - a.z
		local t = math.clamp(((x - a.x) * dx + (z - a.z) * dz) / math.max(dx * dx + dz * dz, 1e-9), 0, 1)
		return math.sqrt((x - a.x - dx * t) ^ 2 + (z - a.z - dz * t) ^ 2)
	end
	for gx = box.x0, box.x1, box.step do
		for gz = box.z0, box.z1, box.step do
			local x = gx + (hash(gx, gz, 1) - 0.5) * box.step
			local z = gz + (hash(gx, gz, 2) - 0.5) * box.step
			-- Clumps, not a lawn: a slow field thins the cover into patches.
			if hash(math.floor(gx / 21), math.floor(gz / 21), 3) < 0.25 or hash(gx, gz, 4) < 0.3 then
				continue
			end
			-- The market square and the main street front stay open ground (R13 reads them as trodden).
			local ok = z < M.shore(x) - 30 and not (math.abs(x) < 46 and z > 326 and z < 400)
			for _, path in layout.paths do
				for index = 2, #path.points do
					ok = ok and segment(x, z, path.points[index - 1], path.points[index]) > path.width / 2 + clear
				end
			end
			for _, lane in M.GROUND.lanes do
				for index = 2, #lane.points do
					ok = ok and segment(x, z, lane.points[index - 1], lane.points[index]) > lane.width / 2 + clear
				end
			end
			for _, disc in M.GROUND.discs do
				ok = ok and (x - disc.x) ^ 2 + (z - disc.z) ^ 2 > (disc.r + clear) ^ 2
			end
			ok = ok and M.channelDistance(x, z) > M.CHANNEL_WIDTH / 2 + M.CHANNEL_BANK + clear
			for _, yard in M.YARDS do
				ok = ok
					and not (
						x > yard.x0 - clear
						and x < yard.x1 + clear
						and z > yard.z0 - clear
						and z < yard.z1 + clear
					)
			end
			for _, other in blockers do
				ok = ok and (x - other.x) ^ 2 + (z - other.z) ^ 2 > (other.r + clear) ^ 2
			end
			if ok then
				local row = M.COVER_ROWS[math.floor(hash(gx, gz, 5) * #M.COVER_ROWS) + 1]
				table.insert(out, {
					key = row[1],
					family = row[2],
					x = x,
					z = z,
					yaw = math.floor(hash(gx, gz, 6) * 360),
					scale = 0.8 + hash(gx, gz, 7) * 0.4,
				})
			end
		end
	end
	return out
end

--- Footprints the cover keeps clear of: the town's buildings, its set pieces, and this plan's props,
--- fires and lamps (radius from M.RADIUS, 10 for a house, 6 for an unknown set piece).
function M.blockers(layout: any, buildings: { any }, setPieces: { any }): { { x: number, z: number, r: number } }
	local out = {}
	for _, building in buildings do
		table.insert(out, { x = building.x, z = building.z, r = if building.kind == "house" then 11 else 8 })
	end
	for _, piece in setPieces do
		if piece.layout == layout.id then
			table.insert(out, { x = piece.x, z = piece.z, r = M.RADIUS[piece.row] or 6 })
		end
	end
	local plan = M.plan(layout)
	for _, list in { plan.props, plan.fires } do
		for _, item in list do
			table.insert(out, { x = item.x, z = item.z, r = item.r })
		end
	end
	for _, lamp in plan.lamps do
		table.insert(out, { x = lamp.x, z = lamp.z, r = 1.5 })
	end
	for _, list in { M.BRIDGES, M.PLANKS } do
		for _, item in list do
			table.insert(out, { x = item.x, z = item.z, r = 8 })
		end
	end
	return out
end

--- Worn-earth cells (4-stud voxel cell origins) of the town's foot paths and patches: noise eats
--- into every rim, the path centre wanders a stud or two and its width breathes, so worn earth
--- never ends on a ruled line. Deterministic (math.noise), unique cells.
function M.worn(): { Point }
	local out: { Point } = {}
	local seen: { [string]: boolean } = {}
	local function add(x: number, z: number)
		local cx, cz = math.floor(x / 4) * 4, math.floor(z / 4) * 4
		local key = cx .. "," .. cz
		if not seen[key] then
			seen[key] = true
			table.insert(out, p(cx, cz))
		end
	end
	local function rim(x: number, z: number): number
		return 0.5 + 0.5 * math.noise(x / 7, z / 7, 3.1)
	end
	for _, disc in M.GROUND.discs do
		for cx = disc.x - disc.r, disc.x + disc.r, 4 do
			for cz = disc.z - disc.r, disc.z + disc.r, 4 do
				local d = math.sqrt((cx - disc.x) ^ 2 + (cz - disc.z) ^ 2)
				if d <= disc.r * (0.7 + 0.3 * rim(cx, cz)) then
					add(cx, cz)
				end
			end
		end
	end
	local lanes: { any } = { M.STREET }
	for _, lane in M.GROUND.lanes do
		table.insert(lanes, lane)
	end
	for _, lane in lanes do
		for index = 2, #lane.points do
			local a, b = lane.points[index - 1], lane.points[index]
			local dx, dz = b.x - a.x, b.z - a.z
			local length = math.sqrt(dx * dx + dz * dz)
			for s = 0, length, 2 do
				local x, z = a.x + dx * s / length, a.z + dz * s / length
				local sway = math.noise(x / 23, z / 23, 7.7) * 2
				local half = lane.width / 2 * (0.75 + 0.5 * rim(x, z))
				for w = -half, half, 2 do
					add(x - dz / length * (w + sway), z + dx / length * (w + sway))
				end
			end
		end
	end
	return out
end

export type Fence = { id: string, x: number, z: number, yaw: number }

--- Mud cells (4-stud voxel origins) of the street's two wheel ruts and the puddled square around
--- the arrival well: broken by noise so they read as wet tracks, never as painted stripes.
function M.ruts(): { Point }
	local out: { Point } = {}
	local seen: { [string]: boolean } = {}
	local function add(x: number, z: number)
		local cx, cz = math.floor(x / 4) * 4, math.floor(z / 4) * 4
		local key = cx .. "," .. cz
		if not seen[key] then
			seen[key] = true
			table.insert(out, p(cx, cz))
		end
	end
	local points = M.STREET.points
	for index = 2, #points do
		local a, b = points[index - 1], points[index]
		local dx, dz = b.x - a.x, b.z - a.z
		local length = math.sqrt(dx * dx + dz * dz)
		for s = 0, length, 4 do
			local x, z = a.x + dx * s / length, a.z + dz * s / length
			for _, side in { -3, 3 } do
				if math.noise(x / 9, z / 9 + side, 2.3) > -0.15 then
					add(x - dz / length * side, z + dx / length * side)
				end
			end
		end
	end
	for cx = -36, -6, 4 do
		for cz = 552, 576, 4 do
			if (cx + 21) ^ 2 + (cz - 564) ^ 2 < 140 and math.noise(cx / 7, cz / 7, 5.5) > -0.2 then
				add(cx, cz)
			end
		end
	end
	return out
end

--- town.plot-fence segments (8 studs, centred) around every yard; the street side keeps a gate gap.
function M.fences(): { Fence }
	local out: { Fence } = {}
	for index, pen in M.YARDS do
		local near = if pen.x0 > 0 then pen.x0 else pen.x1
		local far = if near == pen.x0 then pen.x1 else pen.x0
		local id = "yard." .. index .. "."
		for x = pen.x0 + M.FENCE / 2, pen.x1, M.FENCE do
			table.insert(out, { id = id .. "n." .. x, x = x, z = pen.z0, yaw = 180 })
			table.insert(out, { id = id .. "s." .. x, x = x, z = pen.z1, yaw = 0 })
		end
		for z = pen.z0 + M.FENCE / 2, pen.z1, M.FENCE do
			if math.abs(z - pen.gate) > M.GATE / 2 then
				table.insert(out, { id = id .. "gate-side." .. z, x = near, z = z, yaw = if near > 0 then -90 else 90 })
			end
			table.insert(out, { id = id .. "back." .. z, x = far, z = z, yaw = if near > 0 then 90 else -90 })
		end
	end
	return out
end

return M
