--!strict
-- Deterministic procedural-prop placement for every role world. Pure Luau: the client
-- re-derives the same plan from the layout id and world seed that the server published
-- on ForgeRoleWorld, then builds the generated ProcAssets meshes as non-colliding decor.
-- Keys come from assets/procgen.yml (src/shared/ProcAssets.luau is generated from it).
local Rng = require("../../../../core/domain/random/Rng")
local Terrain = require("../../../../core/domain/island/ArchipelagoTerrain")
local RenderBudget = require("./RenderBudget")

local M = {}

export type Placement = {
	key: string,
	name: string,
	biome: string,
	position: { x: number, y: number, z: number },
	yaw: number,
	scale: number,
}

-- Per-role cap on the high profile; each Part-fallback prop is at most ~23 parts.
M.MAX_PER_ROLE = 24
-- Clearance (studs) beyond Terrain.protected's path/spawn/anchor clearings.
M.MARGIN = 8
M.NODE_CLEARANCE = 16
M.SPACING = 16
-- The home camp is a compact plot; Terrain.protected's 40-stud objective clearing covers
-- all of it, so the home uses tight footprint clearances and a ring past the tree radius.
M.HOME_CLEARANCE = 6
M.HOME_RING = { 25, 30 }
M.HOME_SPACING = 7

-- Biome art sets: 2-4 distinct generated props each.
M.SETS = {
	grassland = { "robango-meadow-oak", "robango-meadow-boulder", "robango-meadow-orchard", "robango-forest-tree" },
	forest = { "robango-forest-pine", "robango-forest-mossrock", "robango-flint-crystal" },
	tropical = { "robango-jungle-tree", "robango-jungle-bloom", "robango-jungle-mossrock" },
	swamp = { "robango-marsh-cypress", "robango-marsh-stone", "robango-marsh-glowshard" },
	desert = { "robango-desert-sandstone", "robango-desert-mesa", "robango-desert-amber", "robango-desert-acacia" },
	snow = { "robango-snow-pine", "robango-snow-boulder", "robango-ice-crystal" },
	volcano = { "robango-basalt-rock", "robango-ember-crystal", "robango-ash-tree" },
	coast = { "robango-coast-palm", "robango-coast-driftrock", "robango-coast-shellstone" },
	camp = { "robango-harbor-cargo", "robango-camp-crate", "robango-camp-egg-cache", "robango-supply-crate" },
} :: { [string]: { string } }

local function isHome(layout: any): boolean
	return layout.id == "rw.home"
end

--- The art sets a layout may draw from.
function M.allowed(layout: any): { string }
	if isHome(layout) then
		return { "camp", "grassland" }
	elseif layout.id == "rw.harbor" then
		return { "coast", "camp" }
	end
	local list = {}
	for _, biome in layout.biomes do
		local set = if biome == "beach" then "coast" else biome
		if M.SETS[set] and not table.find(list, set) then
			table.insert(list, set)
		end
	end
	if not table.find(list, "coast") then
		table.insert(list, "coast")
	end
	return list
end

--- True when a prop footprint at (x, z) keeps clear of objectives, paths, spawns and nodes.
function M.clear(layout: any, x: number, z: number): boolean
	if isHome(layout) then
		local r = M.HOME_CLEARANCE
		for _, list in { layout.anchors, layout.resourceNodes } do
			for _, item in list do
				if (x - item.position.x) ^ 2 + (z - item.position.z) ^ 2 < r * r then
					return false
				end
			end
		end
		for _, path in layout.paths do
			for i = 2, #path.points do
				if Terrain.distance(x, z, path.points[i - 1], path.points[i]) < path.width / 2 + r / 2 then
					return false
				end
			end
		end
		return true
	end
	if Terrain.protected(layout, x, z, M.MARGIN) then
		return false
	end
	for _, node in layout.resourceNodes do
		if (x - node.position.x) ^ 2 + (z - node.position.z) ^ 2 < M.NODE_CLEARANCE ^ 2 then
			return false
		end
	end
	return true
end

