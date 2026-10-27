--!strict
local Rng = require("../random/Rng")
local M = {}
local materials = {
	grassland = "Grass",
	forest = "LeafyGrass",
	tropical = "LeafyGrass",
	swamp = "Mud",
	desert = "Sand",
	snow = "Snow",
	volcano = "Basalt",
}

function M.distance(x: number, z: number, a: any, b: any): (number, number)
	local dx, dz = b.x - a.x, b.z - a.z
	local length = dx * dx + dz * dz
	local t = if length == 0 then 0 else math.clamp(((x - a.x) * dx + (z - a.z) * dz) / length, 0, 1)
	return math.sqrt((x - a.x - dx * t) ^ 2 + (z - a.z - dz * t) ^ 2), t
end

-- The same clearance predicate controls both shore erosion and prop scattering.
function M.protected(layout: any, x: number, z: number, margin: number): boolean
	for _, path in layout.paths do
		for i = 2, #path.points do
			if M.distance(x, z, path.points[i - 1], path.points[i]) <= path.width / 2 + margin then
				return true
			end
		end
	end
	for _, spawn in layout.spawns do
		if (x - spawn.position.x) ^ 2 + (z - spawn.position.z) ^ 2 <= (math.max(80, spawn.radius) + margin) ^ 2 then
			return true
		end
	end
	for _, anchor in layout.anchors do
		local radius = if anchor.id == "objective" then 40 else 24
		if (x - anchor.position.x) ^ 2 + (z - anchor.position.z) ^ 2 <= (radius + margin) ^ 2 then
			return true
		end
	end
	return false
end
-- Survey markers start on the dry main trail 64 studs past the resource yard,
-- toward the objective, so the first one is in sight of the trail spawn.
function M.survey(layout: any, index: number): any
	for _, path in layout.paths do
		if string.sub(path.id, -5) == ".main" then
			local a, b = path.points[3], path.points[4]
			local dx, dz = b.x - a.x, b.z - a.z
			local t = 64 / math.sqrt(dx * dx + dz * dz)
			local x, z = a.x + dx * t + (index - 1) * 12, a.z + dz * t
			if index > 3 then
				x, z = a.x + dx * t + (index - 4) * 12 + 6, z - 12
			end
			return { x = x, y = a.y + (b.y - a.y) * t, z = z }
		end
	end
	error("SURVEY_TRAIL_MISSING:" .. layout.id)
end
-- Harbor and archipelago stages get an organic coast: a seeded lobed radius per angle,
-- widened by a round lobe around every authored gameplay point so all of them stay on land.
function M.organic(layout: any): boolean
	return layout.id == "rw.harbor" or string.match(layout.id, "^rw%.a%d+%.s%d+$") ~= nil
end

-- Opt-in relief generator: a layout whose data carries `terrain = { generator = "relief", seed, relief }`
-- gets the multi-octave height field below. Every other layout keeps the legacy columns byte for byte.
function M.relief(layout: any): boolean
	return layout.terrain ~= nil and layout.terrain.generator == "relief"
end

-- Frontier regions keep their square-column world but get the same graded height field, so
-- their bypass ramps beside the high station yard are walkable.
function M.graded(layout: any): boolean
	return M.organic(layout) or string.match(layout.id, "^rw%.frontier%d+$") ~= nil
end

