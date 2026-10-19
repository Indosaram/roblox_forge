--!strict
-- Deterministic Robango Island heightfield. Pure math (no Instances, no randomness), shared by
-- the server world bootstrap, which writes it into Workspace.Terrain, and by world.spec.luau,
-- which proves every node and wildlife spawn stands on dry land inside its biome.
-- Layout: landing plateau in the middle (flat, the settlement grid), temperate forest hills to
-- the west (x < -44), coastal marsh flats to the east (x > 44), sand shoreline all around.
local M = {}

M.SEA_LEVEL = -4
M.SEABED = -12
M.BOTTOM = -16
M.HALF_X = 130
M.HALF_Z = 100
M.LANDING_TOP = -0.6
M.CELL = 4
-- Height of each biome node's gather part. A node's authored y is its ground (rounded to the half
-- stud, sunk half a stud so it never floats) plus half this height. Gather parts stay short: the
-- gather prompt sits one stud above the part and reach is 8 studs; tall visuals are decoration.
M.NODE_HEIGHT = {
	["forest-oak-windfall"] = 2.5,
	["forest-birch-stand"] = 4,
	["forest-hazel-thicket"] = 4,
	["forest-bramble-patch"] = 3.5,
	["forest-bracken-bed"] = 1.5,
	["forest-chanterelle-log"] = 2,
	["forest-flint-scree"] = 3,
	["forest-boulder-field"] = 4,
	["marsh-reed-bed"] = 3,
	["marsh-cattail-stand"] = 3,
	["marsh-cordgrass-tussock"] = 2.5,
	["marsh-samphire-flat"] = 1,
	["marsh-clay-bank"] = 2.5,
	["marsh-clam-bed"] = 1,
	["marsh-driftwood-line"] = 1.5,
}
-- Freshwater pools in the marsh, dug below sea level and flooded to it.
M.POOLS = {
	{ x = 78, z = -2, r = 5 },
	{ x = 88, z = 40, r = 5 },
}

local function smooth(edge0: number, edge1: number, value: number): number
	local t = math.clamp((value - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

export type Sample = { top: number, material: string, biome: string }

--- Terrain surface height, Enum.Material name and biome id at (x, z).
function M.sample(x: number, z: number): Sample
	local d = math.sqrt((x / M.HALF_X) ^ 2 + (z / M.HALF_Z) ^ 2)
	if d >= 1 then
		return { top = M.SEABED, material = "Sand", biome = "sea" }
	end
	local forest = smooth(-44, -64, x)
	local marsh = smooth(44, 64, x)
	local landing = 1 - forest - marsh
	local forestTop = 2 + 1.5 * math.sin(x / 9) * math.cos(z / 11) + math.cos((x - z) / 23)
	local marshTop = -2.4 + 0.35 * math.sin(x / 7) * math.sin(z / 6) - 0.5 * smooth(70, 110, x)
	local top = landing * M.LANDING_TOP + forest * forestTop + marsh * marshTop
	local pooled = false
	for _, pool in M.POOLS do
		local k = math.sqrt((x - pool.x) ^ 2 + (z - pool.z) ^ 2) / pool.r
		if k < 1 then
			pooled = true
			-- Deep enough that the 4-stud voxel under sea level is empty and floods.
			top += (M.SEA_LEVEL - 4.2 - top) * smooth(1, 0.6, k)
		end
	end
	local shore = smooth(0.84, 1, d)
	top += (M.SEABED - top) * shore
	local biome = if forest > 0.5 then "forest" elseif marsh > 0.5 then "marsh" else "landing"
	local material
	if pooled then
		material = "Mud"
	elseif shore > 0.12 or (top < M.SEA_LEVEL + 0.6 and marsh < 0.5) then
		material = "Sand"
	elseif biome == "marsh" then
		material = if math.sin(x / 5) + math.cos(z / 4) > 0.9 then "Grass" else "Mud"
	elseif biome == "forest" then
		material = if forestTop > 4 then "Ground" else "LeafyGrass"
	else
		material = "Grass"
	end
	return { top = top, material = material, biome = biome }
end

--- Authored y for a biome node part of `height` standing at (x, z).
function M.nodeY(x: number, z: number, height: number): number
	return math.floor(M.sample(x, z).top * 2 + 0.5) / 2 - 0.5 + height / 2
end

return M