local function setFor(layout: any, column: any): string
	if layout.id == "rw.harbor" then
		-- Waterfront ring reads as coast; the market streets inland read as camp.
		local nx = column.x / math.max(math.abs(layout.bounds.min.x), math.abs(layout.bounds.max.x))
		local nz = column.z / math.max(math.abs(layout.bounds.min.z), math.abs(layout.bounds.max.z))
		return if column.beach or nx * nx + nz * nz > 0.5 then "coast" else "camp"
	end
	if column.beach then
		return "coast"
	end
	local biome = column.biome or layout.biomes[1]
	if biome == "beach" then
		return "coast"
	end
	return if M.SETS[biome] then biome else "grassland"
end

local function arrival(layout: any): { x: number, z: number }
	for _, anchor in layout.anchors do
		if anchor.id == "entry" then
			return anchor.position
		end
	end
	return { x = 0, z = 0 }
end

--- Plans up to MAX_PER_ROLE props, nearest to the arrival dock first so capped profiles
--- keep the props in the opening view. `columns` is Terrain.columns for the layout ({} for home).
function M.plan(layout: any, columns: { any }, seed: number): { Placement }
	local rng = Rng.new(seed):fork(layout.id .. ":procprops")
	local candidates: { any } = {}
	if isHome(layout) then
		local count = 32
		local phase = rng:nextNumber() * math.pi * 2
		for i = 1, count do
			local angle = phase + (i - 1) / count * math.pi * 2
			local radius = M.HOME_RING[1] + rng:nextNumber() * (M.HOME_RING[2] - M.HOME_RING[1])
			table.insert(candidates, {
				x = math.cos(angle) * radius,
				y = 2,
				z = math.sin(angle) * radius,
				set = if i % 2 == 0 then "grassland" else "camp",
			})
		end
	else
		for _, column in columns do
			if column.top > 0 then
				local jitter = (column.cell or 32) * 0.3
				table.insert(candidates, {
					x = column.x + (rng:nextNumber() * 2 - 1) * jitter,
					y = column.top,
					z = column.z + (rng:nextNumber() * 2 - 1) * jitter,
					set = setFor(layout, column),
				})
			end
		end
		-- Seeded shuffle so scatter is not biased to the column scan order.
		for i = #candidates, 2, -1 do
			local j = rng:nextInteger(1, i)
			candidates[i], candidates[j] = candidates[j], candidates[i]
		end
	end
	local spacing = if isHome(layout) then M.HOME_SPACING else M.SPACING
	local turns: { [string]: number } = {}
	for name in M.SETS do
		turns[name] = rng:fork(name):nextInteger(0, 3)
	end
	local chosen: { Placement } = {}
	for _, candidate in candidates do
		if #chosen >= M.MAX_PER_ROLE then
			break
		end
		if not M.clear(layout, candidate.x, candidate.z) then
			continue
		end
		local spaced = true
		for _, other in chosen do
			if (candidate.x - other.position.x) ^ 2 + (candidate.z - other.position.z) ^ 2 < spacing ^ 2 then
				spaced = false
				break
			end
		end
		if not spaced then
			continue
		end
		local set = M.SETS[candidate.set]
		turns[candidate.set] += 1
		local key = set[turns[candidate.set] % #set + 1]
		table.insert(chosen, {
			key = key,
			name = "",
			biome = candidate.set,
			position = { x = candidate.x, y = candidate.y, z = candidate.z },
			yaw = math.floor(rng:nextNumber() * 360),
			scale = 0.85 + math.floor(rng:nextNumber() * 40) / 100,
		})
	end
	local origin = arrival(layout)
	local function distance(p: Placement): number
		return (p.position.x - origin.x) ^ 2 + (p.position.z - origin.z) ^ 2
	end
	table.sort(chosen, function(a, b)
		local da, db = distance(a), distance(b)
		if da ~= db then
			return da < db
		end
		return a.position.x < b.position.x
	end)
	for index, placement in chosen do
		placement.name = string.format("ProcProp%02d_%s", index, placement.key)
	end
	return chosen
end

--- The placements a render profile builds: RenderBudget.meshes on the low profile
--- (meshBuildsMax), otherwise the per-role cap.
function M.limit(placements: { Placement }, profile: RenderBudget.Profile): { Placement }
	if profile.meshBuildsMax <= RenderBudget.profiles.low.meshBuildsMax then
		return RenderBudget.meshes(placements, profile)
	end
	local kept = {}
	for index = 1, math.min(#placements, M.MAX_PER_ROLE) do
		table.insert(kept, placements[index])
	end
	return kept
end

return M
