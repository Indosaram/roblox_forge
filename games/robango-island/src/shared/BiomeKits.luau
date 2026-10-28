--!strict
-- B1a biome kits: which mesh kit each role loads, a deterministic scatter plan (pure: Lune runs
-- it), and the Roblox adapters (server template loading + placement, client distance LOD).
-- Rows and per-screen targets come from the asset catalog (robango-durango-specs/asset-catalog.md
-- sections 2-3). Heights come from the shared terrain columns (ArchipelagoTerrain.columns), never
-- from a raycast, so placement works before the area streams in.
local M = {}
local runtime: any, load: any = getfenv(), require
local Rng = load(
	if runtime.game
		then runtime.game:GetService("ReplicatedStorage"):WaitForChild("Forge").core.domain.random.Rng
		else "../../../../core/domain/random/Rng"
)
-- B1b kit data (swamp, desert, tundra, volcano): rows are converted below; this module stays the
-- one loader for every kit.
local B1b = load(
	if runtime.game
		then runtime.game
			:GetService("ReplicatedStorage")
			:WaitForChild("Forge").games["robango-island"].src.shared.BiomeKitsB1b
		else "./BiomeKitsB1b"
)

-- Default-zoom landscape screen on the reference phone (catalog section 0): ~100 x 220 studs.
M.SCREEN_AREA = 100 * 220
-- Land rule: column tops at or below this are shore/sea (sea level is -4, beach top 2).
M.LAND_TOP = 0.5
-- Cliff rule: a column more than this above/below a neighbour (per stud) is a cliff face.
M.CLIFF_SLOPE = 0.3

-- Manifest keys of the uploaded packages (assets/manifest.yml -> Assets.luau).
M.packages = {
	beach = "kit-beach",
	jungle = "kit-jungle",
	grassland = "kit-grassland",
	savanna = "kit-savanna",
	lake = "kit-lake",
}

export type Row = {
	key: string,
	family: string,
	perScreen: number,
	scale: { number },
	mask: string?,
}

-- family -> client hide distance (studs) and whether it may cast a shadow (catalog LOD columns).
M.lod = {
	tree = { hide = 512, shadow = 200 },
	rock = { hide = 512, shadow = 200 },
	shrub = { hide = 384, shadow = 0 },
	fern = { hide = 256, shadow = 0 },
	grass = { hide = 160, shadow = 0 },
	clutter = { hide = 140, shadow = 0 },
}
-- Low profile (RenderBudget "low"): catalog lever 1 (grass 160 -> 120) and an instance cap.
M.lowProfile = { grassHide = 120, maxShown = 700 }

local function row(key: string, family: string, perScreen: number, lo: number, hi: number, mask: string?): Row
	return { key = key, family = family, perScreen = perScreen, scale = { lo, hi }, mask = mask }
end

