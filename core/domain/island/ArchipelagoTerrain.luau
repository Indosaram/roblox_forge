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

-- Catalog navigation and habitat clearings override the seeded high ground.
-- Returns square terrain columns; adapters materialize columns before ribbons.
function M.columns(layout: any, seed: number, cell: number): { any }
	assert(cell > 0 and cell % 4 == 0, "TERRAIN_CELL_MULTIPLE_OF_FOUR")
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
