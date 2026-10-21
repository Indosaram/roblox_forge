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
-- Catalog navigation and habitat clearings override the seeded high ground.
-- Returns square terrain columns; adapters materialize columns before ribbons.
function M.columns(layout: any, seed: number, cell: number): { any }
	assert(cell > 0 and cell % 4 == 0, "TERRAIN_CELL_MULTIPLE_OF_FOUR")
	local rng = Rng.new(seed):fork(layout.id)
	local phase = rng:nextNumber() * math.pi * 2
	local stage = tonumber(string.match(layout.id, "%.s(%d+)$")) or 1
	local result = {}
	for x = layout.bounds.min.x + cell / 2, layout.bounds.max.x - cell / 2, cell do
		for z = layout.bounds.min.z + cell / 2, layout.bounds.max.z - cell / 2, cell do
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
			if shore then
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
				material = if top < 0
					then "Sand"
					elseif table.find(layout.biomes, "volcano") and x < 0 then "Basalt"
					else materials[layout.biomes[1]] or "Grass",
			})
		end
	end
	return result
end
return M