-- perScreen = catalog midpoint. Masks: "band" grass bands, "edge" band borders, "open" off-band.
M.kits = {
	beach = {
		row("veg.beach.palm-tall", "tree", 4, 0.9, 1.1),
		row("veg.beach.palm-lean", "tree", 2, 0.9, 1.1),
		row("veg.beach.seagrape", "shrub", 6, 0.8, 1.2, "edge"),
		row("veg.beach.vine-mat", "fern", 6, 0.8, 1.2, "open"),
		row("veg.beach.dune-grass-a", "grass", 30, 0.8, 1.2, "band"),
		row("veg.beach.dune-grass-b", "grass", 15, 0.8, 1.2, "band"),
		row("rock.beach.tide-boulder", "rock", 3, 0.7, 1.2),
		row("rock.beach.pebble-scatter", "rock", 3, 0.8, 1.2, "open"),
		row("clutter.beach.leaf-litter", "clutter", 6, 0.8, 1.2),
		row("clutter.beach.gravel", "clutter", 6, 0.8, 1.2),
	},
	jungle = {
		row("veg.jungle.fan-palm", "tree", 3, 0.85, 1.15),
		row("veg.jungle.buttress-giant", "tree", 0.75, 0.9, 1.1, "open"),
		row("veg.jungle.buttress-giant-b", "tree", 0.75, 0.9, 1.1, "open"),
		row("veg.jungle.strangler", "tree", 0.75, 0.9, 1.1),
		row("veg.jungle.strangler-b", "tree", 0.75, 0.9, 1.1),
		row("veg.jungle.understory-broadleaf", "shrub", 8, 0.8, 1.2, "edge"),
		row("veg.jungle.red-ginger", "shrub", 4.5, 0.8, 1.2, "edge"),
		row("veg.jungle.tree-fern", "fern", 4.5, 0.8, 1.2),
		row("veg.jungle.ground-fern", "fern", 11, 0.8, 1.3, "edge"),
		row("veg.jungle.jungle-tall", "grass", 37, 0.85, 1.15, "band"),
		row("veg.jungle.elephant-grass", "grass", 15, 0.85, 1.15, "band"),
		row("rock.jungle.mossy-boulder", "rock", 3, 0.7, 1.2),
		row("rock.jungle.red-bank", "rock", 2, 0.8, 1.2),
		row("clutter.jungle.leaf-litter", "clutter", 10, 0.8, 1.2),
		row("clutter.jungle.gravel", "clutter", 4, 0.8, 1.2),
	},
	grassland = {
		row("veg.grassland.oak", "tree", 0.75, 0.85, 1.15, "open"),
		row("veg.grassland.oak-b", "tree", 0.75, 0.85, 1.15, "open"),
		row("veg.grassland.oak-c", "tree", 0.5, 0.85, 1.15, "open"),
		row("veg.grassland.birch", "tree", 1, 0.85, 1.15),
		row("veg.grassland.birch-b", "tree", 1, 0.85, 1.15),
		row("veg.grassland.hazel", "shrub", 6, 0.8, 1.2, "edge"),
		row("veg.grassland.bramble", "shrub", 6, 0.8, 1.2, "edge"),
		row("veg.grassland.bracken", "fern", 9, 0.8, 1.3, "edge"),
		row("veg.grassland.meadow", "grass", 45, 0.8, 1.2, "band"),
		row("veg.grassland.flower-patch", "grass", 15, 0.8, 1.2, "open"),
		row("rock.grassland.grey-boulder", "rock", 4, 0.7, 1.3),
		row("rock.grassland.boulder-cluster", "rock", 1.5, 0.9, 1.1, "open"),
		row("clutter.grassland.leaf-litter", "clutter", 6, 0.8, 1.2),
		row("clutter.grassland.gravel", "clutter", 6, 0.8, 1.2),
	},
	savanna = {
		row("veg.savanna.flat-top", "tree", 0.75, 0.85, 1.15, "open"),
		row("veg.savanna.flat-top-b", "tree", 0.75, 0.85, 1.15, "open"),
		row("veg.savanna.flat-top-c", "tree", 0.5, 0.85, 1.15, "open"),
		row("veg.savanna.bottle-trunk", "tree", 0.5, 0.9, 1.1, "open"),
		row("veg.savanna.thornbush", "shrub", 9, 0.8, 1.2, "edge"),
		row("veg.savanna.termite-mound", "shrub", 2, 0.8, 1.2, "open"),
		row("veg.savanna.dry-tuft", "fern", 9, 0.8, 1.3),
		row("veg.savanna.gold-tall", "grass", 45, 0.85, 1.15, "band"),
		row("veg.savanna.gold-short", "grass", 30, 0.8, 1.2, "open"),
		row("rock.savanna.kopje-slab", "rock", 1.5, 0.9, 1.1, "open"),
		row("rock.savanna.sun-boulder", "rock", 3, 0.8, 1.3),
		row("clutter.savanna.leaf-litter", "clutter", 4, 0.8, 1.2),
		row("clutter.savanna.gravel", "clutter", 8, 0.8, 1.2),
	},
	lake = {
		row("veg.lake.willow", "tree", 1.5, 0.9, 1.1),
		row("veg.lake.alder", "tree", 1, 0.85, 1.15),
		row("veg.lake.alder-b", "tree", 1, 0.85, 1.15),
		row("veg.lake.sedge-clump", "shrub", 9, 0.8, 1.2, "edge"),
		row("veg.lake.reed-card", "grass", 30, 0.85, 1.15, "band"),
		row("veg.lake.cattail-card", "grass", 15, 0.85, 1.15, "band"),
		row("rock.lake.river-stones", "rock", 3, 0.8, 1.2),
		row("clutter.lake.leaf-litter", "clutter", 6, 0.8, 1.2),
		row("clutter.lake.gravel", "clutter", 6, 0.8, 1.2),
	},
} :: { [string]: { Row } }