local function smooth(edge0: number, edge1: number, value: number): number
	local t = math.clamp((value - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Normalised polar coast: `radius(angle)` in bounds-normalised units, `depth(x, z)` is how far
-- inside the coast a world point is (negative offshore), `point(angle)` the world coast point.
function M.coast(layout: any, seed: number): any
	local hx = math.max(math.abs(layout.bounds.min.x), math.abs(layout.bounds.max.x))
	local hz = math.max(math.abs(layout.bounds.min.z), math.abs(layout.bounds.max.z))
	local unit = math.min(hx, hz)
	local rng = Rng.new(seed):fork(layout.id .. ":coast")
	local base = 0.8 + rng:nextNumber() * 0.06
	local waves = {}
	for k = 2, 6 do
		table.insert(
			waves,
			{ k = k, a = (0.03 + rng:nextNumber() * 0.05) * 3 / (k + 1), p = rng:nextNumber() * math.pi * 2 }
		)
	end
	local discs = {}
	local function keep(p: any, margin: number)
		local nx, nz = p.x / hx, p.z / hz
		table.insert(discs, { rho = math.sqrt(nx * nx + nz * nz), phi = math.atan2(nz, nx), r = margin / unit })
	end
	-- High authored points keep room to ramp down to the beach at COAST_SLOPE, so their
	-- ground never ends in a wall at the coast.
	local function rise(p: any): number
		return 16 + math.max(0, p.y - M.BEACH_TOP) / M.COAST_SLOPE
	end
	for _, node in layout.resourceNodes do
		keep(node.position, math.max(48, rise(node.position)))
	end
	for _, anchor in layout.anchors do
		keep(anchor.position, math.max(if anchor.id == "objective" then 96 else 56, rise(anchor.position)))
	end
	for _, spawn in layout.spawns do
		keep(spawn.position, math.max(spawn.radius + 48, rise(spawn.position)))
	end
	for _, hazard in layout.hazards or {} do
		keep(hazard.position, (hazard.radius or 8) + 40)
	end
	for _, refuge in layout.refuges or {} do
		local low, high = refuge.bounds.min, refuge.bounds.max
		local half = math.sqrt((high.x - low.x) ^ 2 + (high.z - low.z) ^ 2) / 2
		keep({ x = (low.x + high.x) / 2, z = (low.z + high.z) / 2 }, half + 24)
	end
	for _, path in layout.paths do
		for i = 2, #path.points do
			local a, b = path.points[i - 1], path.points[i]
			local steps = math.max(1, math.ceil(math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) / 24))
			for s = 0, steps do
				local t = s / steps
				keep({ x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t }, path.width / 2 + 40)
			end
		end
	end
	local coast = { hx = hx, hz = hz, unit = unit }
	function coast.radius(angle: number): number
		local r = base
		for _, wave in waves do
			r += wave.a * math.sin(wave.k * angle + wave.p)
		end
		for _, disc in discs do
			local delta = angle - disc.phi
			local side = disc.rho * math.sin(delta)
			if math.abs(side) < disc.r then
				r = math.max(r, disc.rho * math.cos(delta) + math.sqrt(disc.r * disc.r - side * side))
			end
		end
		return r
	end
	function coast.depth(x: number, z: number): number
		local nx, nz = x / hx, z / hz
		return coast.radius(math.atan2(nz, nx)) - math.sqrt(nx * nx + nz * nz)
	end
	-- `inset` (normalised) walks the contour that far inside the coast, e.g. the grass edge.
	function coast.point(angle: number, inset: number?): (number, number)
		local r = coast.radius(angle) - (inset or 0)
		return r * math.cos(angle) * hx, r * math.sin(angle) * hz
	end
	return coast
end

-- Organic islands: the grass edge is the coast contour inset by GRASS_EDGE (normalised depth).
-- Columns hold BEACH_TOP out to M.band(coast, cell); adapters paint sand discs over 0..band
-- (hiding the square column edges) and then grass discs over GRASS_EDGE..band, so the visible
-- grass/sand boundary is the inset coast curve rather than the column grid.
M.GRASS_EDGE = 0.09
M.BEACH_TOP = 2

-- Height gained per stud inland from the coast (studs/stud) where authored ground meets the beach.
M.COAST_SLOPE = 0.33

-- True when the square column at (x, z) contains an authored node, anchor or spawn point.
function M.pinned(layout: any, x: number, z: number, cell: number): boolean
	for _, list in { layout.resourceNodes, layout.anchors, layout.spawns } do
		for _, item in list do
			local p = item.position
			if math.abs(p.x - x) <= cell / 2 and math.abs(p.z - z) <= cell / 2 then
				return true
			end
		end
	end
	return false
end

-- Largest height difference between 8-neighbouring organic columns, as a fraction of the cell:
-- 6 studs per 32-stud column (0.19 studs/stud). Adapters draw a graded rise as concentric
-- terraces of at most 2 studs, so a character walks it without jumping.
M.GRADE = 6 / 32

-- Grades the organic height field toward 8-neighbouring columns differing by at most
-- GRADE * cell. It only raises: low ground beside higher ground becomes a ramp, never above the
-- coastal ramp cap, while the beach band and authored points keep their height. Without a coast
-- (frontiers) only land columns are graded and the ceiling comes from authored points alone.
local function grade(layout: any, coast: any?, columns: { any }, cell: number)
	local step = M.GRADE * cell
	local byKey: { [string]: any } = {}
	for _, column in columns do
		byKey[column.x .. "," .. column.z] = column
	end
	local band = if coast then M.band(coast, cell) else 0
	-- The ceiling grows from the beach band, the coastal ramp cap and authored points by one step
	-- per cell, so raised ground never walls off the beach; it never cuts below original ground.
	local ceiling: { [any]: number } = {}
	for _, column in columns do
		local depth = if coast then coast.depth(column.x, column.z) else math.huge
		ceiling[column] = if M.pinned(layout, column.x, column.z, cell)
			then column.top
			elseif not coast then math.huge
			elseif depth < band and column.top <= M.BEACH_TOP + 0.01 then M.BEACH_TOP
			else M.BEACH_TOP + math.max(0, depth * coast.unit - cell / 2) * M.COAST_SLOPE
	end
	local function relax(value: { [any]: number }, toward: (any, any) -> number?)
		local changed = true
		while changed do
			changed = false
			for _, column in columns do
				for dx = -1, 1 do
					for dz = -1, 1 do
						local other = byKey[column.x + dx * cell .. "," .. column.z + dz * cell]
						local target = if other then toward(column, other) else nil
						if target and math.abs(target - value[column]) > 1e-6 then
							value[column] = target
							changed = true
						end
					end
				end
			end
		end
	end
	relax(ceiling, function(column, other)
		return if ceiling[other] + step < ceiling[column] then ceiling[other] + step else nil
	end)
	if not coast then
		-- A raised column's outer terraces reach 0.95 cell from its centre; a lower authored point
		-- in that reach caps the column at the point's height, so the terraces never bury it.
		-- The cap grows one step per cell; unlike organic grading this may lower unpinned ground.
		for _, column in columns do
			for _, list in { layout.resourceNodes, layout.anchors, layout.spawns } do
				for _, item in list do
					local p = item.position
					local inside = math.abs(p.x - column.x) <= cell / 2 and math.abs(p.z - column.z) <= cell / 2
					if not inside and (p.x - column.x) ^ 2 + (p.z - column.z) ^ 2 <= (cell * 0.95) ^ 2 then
						ceiling[column] = math.min(ceiling[column], p.y)
					end
				end
			end
		end
		relax(ceiling, function(column, other)
			return if ceiling[other] + step < ceiling[column] then ceiling[other] + step else nil
		end)
	end
	local tops: { [any]: number } = {}
	local original: { [any]: number } = {}
	for _, column in columns do
		original[column] = column.top
		if not coast then
			-- Square-column shore and sea are never raised; pinned columns keep their height.
			local pinned = M.pinned(layout, column.x, column.z, cell)
			ceiling[column] = if column.top <= 0 or pinned then column.top else ceiling[column]
			column.top = math.min(column.top, ceiling[column])
		else
			ceiling[column] = math.max(ceiling[column], column.top)
		end
		tops[column] = column.top
	end
	relax(tops, function(column, other)
		local target = math.min(tops[other] - step, ceiling[column])
		return if target > tops[column] then target else nil
	end)
	for _, column in columns do
		if coast or original[column] ~= tops[column] then
			column.top = tops[column]
			column.material = if column.top < 0 or column.beach then "Sand" else M.ground(layout, column.x)
		end
	end
end

function M.band(coast: any, cell: number): number
	return M.GRASS_EDGE + cell * 1.5 / coast.unit
end

function M.ground(layout: any, x: number): string
	return if table.find(layout.biomes, "volcano") and x < 0 then "Basalt" else materials[layout.biomes[1]] or "Grass"
end

-- Authored heights for the organic height field: path samples, nodes, anchors, spawns.
local function authored(layout: any): { any }
	local samples = {}
	for _, path in layout.paths do
		for i = 2, #path.points do
			local a, b = path.points[i - 1], path.points[i]
			local steps = math.max(1, math.ceil(math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) / 32))
			for s = 0, steps do
				local t = s / steps
				table.insert(
					samples,
					{ x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
				)
			end
		end
	end
	for _, list in { layout.resourceNodes, layout.anchors, layout.spawns } do
		for _, item in list do
			table.insert(samples, item.position)
		end
	end
	return samples
end

-- Relief field constants (studs). SEA is the water surface the role adapters fill to.
M.SEA = -4
M.CLIFF_STEP = 12
M.TRAIL_WIDTH = 10
M.TRAIL_SLOPE = 0.3
M.STREAM_WIDTH = 14
-- Steepest ground rise (studs per stud) next to authored points and paths.
M.GRADE_CAP = 0.35

local function segments(x: number, z: number, points: { any }): (number, number)
	local best, at = math.huge, 1
	for i = 2, #points do
		local d = M.distance(x, z, points[i - 1], points[i])
		if d < best then
			best, at = d, i
		end
	end
	return best, at
end

local function along(x: number, z: number, points: { any }): (number, number)
	local d, i = segments(x, z, points)
	local _, t = M.distance(x, z, points[i - 1], points[i])
	return d, points[i - 1].y + (points[i].y - points[i - 1].y) * t
end

-- Densifies a polyline every `step` studs, sampling y from `height`.
local function densify(points: { any }, step: number, height: (number, number) -> number): { any }
	local out = {}
	for i = 2, #points do
		local a, b = points[i - 1], points[i]
		local n = math.max(1, math.ceil(math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) / step))
		for s = if i == 2 then 0 else 1, n do
			local x, z = a.x + (b.x - a.x) * s / n, a.z + (b.z - a.z) * s / n
			table.insert(out, { x = x, y = height(x, z), z = z })
		end
	end
	return out
