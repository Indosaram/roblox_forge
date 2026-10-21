--!strict
-- Role builder with injected engine ports. Catalog positions are already
-- transformed by content codegen: never apply rotation/mirror a second time.
local Terrain = require("../../../../core/domain/island/ArchipelagoTerrain")
local M = {}

function M.describe(content: any, layoutId: string, seed: number): any
	local layout = nil
	for _, candidate in content.layouts do
		if candidate.id == layoutId then
			layout = candidate
		end
	end
	assert(layout, "unknown_archipelago_layout")
	local result: any = {
		layout = layout,
		seed = seed,
		objectives = {},
		docks = {},
		terrain = {},
		columns = Terrain.columns(layout, seed, 32),
	}
	for _, anchor in layout.anchors do
		if anchor.id == "entry" or anchor.id == "exit" then
			table.insert(
				result.docks,
				{ position = anchor.position, returnHome = true, nextIsland = anchor.id == "exit" }
			)
		end
	end
	for _, stage in content.stages do
		if stage.layout == layoutId then
			for _, objective in stage.objectives do
				table.insert(result.objectives, objective)
			end
		end
	end
	-- Each navigation segment is a dry linear ramp, not a single flat island.
	-- The engine port constructs a wedge/terrain ribbon with this exact slope.
	for _, path in layout.paths do
		for i = 2, #path.points do
			table.insert(result.terrain, {
				id = path.id .. "." .. i,
				from = path.points[i - 1],
				to = path.points[i],
				width = path.width,
				biome = layout.biomes[1],
			})
		end
	end
	return result
end

function M.build(env: any): any
	local description = M.describe(env.content, env.layoutId, env.seed)
	local root = env.begin(description.layout.id, description.seed, description.layout.bounds)
	for _, column in description.columns do
		env.column(root, column)
	end
	for _, ribbon in description.terrain do
		env.terrain(root, ribbon)
	end
	for _, node in description.layout.resourceNodes do
		env.resource(root, node)
	end
	for _, spawn in description.layout.spawns do
		env.wildlife(root, spawn)
	end
	for _, hazard in description.layout.hazards do
		env.hazard(root, hazard)
	end
	for _, refuge in description.layout.refuges do
		env.refuge(root, refuge)
	end
	for _, objective in description.objectives do
		env.objective(root, objective, description.layout)
	end
	for _, dock in description.docks do
		env.dock(root, dock)
	end
	return root
end
return M