-- B1b rows -> B1a rows: perScreen is the midpoint of B1b's {min, max} density, masks follow the
-- B1a convention (grass in bands, shrubs on band edges), and scale jitter is +-10% for trees and
-- +-20% otherwise. B1b packages name each MeshPart `model` (dots/dashes as underscores), so the
-- loader aliases that name to the row key.
M.modelKey = {} :: { [string]: string }
for kit, data in B1b.kits do
	M.packages[kit] = data.package
	local rows = {}
	for _, entry in data.rows do
		local tree = entry.family == "tree"
		local mask = if entry.family == "grass" then "band" elseif entry.family == "shrub" then "edge" else nil
		local perScreen = (entry.density[1] + entry.density[2]) / 2
		table.insert(
			rows,
			row(entry.key, entry.family, perScreen, if tree then 0.9 else 0.8, if tree then 1.1 else 1.2, mask)
		)
		M.modelKey[entry.model] = entry.key
	end
	M.kits[kit] = rows
end

-- Catalog section 2 kit map. Beach coves (sand-edged land columns) use the beach kit on every
-- role that loads it. Swamp/desert/snow/volcano roles use the B1b kit of their first biome.
function M.kitsFor(layout: any): { string }
	local id = layout.id
	if id == "rw.onboarding" then
		return { "grassland", "jungle", "beach" }
	elseif id == "rw.harbor" then
		return { "beach" }
	elseif id == "rw.a1.s3" or id == "rw.explore20" then
		return { "savanna", "beach" }
	elseif id == "rw.a1.s2" then
		return { "lake", "grassland", "beach" }
	end
	local first = layout.biomes[1]
	if first == "tropical" then
		return { "jungle", "beach" }
	elseif first == "grassland" or first == "forest" or first == "beach" then
		return { "grassland", "beach" }
	elseif B1b.biomeKit[first] then
		return { B1b.biomeKit[first], "beach" }
	end
	return { "beach" }
end

-- Shared terrain height lookup over ArchipelagoTerrain.columns.
export type Ground = {
	top: (x: number, z: number) -> number?,
	slope: (x: number, z: number) -> number,
	beach: (x: number, z: number) -> boolean,
}
function M.ground(columns: { any }, sandInland: boolean?): Ground
	local cell = if columns[1] then columns[1].cell else 32
	local byKey: { [string]: any } = {}
	for _, column in columns do
		byKey[column.x .. "," .. column.z] = column
	end
	local function at(x: number, z: number): (any, number, number)
		local ox, oz = columns[1] and columns[1].x or 0, columns[1] and columns[1].z or 0
		local cx = ox + math.floor((x - ox) / cell + 0.5) * cell
		local cz = oz + math.floor((z - oz) / cell + 0.5) * cell
		return byKey[cx .. "," .. cz], cx, cz
	end
	local ground = {}
	function ground.top(x: number, z: number): number?
		local column = at(x, z)
		return if column then column.top else nil
	end
	-- Slope depends only on the snapped column: computed once per column (the scatter asks per try).
	local slopes: { [any]: number } = {}
	function ground.slope(x: number, z: number): number
		local column, cx, cz = at(x, z)
		if not column then
			return math.huge
		end
		local cached = slopes[column]
		if cached then
			return cached
		end
		local worst = 0
		for dx = -1, 1 do
			for dz = -1, 1 do
				local other = byKey[cx + dx * cell .. "," .. cz + dz * cell]
				local top = if other then other.top else -12
				local distance = cell * math.sqrt(dx * dx + dz * dz)
				if distance > 0 then
					worst = math.max(worst, math.abs(top - column.top) / distance)
				end
			end
		end
		slopes[column] = worst
		return worst
	end
	function ground.beach(x: number, z: number): boolean
		local column = at(x, z)
		return column ~= nil and (column.beach == true or (not sandInland and column.material == "Sand"))
	end
	return ground
end

export type Placement = {
	key: string,
	kit: string,
	family: string,
	x: number,
	y: number,
	z: number,
	yaw: number,
	scale: number,
}

