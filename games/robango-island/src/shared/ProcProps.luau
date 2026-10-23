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
-- all of it, so the home scatters a few props over the free ground between the camp and
-- the shore. HOME_MAX is the designed home count. HOME_CLEARANCE keeps every prop that far
-- from each prompt/interactable (anchors, resource nodes, the travel dock, the starter
-- farm plot) and from each camp kit in HOME_CAMP.
M.HOME_MAX = 8
M.HOME_CLEARANCE = 14
M.HOME_SPACING = 6
-- Flat radius band the home scan covers, and the grid step of its candidates.
M.HOME_RING = { 12, 36 }
M.HOME_STEP = 1
-- Studs a home prop keeps inside the shore and beside a path edge.
M.HOME_SHORE = 2
M.HOME_PATH = 2
-- Camp kit centres WorldDressing.home places on the rank-1 plot (shelter, fire, workbench,
-- drying rack, storage, farm). procprops.spec.luau re-derives them from WorldDressing.
M.HOME_CAMP = {
	{ x = -20, z = -20 },
	{ x = -8, z = 4 },
	{ x = -14, z = 10 },
	{ x = -20, z = 4 },
	{ x = -14.35, z = -13 },
	{ x = 20, z = -18 },
} :: { { x: number, z: number } }
-- WorldDressing.home's shore palms: props keep HOME_PALM studs from their roots.
M.HOME_PALM = 6
M.HOME_PALM_RADIUS = 32
-- Rank-1 home land: RoleWorld renders the coast at 1.12 + 0.08 sin(a(2+p) + (p-1)0.7)
-- + 0.045 cos(7a) times the half side for terrain presets 1-3; the plan keeps to the
-- narrowest of them so a prop stands on land under every preset.
M.HOME_HALF = 32
M.HOME_PRESETS = 3

-- Per-role prop scale: props grow with the layout's terrain relief (the highest land
-- column above the beach) so they read beside its mounds at gameplay camera distance.
-- The home keeps authored camp scale. Camp-set crates and caches stay smaller than trees.
M.SCALE_BASE = 1.3
M.SCALE_PER_STUD = 0.12
M.SCALE_MAX = 3
M.HOME_SCALE = 1
M.SET_SCALE = { camp = 0.8 } :: { [string]: number }

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

--- The home interactables a prop keeps HOME_CLEARANCE from: every anchor and resource
--- node, the travel dock and starter farm plot (when `policy` is the homePolicy), and the
--- camp kits.
function M.homeInteractables(layout: any, policy: any?): { { x: number, z: number } }
	local list = {}
	for _, items in { layout.anchors, layout.resourceNodes } do
		for _, item in items do
			table.insert(list, { x = item.position.x, z = item.position.z })
		end
	end
	if policy then
		for _, item in { policy.dock, policy.starterFarmPlot } do
			if item then
				table.insert(list, { x = item.x, z = item.z })
			end
		end
	end
	for _, kit in M.HOME_CAMP do
		table.insert(list, kit)
	end
	return list
end

--- Narrowest rank-1 home shore radius at angle `a` across the terrain presets.
function M.homeShore(a: number): number
	local edge = math.huge
	for preset = 1, M.HOME_PRESETS do
		edge = math.min(edge, 1.12 + 0.08 * math.sin(a * (2 + preset) + (preset - 1) * 0.7) + 0.045 * math.cos(a * 7))
	end
	return edge * M.HOME_HALF
end

--- True when a prop footprint at (x, z) keeps clear of objectives, paths, spawns and nodes.
--- On the home `policy` (content.homePolicy) adds the dock and starter farm plot.
function M.clear(layout: any, x: number, z: number, policy: any?): boolean
	if isHome(layout) then
		if math.sqrt(x * x + z * z) > M.homeShore(math.atan2(z, x)) - M.HOME_SHORE then
			return false
		end
		local r = M.HOME_CLEARANCE
		for _, item in M.homeInteractables(layout, policy) do
			if (x - item.x) ^ 2 + (z - item.z) ^ 2 < r * r then
				return false
			end
		end
		for i = 1, 4 do
			local a = math.rad(i * 20 - 40)
			local px, pz = math.cos(a) * M.HOME_PALM_RADIUS, math.sin(a) * M.HOME_PALM_RADIUS
			if (x - px) ^ 2 + (z - pz) ^ 2 < M.HOME_PALM ^ 2 then
				return false
			end
		end
		for _, path in layout.paths do
			for i = 2, #path.points do
				if Terrain.distance(x, z, path.points[i - 1], path.points[i]) < path.width / 2 + M.HOME_PATH then
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

