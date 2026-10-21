--!strict
local Rng = require("../random/Rng")
local M = {}
-- Catalog navigation and habitat clearings override the seeded high ground.
-- Returns square terrain columns; adapters materialize columns before ribbons.
function M.columns(layout: any, seed: number, cell: number): { any }
	local rng = Rng.new(seed):fork(layout.id)
	local result = {}
	for x = layout.bounds.min.x + cell / 2, layout.bounds.max.x - cell / 2, cell do
		for z = layout.bounds.min.z + cell / 2, layout.bounds.max.z - cell / 2, cell do
			local top = rng:nextInteger(layout.bounds.min.y, layout.bounds.max.y)
			for _, path in layout.paths do
				for i = 2, #path.points do
					local a, b = path.points[i - 1], path.points[i]
					local dx, dz = b.x - a.x, b.z - a.z
					local length = dx * dx + dz * dz
					local t = if length == 0 then 0 else math.clamp(((x - a.x) * dx + (z - a.z) * dz) / length, 0, 1)
					local distance = math.sqrt((x - a.x - dx * t) ^ 2 + (z - a.z - dz * t) ^ 2)
					if distance <= path.width / 2 + cell then
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
				if math.abs(x - anchor.position.x) <= cell and math.abs(z - anchor.position.z) <= cell then
					top = anchor.position.y
				end
			end
			for _, node in layout.resourceNodes do
				if math.abs(x - node.position.x) <= cell and math.abs(z - node.position.z) <= cell then
					top = node.position.y
				end
			end
			table.insert(result, { x = x, z = z, top = top, cell = cell, biome = layout.biomes[1] })
		end
	end
	return result
end
return M