-- Value noise from the seeded stream (no math.noise: Lune and Roblox must agree bit for bit).
local function lattice(rng: any, size: number): (number, number) -> number
	local values = {}
	for i = 1, size * size do
		values[i] = rng:nextNumber()
	end
	return function(u: number, v: number): number
		local x, z = u % size, v % size
		local x0, z0 = math.floor(x), math.floor(z)
		local fx, fz = x - x0, z - z0
		fx, fz = fx * fx * (3 - 2 * fx), fz * fz * (3 - 2 * fz)
		local function g(a: number, b: number): number
			return values[(a % size) * size + (b % size) + 1]
		end
		local top = g(x0, z0) + (g(x0 + 1, z0) - g(x0, z0)) * fx
		local bottom = g(x0, z0 + 1) + (g(x0 + 1, z0 + 1) - g(x0, z0 + 1)) * fx
		return top + (bottom - top) * fz
	end
end

--- Whether (x, z) may hold a kit instance: dry land, not a cliff, off the walkable path ribbon,
--- spawn circles and anchors, and clear of gather nodes. Kits use their own narrow clearance, not
--- ArchipelagoTerrain.protected (its 80-stud spawn reserve was sized for primitive props and
--- leaves the onboarding island bare); tall grass may flank a path as in R03-3.
function M.allowed(layout: any, terrain: any, ground: Ground, x: number, z: number, clearance: number): boolean
	local top = ground.top(x, z)
	if top == nil or top <= M.LAND_TOP then
		return false
	end
	if ground.slope(x, z) > M.CLIFF_SLOPE then
		return false
	end
	for _, path in layout.paths do
		for i = 2, #path.points do
			if terrain.distance(x, z, path.points[i - 1], path.points[i]) <= path.width / 2 + 2 + clearance then
				return false
			end
		end
	end
	for _, spawn in layout.spawns do
		if (x - spawn.position.x) ^ 2 + (z - spawn.position.z) ^ 2 <= (spawn.radius + clearance) ^ 2 then
			return false
		end
	end
	for _, anchor in layout.anchors do
		local radius = if anchor.id == "objective" then 24 else 12
		if (x - anchor.position.x) ^ 2 + (z - anchor.position.z) ^ 2 <= (radius + clearance) ^ 2 then
			return false
		end
	end
	for _, node in layout.resourceNodes do
		if (x - node.position.x) ^ 2 + (z - node.position.z) ^ 2 < (6 + clearance) ^ 2 then
			return false
		end
	end
	return true
end

-- D2 F3: tall families stay out of an arrival clearing so the opening camera sees the player.
-- The cold open frames the spawn from 150-260 studs at a 35-40 degree pitch (OpeningClient.shot),
-- the play camera from 95 studs at 57 degrees. A tree at flat distance d hides the spawn on the
-- shallowest (35 degree) sight line unless its crown's near edge clears it:
-- (d - crown radius) * tan(35) >= tree top. L3 caps the hero trees near 30 studs: the worst row is
-- veg.grassland.oak-c (29.8 studs, x1.15 scale jitter = 34.3) and the widest crown
-- veg.jungle.buttress-giant (28.3 studs across, x1.1 = 15.6 radius), so the sight line clears from
-- 34.3 / tan(35) + 15.6 = 64.6 studs. 68 keeps a small margin; the old 112 was the same rule for
-- a 60-stud canopy and left the spawn in an empty field. Rocks top out near 20 studs (a 16-stud
-- slab at scale 1.2). Radii are flat studs from each arrival point.
M.ARRIVAL_SIGHT = { pitch = 35, treeTop = 29.8 * 1.15, crownRadius = 28.3 * 1.1 / 2 }
M.ARRIVAL_CLEAR = { tree = 68, rock = 40 } :: { [string]: number }

