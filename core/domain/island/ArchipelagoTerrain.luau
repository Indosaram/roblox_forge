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
	for _, node in layout.resourceNodes do
		keep(node.position, 48)
	end
	for _, anchor in layout.anchors do
		keep(anchor.position, if anchor.id == "objective" then 96 else 56)
	end
	for _, spawn in layout.spawns do
		keep(spawn.position, spawn.radius + 48)
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
	local coast = { hx = hx, hz = hz }
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
	function coast.point(angle: number): (number, number)
		local r = coast.radius(angle)
		return r * math.cos(angle) * hx, r * math.sin(angle) * hz
	end
	return coast
end

-- Catalog navigation and habitat clearings override the seeded high ground.
-- Returns square terrain columns; adapters materialize columns before ribbons.
function M.columns(layout: any, seed: number, cell: number): { any }
	assert(cell > 0 and cell % 4 == 0, "TERRAIN_CELL_MULTIPLE_OF_FOUR")
	local rng = Rng.new(seed):fork(layout.id)
	local phase = rng:nextNumber() * math.pi * 2
	local stage = tonumber(string.match(layout.id, "%.s(%d+)$")) or 1
	local coast = if M.organic(layout) then M.coast(layout, seed) else nil
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
				if
					math.min(
						coast.depth(x - h, z - h),
						coast.depth(x + h, z - h),
						coast.depth(x - h, z + h),
						coast.depth(x + h, z + h)
					) <= 0
				then
					continue
				end
				local depth = coast.depth(x, z)
				top = 2 + (top - 2) * smooth(0.04, 0.2, depth)
				beach = depth < 0.09
			elseif shore then
				top = if edge > 0.98 then -12 else -2
			end
			for _, path in layout.paths do
				for i = 2, #path.points do
					local a, b = path.points[i - 1], path.points[i]
					local distance, t = M.distance(x, z, a, b)
					if distance <= path.width / 2 + cell * 2 then
						top = a.y + (b.y - a.y) * t
					end
				end
			end
			for _, spawn in layout.spawns do
				if (x - spawn.position.x) ^ 2 + (z - spawn.position.z) ^ 2 <= (spawn.radius + cell) ^ 2 then
					top = spawn.position.y
				end
			end
			for _, anchor in layout.anchors do
				local clearance = if anchor.id == "objective" then 64 else cell
				if math.abs(x - anchor.position.x) <= clearance and math.abs(z - anchor.position.z) <= clearance then
					top = anchor.position.y
				end
			end
			for _, node in layout.resourceNodes do
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
				material = if top < 0 or beach
					then "Sand"
					elseif table.find(layout.biomes, "volcano") and x < 0 then "Basalt"
					else materials[layout.biomes[1]] or "Grass",
			})
		end
	end
	return result
end
return M