end

function M.length(points: { any }): number
	local total = 0
	for i = 2, #points do
		total += math.sqrt((points[i].x - points[i - 1].x) ^ 2 + (points[i].z - points[i - 1].z) ^ 2)
	end
	return total
end

local fields: { [string]: any } = setmetatable({}, { __mode = "v" }) :: any

--- The relief height field of an opted-in layout. The route `seed` and the island seed recorded in
--- the layout data (`terrain.seed`) together fix the island: the same pair always gives the same
--- field. Returns { coast, height(x, z), water(x, z), trails, streams, ponds, relief }.
function M.field(layout: any, seed: number): any
	local key = layout.id .. ":" .. seed .. ":" .. layout.terrain.seed
	if fields[key] then
		return fields[key]
	end
	local mixed = (seed * 1000003 + layout.terrain.seed) % 2147483647
	local rng = Rng.new(mixed):fork(layout.id .. ":relief")
	-- The relief coast is tabulated per angle (2048 steps, linear between), so the many depth
	-- queries of a 3072-stud island do not rescan every authored keep-disc.
	local exact = M.coast(layout, mixed)
	local STEPS = 2048
	local table_ = table.create(STEPS + 1, 0)
	for i = 0, STEPS do
		table_[i + 1] = exact.radius(-math.pi + i * 2 * math.pi / STEPS)
	end
	local coast: any = { hx = exact.hx, hz = exact.hz, unit = exact.unit }
	function coast.radius(angle: number): number
		local f = ((angle + math.pi) % (2 * math.pi)) / (2 * math.pi) * STEPS
		local i = math.clamp(math.floor(f), 0, STEPS - 1)
		return table_[i + 1] + (table_[i + 2] - table_[i + 1]) * (f - i)
	end
	function coast.depth(x: number, z: number): number
		local nx, nz = x / coast.hx, z / coast.hz
		return coast.radius(math.atan2(nz, nx)) - math.sqrt(nx * nx + nz * nz)
	end
	function coast.point(angle: number, inset: number?): (number, number)
		local r = coast.radius(angle) - (inset or 0)
		return r * math.cos(angle) * coast.hx, r * math.sin(angle) * coast.hz
	end
	local unit, amp = coast.unit, layout.terrain.relief
	local o = {}
	for i = 1, 6 do
		o[i] = rng:nextNumber() * 4096
	end
	local samples = authored(layout)
	local function inland(x: number, z: number): number
		return coast.depth(x, z) * unit
	end
	-- Authored samples binned on a 64-stud grid; lookups beyond 240 studs only need "far".
	local BIN = 64
	local none: { any } = {}
	local bins: { [number]: { any } } = {}
	for _, p in samples do
		local bin = math.floor(p.x / BIN) * 65536 + math.floor(p.z / BIN)
		bins[bin] = bins[bin] or {}
		table.insert(bins[bin], p)
	end
	local function nearestAuthored(x: number, z: number): number
		local best = math.huge
		local bx, bz = math.floor(x / BIN), math.floor(z / BIN)
		for dx = -4, 4 do
			for dz = -4, 4 do
				for _, p in bins[(bx + dx) * 65536 + bz + dz] or none do
					best = math.min(best, (x - p.x) ^ 2 + (z - p.z) ^ 2)
				end
			end
		end
		return math.sqrt(best)
	end
	-- Seeded inland spot at least `clear` studs from authored ground and `shore` studs inside the coast.
	local function spot(clear: number, shore: number, avoid: { any }): any
		for _ = 1, 64 do
			local angle, r = rng:nextNumber() * math.pi * 2, math.sqrt(rng:nextNumber()) * 0.75
			local x, z = math.cos(angle) * r * coast.hx, math.sin(angle) * r * coast.hz
			local ok = inland(x, z) > shore and nearestAuthored(x, z) > clear
			for _, other in avoid do
				ok = ok and (x - other.x) ^ 2 + (z - other.z) ^ 2 > (other.r + clear) ^ 2
			end
			if ok then
				return { x = x, z = z }
			end
		end
		return nil
	end
	local basins: { any } = {}
	for _ = 1, 3 do
		local at = spot(420, 420, basins)
		if at then
			table.insert(basins, { x = at.x, z = at.z, r = 240, depth = amp * 0.55 })
		end
	end
	-- Multi-octave hills, ridged crests, terraced cliffs on strong ridges, seeded basins.
	local mesas: { any } = {}
	for _ = 1, 2 do
		local avoid = table.clone(basins)
		for _, mesa in mesas do
			table.insert(avoid, mesa)
		end
		local at = spot(260, 360, avoid)
		if at then
			table.insert(mesas, { x = at.x, z = at.z, r = 150, height = M.CLIFF_STEP * 2 })
		end
	end
	local function natural(x: number, z: number): number
		local n, a, f, total = 0, 1, 1 / 700, 0
		for k = 1, 5 do
			n += math.noise(x * f + o[1] + k * 17.3, z * f + o[2], k * 0.37) * a
			total += a
			a *= 0.5
			f *= 2
		end
		local ridge = 1 - math.abs(math.noise(x / 460 + o[3], z / 460 + o[4], 0.5)) * 2
		ridge = math.clamp(ridge, 0, 1) ^ 3
		local h = amp * (0.55 * math.clamp(n / total + 0.5, 0, 1) + 0.6 * ridge)
		local cliff = smooth(0.3, 0.45, ridge) * smooth(80, 200, nearestAuthored(x, z))
		if cliff > 0 then
			local t = h / M.CLIFF_STEP
			local stepped = (math.floor(t) + smooth(0.75, 0.95, t - math.floor(t))) * M.CLIFF_STEP
			h += (stepped - h) * cliff
		end
		for _, basin in basins do
			local d = math.sqrt((x - basin.x) ^ 2 + (z - basin.z) ^ 2)
			h -= basin.depth * (1 - smooth(basin.r * 0.3, basin.r, d))
		end
		-- Seeded mesas: flat-topped rises whose rims are near-vertical cliffs.
		for _, mesa in mesas do
			local d = math.sqrt((x - mesa.x) ^ 2 + (z - mesa.z) ^ 2)
			h += mesa.height * (1 - smooth(mesa.r - 10, mesa.r, d))
		end
		return math.max(h, 0)
	end
	-- Authored gameplay ground: inverse-distance blend of authored heights, exact in round clearings,
	-- blended into the relief over 48..240 studs so every node, anchor and spawn keeps its height.
	local function settled(x: number, z: number): number
		local h = natural(x, z)
		if nearestAuthored(x, z) < 240 then
			local sum, weight, nearest = 0, 0, math.huge
			for _, p in samples do
				local d2 = (x - p.x) ^ 2 + (z - p.z) ^ 2
				nearest = math.min(nearest, d2)
				local w = 1 / (d2 + 256) ^ 1.5
				sum += p.y * w
				weight += w
			end
			h += (sum / weight - h) * (1 - smooth(48, 240, math.sqrt(nearest)))
			local exactSum, exactWeight, pointSum, pointWeight, pointDepth, exactDepth = 0, 0, 0, 0, 0, 0
			local function blend(distance: number, inner: number, target: number, point: boolean?)
				h += (target - h) * (1 - smooth(inner, inner + 48, distance))
				-- Overlapping clearings blend by depth inside each, so their meeting line has no step;
				-- a node, anchor or spawn clearing outranks a path passing through it.
				if distance <= inner then
					local w = (1 - distance / inner) ^ 2 + 1e-3
					if point then
						pointSum += target * w
						pointWeight += w
						pointDepth = math.max(pointDepth, 1 - distance / inner)
					else
						exactSum += target * w
						exactWeight += w
						exactDepth = math.max(exactDepth, 1 - distance / inner)
					end
				end
			end
			-- Crossing catalog paths at different heights: the ground follows the highest one, with a
			-- walkable 0.3 ramp down from its edge, so no path ribbon stands above the ground.
			local ridge, near = -math.huge, math.huge
			for _, path in layout.paths do
				for i = 2, #path.points do
					local a, b = path.points[i - 1], path.points[i]
					local distance, t = M.distance(x, z, a, b)
					local over = math.max(0, distance - path.width / 2 - 4)
					if over < 48 then
						ridge = math.max(ridge, a.y + (b.y - a.y) * t - over * 0.3)
						near = math.min(near, distance - path.width / 2)
					end
				end
			end
			if ridge > -math.huge then
				h += (ridge - h) * (1 - smooth(40, 88, near))
			end
			for _, list in { layout.spawns, layout.anchors, layout.resourceNodes } do
				for _, item in list do
					local p = item.position
					local inner = if item.id == "objective" then 64 else (item.radius or 0) + 24
					blend(math.sqrt((x - p.x) ^ 2 + (z - p.z) ^ 2), inner, p.y, true)
				end
			end
			if exactWeight > 0 then
				h += (exactSum / exactWeight - h) * smooth(0, 0.45, exactDepth)
			end
			-- Point clearings take over from paths over their outer third, as a walkable ramp.
			if pointWeight > 0 then
				h += (pointSum / pointWeight - h) * smooth(0, 0.7, pointDepth)
			end
			-- Slope cap: within reach of any authored point or path the ground stays inside a
			-- GRADE_CAP cone around it, so no blend leaves a step a character must jump. Points first,
			-- then paths as an upper cap, so a path never runs below a raised bank.
			for _, list in { layout.spawns, layout.anchors, layout.resourceNodes } do
				for _, item in list do
					local p = item.position
					local lim = M.GRADE_CAP * math.max(0, math.sqrt((x - p.x) ^ 2 + (z - p.z) ^ 2) - 6)
					if lim < 40 then
						h = math.clamp(h, p.y - lim, p.y + lim)
					end
				end
			end
			-- Paths: the ground stays between the highest ramp floor (a path's height falling off at
			-- GRADE_CAP from its edge) and the lowest cap (rising off at GRADE_CAP). On a ribbon both meet
			-- the path height; where ribbons at different heights meet, the higher wins and ramps down.
			local floor, cap = -math.huge, math.huge
			for _, path in layout.paths do
				for i = 2, #path.points do
					local a, b = path.points[i - 1], path.points[i]
					local distance, t = M.distance(x, z, a, b)
					local lim = M.GRADE_CAP * math.max(0, distance - path.width / 2 - 2)
					if lim < 40 then
						local y = a.y + (b.y - a.y) * t
						floor, cap = math.max(floor, y - lim), math.min(cap, y + lim)
					end
				end
			end
			if floor > -math.huge then
				h = if floor >= cap then floor else math.clamp(h, floor, cap)
			end
			-- Authored points keep their catalog height last: within 6 studs exact, then a 0.6 cone (the
			-- steepest catalog station-to-ribbon grade). The clamp is continuous, so it adds no step.
			for _, list in { layout.spawns, layout.anchors, layout.resourceNodes } do
				for _, item in list do
					local p = item.position
					local lim = 0.6 * math.max(0, math.sqrt((x - p.x) ^ 2 + (z - p.z) ^ 2) - 6)
					if lim < 120 then
						h = math.clamp(h, p.y - lim, p.y + lim)
					end
				end
			end
		end
		-- The ground ramps down to the beach over the last 260 studs inside the coast.
		return M.BEACH_TOP + math.max(0, h - M.BEACH_TOP) * smooth(40, 300, inland(x, z))
	end
	-- Coast-to-coast dirt trail: a seeded meander across the island, height-smoothed and graded to
	-- TRAIL_SLOPE so it is walkable end to end.
	local a0 = rng:nextNumber() * math.pi * 2
	local a1 = a0 + math.pi + (rng:nextNumber() - 0.5) * 0.6
	local sx, sz = coast.point(a0, 0.03)
	local ex, ez = coast.point(a1, 0.03)
	local phase, waves = rng:nextNumber() * math.pi * 2, 3 + rng:nextInteger(0, 1)
	local route = {}
	for i = 0, 24 do
		local t = i / 24
		local dx, dz = ex - sx, ez - sz
		local length = math.sqrt(dx * dx + dz * dz)
		local side = math.sin(t * math.pi * waves + phase) * math.sin(t * math.pi) * unit * 0.3
		local x, z = sx + dx * t - dz / length * side, sz + dz * t + dx / length * side
		for _ = 1, 8 do
			if i == 0 or i == 24 or coast.depth(x, z) > 0.05 then
				break
			end
			x, z = x * 0.9, z * 0.9
		end
		table.insert(route, { x = x, y = 0, z = z })
	end
	local trail = densify(route, 16, settled)
	-- The trail height is smoothed, then graded to TRAIL_SLOPE in both directions.
	for _ = 1, 3 do
		local copy = table.clone(trail)
		for i = 2, #trail - 1 do
			trail[i] = { x = copy[i].x, z = copy[i].z, y = (copy[i - 1].y + copy[i].y * 2 + copy[i + 1].y) / 4 }
		end
	end
	for _, order in { { 2, #trail, 1 }, { #trail - 1, 1, -1 } } do
		for i = order[1], order[2], order[3] do
			local prev = trail[i - order[3]]
			local run = math.sqrt((trail[i].x - prev.x) ^ 2 + (trail[i].z - prev.z) ^ 2)
			trail[i].y = math.clamp(trail[i].y, prev.y - run * M.TRAIL_SLOPE, prev.y + run * M.TRAIL_SLOPE)
		end
	end
	local function trailed(x: number, z: number): (number, number)
		local h = settled(x, z)
		local d, y = along(x, z, trail)
		-- Inside authored clearings the clearing height wins (trail samples there are pinned to it).
		local w = (1 - smooth(M.TRAIL_WIDTH / 2, M.TRAIL_WIDTH / 2 + 24, d)) * smooth(16, 72, nearestAuthored(x, z))
		return h + (y - h) * w, d
	end
	-- One stream from a high inland spring to the sea, its bed never rising downstream; ponds in basins.
	local streams: { any } = {}
	local source = spot(360, 520, basins)
	if source then
		local angle = math.atan2(source.z / coast.hz, source.x / coast.hx)
		local mx, mz = coast.point(angle, -0.04)
		local bend = (rng:nextNumber() - 0.5) * unit * 0.25
		local path = {}
		for i = 0, 10 do
			local t = i / 10
			local dx, dz = mx - source.x, mz - source.z
			local length = math.sqrt(dx * dx + dz * dz)
			local side = math.sin(t * math.pi * 2) * bend
			table.insert(path, {
				x = source.x + dx * t - dz / length * side,
				y = 0,
				z = source.z + dz * t + dx / length * side,
			})
		end
		local bed = densify(path, 16, function(x, z)
			return (trailed(x, z)) - 3
		end)
		for i = 2, #bed do
			bed[i].y = math.min(bed[i].y, bed[i - 1].y)
		end
		bed[#bed].y = math.min(bed[#bed].y, M.SEA - 2)
		table.insert(streams, { points = bed, width = M.STREAM_WIDTH })
	end
	local ponds: { any } = {}
	for _, basin in basins do
		if segments(basin.x, basin.z, trail) > 120 and inland(basin.x, basin.z) > 200 then
			table.insert(ponds, { x = basin.x, z = basin.z, r = 56, level = (trailed(basin.x, basin.z)) + 1.5 })
		end
	end
	local field: any = { coast = coast, trails = { trail }, streams = streams, ponds = ponds, relief = amp }
	function field.height(x: number, z: number): number
		local depth = coast.depth(x, z)
		if depth <= 0 then
			-- Offshore: a sand shelf sloping from the beach down to the seabed, no wall at the coast.
			return math.max(M.SEA - 8, M.BEACH_TOP + depth * unit * 0.3)
		end
		local h, dTrail = trailed(x, z)
		if M.protected(layout, x, z, 16) then
			return h
		end
		for _, stream in streams do
			local d, y = along(x, z, stream.points)
			if d < stream.width then
				-- A ford where the trail crosses: the channel there is at most 1.5 studs deep.
				local floor = if dTrail < M.TRAIL_WIDTH then h - 1.5 else -math.huge
				h = math.min(h, math.max(floor, y + (d / stream.width) ^ 2 * 6))
			end
		end
		for _, pond in ponds do
			local d2 = (x - pond.x) ^ 2 + (z - pond.z) ^ 2
			if d2 < pond.r ^ 2 then
				h = math.min(h, pond.level - 3 * (1 - d2 / pond.r ^ 2))
			end
		end
		return h
	end
	--- Water surface over (x, z) for a pond or stream channel, else nil (sea excluded).
	function field.water(x: number, z: number): number?
		for _, pond in ponds do
			if (x - pond.x) ^ 2 + (z - pond.z) ^ 2 < pond.r ^ 2 then
				return pond.level
			end
		end
		for _, stream in streams do
			local d, y = along(x, z, stream.points)
			if d < stream.width * 0.6 and not M.protected(layout, x, z, 16) then
				return y + 1.5
			end
		end
		return nil
	end
	function field.trail(x: number, z: number): number
		return (segments(x, z, trail))
	end
	--- Distance to the nearest authored gameplay point (path sample, node, anchor or spawn).
	field.clear = nearestAuthored
	fields[key] = field
	return field
end

--- Ground height an adapter can use where a terrain ray finds nothing (not yet written or not
--- streamed in). Relief layouts only; nil for legacy layouts.
function M.surface(layout: any, seed: number, x: number, z: number): number?
	return if M.relief(layout) then M.field(layout, seed).height(x, z) else nil
end

local reliefCache: { [string]: { any } } = setmetatable({}, { __mode = "v" }) :: any

--- Square land columns of a relief layout: only cells wholly inside the coast; cliffs read as Rock,
--- trails as Ground, pond and stream beds as Mud, the beach band as Sand. Memoized per
--- (layout, seed, island seed, cell); callers treat the list as read-only.
local function reliefColumns(layout: any, seed: number, cell: number): { any }
	local cacheKey = layout.id .. ":" .. seed .. ":" .. layout.terrain.seed .. ":" .. cell
	if reliefCache[cacheKey] then
		return reliefCache[cacheKey]
	end
	local field = M.field(layout, seed)
	local coast = field.coast
	local result = {}
	local tops: { [string]: number } = {}
	local h = cell / 2
	for x = -coast.hx + h, coast.hx - h, cell do
		for z = -coast.hz + h, coast.hz - h, cell do
			local corner = math.min(
				coast.depth(x - h, z - h),
				coast.depth(x + h, z - h),
				coast.depth(x - h, z + h),
				coast.depth(x + h, z + h)
			)
			if corner <= 0 then
				continue
			end
			local top = field.height(x, z)
			tops[x .. "," .. z] = top
			local beach = coast.depth(x, z) < M.GRASS_EDGE
			local wet = field.water(x, z) ~= nil
			table.insert(result, {
				x = x,
				z = z,
				top = top,
				cell = cell,
				biome = layout.biomes[1],
				beach = beach,
				wet = wet or nil,
				material = if beach
					then "Sand"
					elseif wet then "Mud"
					elseif field.trail(x, z) < M.TRAIL_WIDTH / 2 + 4 then "Ground"
					else M.ground(layout, x),
			})
		end
	end
	for _, column in result do
		if column.beach or column.wet or column.material == "Ground" then
			continue
		end
		for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local other = tops[column.x + d[1] * cell .. "," .. column.z + d[2] * cell]
			if other and column.top - other >= 8 and not M.protected(layout, column.x, column.z, 16) then
				column.material = "Rock"
			end
		end
	end
	reliefCache[cacheKey] = result
	return result
end

-- Catalog navigation and habitat clearings override the seeded high ground.
-- Returns square terrain columns; adapters materialize columns before ribbons.
function M.columns(layout: any, seed: number, cell: number): { any }
	assert(cell > 0 and cell % 4 == 0, "TERRAIN_CELL_MULTIPLE_OF_FOUR")
	if M.relief(layout) then
		return reliefColumns(layout, seed, cell)
	end
	local rng = Rng.new(seed):fork(layout.id)
	local phase = rng:nextNumber() * math.pi * 2
	local stage = tonumber(string.match(layout.id, "%.s(%d+)$")) or 1
	local coast = if M.organic(layout) then M.coast(layout, seed) else nil
	local samples: { any } = if coast then authored(layout) else {}
	local result = {}
	-- An organic coast may bulge past the authored bounds; offshore cells are left to the sea.
	local grow = if coast then cell * 2 else 0
	for x = layout.bounds.min.x + cell / 2 - grow, layout.bounds.max.x - cell / 2 + grow, cell do
		for z = layout.bounds.min.z + cell / 2 - grow, layout.bounds.max.z - cell / 2 + grow, cell do
			local nx = x / math.max(math.abs(layout.bounds.min.x), math.abs(layout.bounds.max.x))
			local nz = z / math.max(math.abs(layout.bounds.min.z), math.abs(layout.bounds.max.z))
			local angle = math.atan2(nz, nx)
			local edge = math.sqrt(nx * nx + nz * nz) + 0.11 * math.sin(angle * (stage + 1) + phase)
			local shore = edge > 0.82 and not M.protected(layout, x, z, cell)
			local top = layout.bounds.min.y
				+ 2
				+ (layout.bounds.max.y - layout.bounds.min.y)
					* 0.22
					* (1 + math.sin(x / 80 + phase) * math.cos(z / 96))
			local beach = nil
			if coast then
				-- Only cells wholly inside the coast are land; adapters draw the rim as round beach.
				local h = cell / 2
				local corner = math.min(
					coast.depth(x - h, z - h),
					coast.depth(x + h, z - h),
					coast.depth(x - h, z + h),
					coast.depth(x + h, z + h)
				)
				if corner <= 0 then
					continue
				end
				-- Smooth height field: inverse-distance blend of the authored heights with a
				-- gentle seeded swell far from them, so neighbouring columns never form terraces.
				local sum, weight, nearest = 0, 0, math.huge
				for _, p in samples do
					local d2 = (x - p.x) ^ 2 + (z - p.z) ^ 2
					nearest = math.min(nearest, d2)
					local w = 1 / (d2 + 256) ^ 1.5
					sum += p.y * w
					weight += w
				end
				local swell = (top - layout.bounds.min.y - 2) * 0.3 * smooth(cell, cell * 4, math.sqrt(nearest))
				top = sum / weight + swell
				local depth = coast.depth(x, z)
				local hold = M.band(coast, cell) + cell * 0.71 / coast.unit
				top = M.BEACH_TOP + (top - M.BEACH_TOP) * smooth(hold, hold + 0.16, depth)
				beach = depth < M.GRASS_EDGE
			elseif shore then
				top = if edge > 0.98 then -12 else -2
			end
			if coast then
				-- Authored ground is exact within round clearings and blends out over two cells,
				-- never as rectangular plateaus. Exact clearings are re-applied last, in catalog order.
				local exact: number? = nil
				local function blend(distance: number, inner: number, target: number)
					local w = 1 - smooth(inner, inner + cell * 2, distance)
					top += (target - top) * w
					if distance <= inner then
						exact = target
					end
				end
				for _, path in layout.paths do
					for i = 2, #path.points do
						local a, b = path.points[i - 1], path.points[i]
						local distance, t = M.distance(x, z, a, b)
						blend(distance, path.width / 2 + cell * 0.75, a.y + (b.y - a.y) * t)
					end
				end
				for _, spawn in layout.spawns do
					local p = spawn.position
					blend(math.sqrt((x - p.x) ^ 2 + (z - p.z) ^ 2), spawn.radius + cell * 0.75, p.y)
				end
				for _, anchor in layout.anchors do
					local p = anchor.position
					local inner = if anchor.id == "objective" then 64 else cell * 0.75
					blend(math.sqrt((x - p.x) ^ 2 + (z - p.z) ^ 2), inner, p.y)
				end
				for _, node in layout.resourceNodes do
					local p = node.position
					blend(math.sqrt((x - p.x) ^ 2 + (z - p.z) ^ 2), cell * 0.75, p.y)
				end
				top = exact or top
				-- Authored clearings can reach the beach band; near the coast the ground ramps down
				-- to BEACH_TOP over at least two cells instead of ending in a wall at the last column.
				-- M.coast widens the island around high authored ground to make room for the ramp;
				-- the column holding an authored point always keeps its exact height.
				local cap = M.BEACH_TOP + math.max(0, coast.depth(x, z) * coast.unit - cell / 2) * M.COAST_SLOPE
				if top > cap and not M.pinned(layout, x, z, cell) then
					top = cap
				end
			end
			for _, path in if coast then {} else layout.paths do
				for i = 2, #path.points do
					local a, b = path.points[i - 1], path.points[i]
					local distance, t = M.distance(x, z, a, b)
					if distance <= path.width / 2 + cell * 2 then
						top = a.y + (b.y - a.y) * t
					end
				end
			end
			for _, spawn in if coast then {} else layout.spawns do
				if (x - spawn.position.x) ^ 2 + (z - spawn.position.z) ^ 2 <= (spawn.radius + cell) ^ 2 then
					top = spawn.position.y
				end
			end
			for _, anchor in if coast then {} else layout.anchors do
				local clearance = if anchor.id == "objective" then 64 else cell
				if math.abs(x - anchor.position.x) <= clearance and math.abs(z - anchor.position.z) <= clearance then
					top = anchor.position.y
				end
			end
			for _, node in if coast then {} else layout.resourceNodes do
				if math.abs(x - node.position.x) <= cell and math.abs(z - node.position.z) <= cell then
					top = node.position.y
				end
			end
			table.insert(result, {
				x = x,
				z = z,
				top = top,
				cell = cell,
				biome = layout.biomes[1],
				beach = beach,
				material = if top < 0 or beach then "Sand" else M.ground(layout, x),
			})
		end
	end
	if M.graded(layout) then
		grade(layout, coast, result, cell)
	end
	return result
end
return M