--- Archipelago stage arrival (RoleWorld spawn): beside the nearest yard gather node, inside its
--- 8-stud prompt range, 32 studs up the `.main` path from its third point. nil on other roles.
function M.yard(layout: any): { x: number, y: number, z: number }?
	if not string.match(layout.id, "^rw%.a%d+%.s%d+$") then
		return nil
	end
	local result = nil
	for _, path in layout.paths do
		if string.sub(path.id, -5) ~= ".main" then
			continue
		end
		local y, q = path.points[3], path.points[2]
		local dx, dz = q.x - y.x, q.z - y.z
		local length = math.sqrt(dx * dx + dz * dz)
		local ax, az = y.x + dx / length * 32, y.z + dz / length * 32
		local nearest, best = nil, math.huge
		for _, node in layout.resourceNodes do
			local d = math.sqrt((node.position.x - ax) ^ 2 + (node.position.z - az) ^ 2)
			if
				d < best
				and not string.find(node.id, ".cargo.", 1, true)
				and not string.find(node.id, ".chapter.", 1, true)
			then
				nearest, best = node, d
			end
		end
		if nearest and best > 0 then
			local px, pz = nearest.position.x, nearest.position.z
			ax, az = px + (ax - px) / best * 5, pz + (az - pz) / best * 5
		end
		result = { x = ax, y = y.y, z = az }
	end
	return result
end

--- Where players arrive on a role: the entry anchor (else the first anchor) plus the stage yard.
function M.arrivals(layout: any): { { x: number, z: number } }
	local entry = layout.anchors[1] and layout.anchors[1].position
	for _, anchor in layout.anchors do
		if anchor.id == "entry" then
			entry = anchor.position
		end
	end
	local result = {}
	if entry then
		table.insert(result, { x = entry.x, z = entry.z })
	end
	local yard = M.yard(layout)
	if yard then
		table.insert(result, { x = yard.x, z = yard.z })
	end
	return result
end