--- The role's prop scale from its terrain relief (`columns` as for plan).
function M.roleScale(layout: any, columns: { any }): number
	if isHome(layout) then
		return M.HOME_SCALE
	end
	local top = 0
	for _, column in columns do
		if column.top > 0 then
			top = math.max(top, column.top)
		end
	end
	local relief = math.max(0, top - Terrain.BEACH_TOP)
	return math.min(M.SCALE_MAX, M.SCALE_BASE + relief * M.SCALE_PER_STUD)
end

--- Plans up to MAX_PER_ROLE props (HOME_MAX on the home), nearest to the arrival dock
--- first so capped profiles keep the props in the opening view. `columns` is
--- Terrain.columns for the layout ({} for home); `policy` is content.homePolicy.
function M.plan(layout: any, columns: { any }, seed: number, policy: any?): { Placement }
	local rng = Rng.new(seed):fork(layout.id .. ":procprops")
	local candidates: { any } = {}
	if isHome(layout) then
		-- A jittered grid over the free ground between camp and shore, swept by angle from a
		-- seeded phase so the greedy spacing packs the narrow free band densely.
		local step = M.HOME_STEP
		local phase = rng:nextNumber() * math.pi * 2
		local index = 0
		for x = -M.HOME_RING[2], M.HOME_RING[2], step do
			for z = -M.HOME_RING[2], M.HOME_RING[2], step do
				local px = x + (rng:nextNumber() - 0.5) * step * 0.5
				local pz = z + (rng:nextNumber() - 0.5) * step * 0.5
				local radius = math.sqrt(px * px + pz * pz)
				if radius >= M.HOME_RING[1] and radius <= M.HOME_RING[2] then
					index += 1
					table.insert(candidates, {
						x = px,
						y = 2,
						z = pz,
						set = if index % 2 == 0 then "grassland" else "camp",
						sweep = (math.atan2(pz, px) - phase) % (math.pi * 2),
					})
				end
			end
		end
		table.sort(candidates, function(a, b)
			if a.sweep ~= b.sweep then
				return a.sweep < b.sweep
			end
			return a.x < b.x
		end)
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
	local cap = if isHome(layout) then M.HOME_MAX else M.MAX_PER_ROLE
	local roleScale = M.roleScale(layout, columns)
	local turns: { [string]: number } = {}
	for name in M.SETS do
		turns[name] = rng:fork(name):nextInteger(0, 3)
	end
	local chosen: { Placement } = {}
	for _, candidate in candidates do
		if #chosen >= cap then
			break
		end
		if not M.clear(layout, candidate.x, candidate.z, policy) then
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
			scale = (0.85 + math.floor(rng:nextNumber() * 40) / 100) * roleScale * (M.SET_SCALE[candidate.set] or 1),
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

--- Lowest world Y of a set of parts (anything with .CFrame and .Size): each part's
--- oriented box bottom. A MeshPart's box is its mesh bounds, so this is the prop's
--- bounding-box bottom on both the MeshPart and the Part-fallback paths.
function M.bottom(parts: { any }): number
	local lowest = math.huge
	for _, part in parts do
		local cf, size = part.CFrame, part.Size
		local half = (
			math.abs(cf.RightVector.Y) * size.X
			+ math.abs(cf.UpVector.Y) * size.Y
			+ math.abs(cf.LookVector.Y) * size.Z
		) / 2
		lowest = math.min(lowest, cf.Position.Y - half)
	end
	return lowest
end

--- Vertical offset that seats a prop whose bounding-box bottom is `bottom` on `ground`.
function M.seat(ground: number, bottom: number): number
	return ground - bottom
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