--- Deterministic scatter for one role: same layout + columns + seed -> same placements.
function M.plan(layout: any, columns: { any }, seed: number, terrain: any): { Placement }
	local kits = M.kitsFor(layout)
	local arrivals = M.arrivals(layout)
	local function crowdsArrival(family: string, x: number, z: number): boolean
		local radius = M.ARRIVAL_CLEAR[family]
		if not radius then
			return false
		end
		for _, point in arrivals do
			if (x - point.x) ^ 2 + (z - point.z) ^ 2 < radius * radius then
				return true
			end
		end
		return false
	end
	-- Desert islands are Sand throughout: only the terrain's beach flag marks their rim.
	local ground = M.ground(columns, kits[1] == "desert")
	local result: { Placement } = {}
	if #columns == 0 then
		return result
	end
	local low, high = layout.bounds.min, layout.bounds.max
	local grow = columns[1].cell * 2
	local x0, x1, z0, z1 = low.x - grow, high.x + grow, low.z - grow, high.z + grow
	local landArea = 0
	for _, column in columns do
		if column.top > M.LAND_TOP then
			landArea += column.cell * column.cell
		end
	end
	local stream = Rng.new(seed):fork("biome-kits:" .. layout.id)
	local bands = lattice(stream:fork("bands"), 16)
	-- fork() never advances `stream`, so the region lattice is the same for every candidate: build it once.
	local regions = lattice(stream:fork("regions"), 4)
	for kitIndex, kit in kits do
		-- Beach is a rim kit unless it is the role's only kit (harbor), where it dresses all land.
		local beachKit = kit == "beach" and #kits > 1
		local share = if beachKit
			then 1
			else 1 / math.max(1, #kits - (if #kits > 1 and table.find(kits, "beach") then 1 else 0))
		local rng = stream:fork(kit)
		for _, entry in M.kits[kit] do
			local wanted = math.floor(entry.perScreen * landArea / M.SCREEN_AREA * share + 0.5)
			if beachKit then
				-- Coves are a thin rim: scale the beach kit by the rim's share of the land.
				wanted = math.floor(wanted * 0.15 + 0.5)
			end
			local placed, tries = 0, 0
			local clearance = if entry.family == "tree" then 4 else if entry.family == "grass" then 1 else 2
			-- Stratified sampling: candidates walk a jittered grid sized to the wanted count, so a
			-- 3072-stud relief island has no screen-sized holes that pure uniform scatter leaves.
			local gx = math.max(1, math.ceil(math.sqrt(math.max(wanted, 1) * (x1 - x0) / (z1 - z0))))
			local gz = math.max(1, math.ceil(math.max(wanted, 1) / gx))
			local cw, ch = (x1 - x0) / gx, (z1 - z0) / gz
			while placed < wanted and tries < wanted * 8 do
				local cell = tries % (gx * gz)
				tries += 1
				local x = x0 + (cell % gx + rng:nextNumber()) * cw
				local z = z0 + (cell // gx + rng:nextNumber()) * ch
				local yaw = rng:nextNumber() * 360
				local scale = entry.scale[1] + rng:nextNumber() * (entry.scale[2] - entry.scale[1])
				if not M.allowed(layout, terrain, ground, x, z, clearance) or crowdsArrival(entry.family, x, z) then
					continue
				end
				if #kits > 1 and ground.beach(x, z) ~= beachKit then
					continue
				end
				-- Multi-kit roles split the island into seeded kit regions (onboarding/lake roles).
				if not beachKit and #kits > 2 then
					local span = math.min(160, (x1 - x0) / 3)
					local region = regions((x - x0) / span, (z - z0) / span)
					local inland = #kits - 1
					if math.min(inland, math.floor(region * inland) + 1) ~= kitIndex then
						continue
					end
				end
				local band = bands(x / 48, z / 48)
				if entry.mask == "band" and band < 0.45 then
					continue
				elseif entry.mask == "edge" and math.abs(band - 0.45) > 0.12 then
					continue
				elseif entry.mask == "open" and band >= 0.45 then
					continue
				end
				placed += 1
				table.insert(result, {
					key = entry.key,
					kit = kit,
					family = entry.family,
					x = x,
					y = ground.top(x, z) :: number,
					z = z,
					yaw = yaw,
					scale = scale,
				})
			end
		end
	end
	return result
end

--- Client LOD verdict for one instance at `distance` from the camera focus.
function M.visible(family: string, distance: number, low: boolean): boolean
	local hide = M.lod[family].hide
	if low and family == "grass" then
		hide = M.lowProfile.grassHide
	end
	return distance <= hide
end

-- ------------------------------------------------------------------ Roblox adapters
local templates: { [string]: any } = {}
local loading: { [string]: boolean } = {}

-- Every kit this module can place. Role worlds load only BiomeKits.kitsFor(layout) (D1: the
-- server no longer preloads all nine at start).
M.allKits = { "beach", "jungle", "grassland", "savanna", "lake", "swamp", "desert", "tundra", "volcano" }

-- D1 (G21) placement budget. Placements go in nearest the spawn first: the first batch is the
-- spawn screen and its surroundings (at most KIT_FIRST_MAX within KIT_FIRST_RADIUS studs), placed
-- right away; the rest follow KIT_BATCH per engine step, so no frame clones a whole island.
M.KIT_FIRST_RADIUS = 128
M.KIT_FIRST_MAX = 400
M.KIT_BATCH = 300

--- Splits a plan into placement batches ordered by flat distance to `origin` (ties keep plan
--- order, so the result is deterministic): batch 1 per the first-batch budget, then KIT_BATCH each.
function M.batches(placements: { Placement }, origin: { x: number, z: number }): { { Placement } }
	local order = table.create(#placements)
	local distance = table.create(#placements)
	for index, p in placements do
		order[index] = index
		distance[index] = (p.x - origin.x) ^ 2 + (p.z - origin.z) ^ 2
	end
	table.sort(order, function(a, b)
		return if distance[a] ~= distance[b] then distance[a] < distance[b] else a < b
	end)
	local batches: { { Placement } } = {}
	local current: { Placement } = {}
	local first = true
	for _, index in order do
		local full = if first
			then #current >= M.KIT_FIRST_MAX or distance[index] > M.KIT_FIRST_RADIUS ^ 2
			else #current >= M.KIT_BATCH
		if full then
			table.insert(batches, current)
			current, first = {}, false
		end
		table.insert(current, placements[index])
	end
	if #current > 0 or first then
		table.insert(batches, current)
	end
	return batches
end

local function loadKit(insert: any, kit: string, id: number)
	loading[kit] = true
	local ok, model = pcall(insert.LoadAsset, insert, id)
	loading[kit] = nil
	if ok and model then
		templates["@" .. kit] = model
		for _, child in model:GetDescendants() do
			if child:IsA("BasePart") then
				templates[M.modelKey[child.Name] or child.Name] = child
			end
		end
	else
		warn("BiomeKits: package " .. kit .. " did not load: " .. tostring(model))
	end
end

--- Server: loads each needed package once (InsertService, owned by the universe creator) and
--- returns key -> template. A failed load leaves that kit out; the world still builds. The
--- packages load in parallel; a load already in flight (started earlier by the role build) is
--- awaited, never repeated.
function M.load(kits: { string }, assets: { [string]: string }): { [string]: any }
	-- Headless engines (Lune specs, native qa) have no InsertService: no kits, the world still builds.
	local hasInsert, insert = pcall(function()
		return runtime.game:GetService("InsertService")
	end)
	if not hasInsert or insert == nil then
		return templates
	end
	for _, kit in kits do
		local id = tonumber(string.match(assets[M.packages[kit]] or "", "%d+$") or "")
		if id and not templates["@" .. kit] and not loading[kit] then
			task.spawn(loadKit, insert, kit, id)
		end
	end
	for _, kit in kits do
		while loading[kit] do
			task.wait()
		end
	end
	return templates
end

--- Server: clones templates for every placement under `parent` (a Folder named ForgeBiomeKits).
--- `surface(x, z)` is the rendered terrain top there (a server raycast). Voxel terrain rounds a
--- FillBlock top up to the 4-stud voxel grid (column top 2.0 renders at 4.0), so the planned
--- column top alone buries short rows (clutter, ferns, rocks, meadow grass) under the grass.
--- `offset` numbers ForgeKitIndex across batches.
function M.place(
	parent: any,
	placements: { Placement },
	loaded: { [string]: any },
	surface: ((x: number, z: number) -> number?)?,
	offset: number?
): number
	local count = 0
	for index, p in placements do
		local template = loaded[p.key]
		if not template then
			continue
		end
		local part = template:Clone()
		part.Anchored, part.CanCollide, part.CanTouch = true, false, false
		part.CanQuery = p.family == "tree" or p.family == "rock"
		part.CastShadow = p.family == "tree" or p.family == "rock"
		part.Size = template.Size * p.scale
		local y = if surface then surface(p.x, p.z) or p.y else p.y
		-- Sink 0.3 studs so card bases and rock skirts never float on the voxel surface; flat ground
		-- cards (leaf litter, gravel: ~0.02 thick) would vanish under it, so they ride 0.05 above.
		local sink = if part.Size.Y < 0.6 then -0.05 else 0.3
		part.CFrame = CFrame.new(p.x, y + part.Size.Y / 2 - sink, p.z) * CFrame.Angles(0, math.rad(p.yaw), 0)
		part.Name = p.key
		part:SetAttribute("ForgeKitFamily", p.family)
		part:SetAttribute("ForgeKitIndex", (offset or 0) + index)
		part.Parent = parent
		count += 1
	end
	return count
end

--- Client: distance LOD + low-profile cap over the replicated ForgeBiomeKits folder. A hidden
--- instance stays in place with LocalTransparencyModifier 1 (not drawn), so StreamingEnabled can
--- still evict it; a part the engine streams out (Parent nil) is dropped from the list. D1: the old
--- client-only holder kept every hidden card out of streaming's reach and re-parented streamed-out
--- parts back, so client memory grew with every stud walked.
function M.runLod(folder: any, low: boolean)
	local all: { any } = {}
	local function track(child: any)
		if child:IsA("BasePart") and child:GetAttribute("ForgeKitFamily") then
			table.insert(all, child)
		end
	end
	for _, child in folder:GetChildren() do
		track(child)
	end
	folder.ChildAdded:Connect(track)
	task.spawn(function()
		while folder.Parent do
			local camera = runtime.workspace.CurrentCamera
			local focus = camera and camera.Focus.Position or Vector3.zero
			local shown = 0
			local kept = table.create(#all)
			for _, part in all do
				if part.Parent == nil then
					continue
				end
				table.insert(kept, part)
				local family = part:GetAttribute("ForgeKitFamily")
				local distance = (part.Position - focus).Magnitude
				local keep = M.visible(family, distance, low) and (not low or shown < M.lowProfile.maxShown)
				if keep then
					shown += 1
				end
				part.LocalTransparencyModifier = if keep then 0 else 1
				part.CastShadow = keep and not low and distance <= M.lod[family].shadow
			end
			all = kept
			task.wait(0.5)
		end
	end)
end

return M
