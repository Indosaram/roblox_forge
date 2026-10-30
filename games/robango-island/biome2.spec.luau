--!strict
-- Biome2 (R11-3/R11-4/R11-6/R11-7, raptor tail): B1b islands get seeded groves (swamp dead forest
-- with standing pools and reed rims, desert scrub with rock clusters, snow frozen shrubs and drift
-- mounds under pines, volcano basalt stacks, dead stumps and glow cracks) inside the pre-biome2
-- per-island kit part and triangle totals; grassland path banks grade to the warm ochre Mud outside
-- the arrival ring; the raptor tail fan has tapered cards and no near-white colours.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Kits = require("./src/shared/BiomeKits")
local B1b = require("./src/shared/BiomeKitsB1b")
local BiomeLook = require("./src/shared/BiomeLook")

local document = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
local layouts: { [string]: any } = {}
for _, layout in document.layouts do
	layouts[layout.id] = layout
end

local SEED = 20261027
-- Pre-biome2 plans at SEED (15d715a): kit placements and B1b LOD0 triangles per island. The phone
-- sits at ~885 of 900 MB PSS, so these totals are the ceiling.
local BUDGET = {
	["rw.a2.s2"] = { parts = 19433, tris = 5317484 },
	["rw.a1.s4"] = { parts = 15605, tris = 3787926 },
	["rw.a4.s1"] = { parts = 13608, tris = 2355390 },
	["rw.a5.s1"] = { parts = 10714, tris = 1569628 },
}
local GROVE_ROWS = {
	["rw.a2.s2"] = { "veg.swamp.dead-lean", "veg.swamp.reed-clump" },
	["rw.a1.s4"] = { "veg.desert.scrub", "rock.desert.rock-cluster" },
	["rw.a4.s1"] = { "veg.tundra.frozen-shrub", "rock.tundra.drift-mound" },
	["rw.a5.s1"] = { "rock.volcano.basalt-stack", "rock.volcano.dead-stump", "clutter.volcano.glow-crack" },
}

local plans: { [string]: { any } } = {}
local function plan(id: string): ({ any }, { any })
	local columns = Terrain.columns(layouts[id], SEED, 32)
	plans[id] = plans[id] or Kits.plan(layouts[id], columns, SEED, Terrain)
	return plans[id], columns
end

return {
	["B1b islands carry grove rows in clumps"] = function()
		for id, keys in GROVE_ROWS do
			local placements = plan(id)
			for _, key in keys do
				local list = {}
				for _, p in placements do
					if p.key == key then
						table.insert(list, p)
					end
				end
				assert(#list >= 40, id .. ": " .. key .. " placed " .. #list)
				-- Clumped, not uniform: most grove members have another of the same row within 16 studs.
				local near = 0
				for i, p in list do
					for j, q in list do
						if i ~= j and (p.x - q.x) ^ 2 + (p.z - q.z) ^ 2 <= 16 * 16 then
							near += 1
							break
						end
					end
				end
				assert(near >= #list * 0.5, id .. ": " .. key .. " is not clumped (" .. near .. "/" .. #list .. ")")
			end
		end
	end,
	["grove rows have generator meshes and triangle counts"] = function()
		local sources = fs.readFile("games/robango-island/assets/blender/gen_kit_swamp.py")
			.. fs.readFile("games/robango-island/assets/blender/gen_kit_biomes.py")
		for _, keys in GROVE_ROWS do
			for _, key in keys do
				local model = string.gsub(string.gsub(key, "%.", "_"), "%-", "_")
				assert(string.find(sources, '"' .. model .. '"', 1, true), key .. " has no generator mesh")
				assert(Kits.modelKey[model] == key, key .. " model alias")
				assert((Kits.tris[key] or 0) > 0 and Kits.tris[key] <= 200, key .. " tris " .. tostring(Kits.tris[key]))
			end
		end
	end,
	["groves keep each island inside its pre-biome2 part and triangle totals"] = function()
		for id, budget in BUDGET do
			local placements = plan(id)
			local tris = 0
			for _, p in placements do
				local model = string.gsub(string.gsub(p.key, "%.", "_"), "%-", "_")
				tris += B1b.tris[model] or 0
			end
			assert(#placements <= budget.parts, id .. ": parts " .. #placements .. " > " .. budget.parts)
			assert(tris <= budget.tris, id .. ": tris " .. tris .. " > " .. budget.tris)
			-- Ground cover stays: the grass trade never removes more than 60% of the grass cards.
			local grass = 0
			for _, p in placements do
				grass += if p.family == "grass" then 1 else 0
			end
			assert(grass >= 2000, id .. ": grass cards " .. grass)
		end
	end,
	["swamp pools sit on dry flat land with reed rims, off paths and arrivals"] = function()
		local layout = layouts["rw.a2.s2"]
		local placements, columns = plan("rw.a2.s2")
		local pools = Kits.pools(layout, columns, SEED, Terrain)
		assert(#pools >= 20, "swamp pools: " .. #pools)
		local ground = Kits.ground(columns)
		for _, pool in pools do
			assert(Kits.allowed(layout, Terrain, ground, pool.x, pool.z, pool.radius), "pool on blocked ground")
			assert(ground.slope(pool.x, pool.z) <= 0.15, "pool on a slope")
		end
		local rimmed = 0
		for _, p in placements do
			if p.key == "veg.swamp.reed-clump" then
				for _, pool in pools do
					local d = math.sqrt((p.x - pool.x) ^ 2 + (p.z - pool.z) ^ 2)
					if d >= pool.radius and d <= pool.radius + 3.5 then
						rimmed += 1
						break
					end
				end
			end
		end
		assert(rimmed >= #pools * 3, "reed rims: " .. rimmed)
		local desertColumns = Terrain.columns(layouts["rw.a1.s4"], SEED, 32)
		assert(#Kits.pools(layouts["rw.a1.s4"], desertColumns, SEED, Terrain) == 0, "only swamps have pools")
	end,
	["grassland path banks grade to warm ochre outside the arrival ring only"] = function()
		local look = assert(BiomeLook.of(layouts["rw.a1.s1"]))
		assert(look.verge and look.verge.material == "Mud", "grassland verge rule")
		local mud = look.terrain.Mud
		assert(mud[1] > mud[2] and mud[2] > mud[3], "verge Mud is warm ochre")
		local changed, total = 0, 0
		for x = -400, 400, 8 do
			for z = -400, 400, 8 do
				total += 1
				assert(BiomeLook.verge(look, "Grass", x, z, false) == "Grass", "graded inside the arrival ring")
				assert(BiomeLook.verge(look, "Sand", x, z, true) == "Sand", "sand is never a verge")
				changed += if BiomeLook.verge(look, "Grass", x, z, true) == "Mud" then 1 else 0
			end
		end
		assert(changed >= total * 0.5 and changed < total, "verge share " .. changed .. "/" .. total)
		for _, biome in { "desert", "snow", "swamp", "volcano", "tropical" } do
			assert(BiomeLook.looks[biome].verge == nil, biome .. " keeps its path banks")
		end
		local role = fs.readFile("games/robango-island/src/server/RoleWorld.luau")
		assert(string.find(role, "BiomeLook.verge(", 1, true), "RoleWorld writes path banks through BiomeLook.verge")
		assert(string.find(role, "BiomeKits.pools(", 1, true), "RoleWorld writes the swamp pools")
	end,
	["volcano ground is ash and the swamp ground is dark wet mud"] = function()
		local volcano = BiomeLook.looks.volcano
		assert(volcano.patch.material == "Sand" and volcano.patch.share >= 0.4, "volcano ash patches")
		local ash = volcano.terrain.Sand
		assert(math.max(ash[1], ash[2], ash[3]) - math.min(ash[1], ash[2], ash[3]) <= 16, "ash is grey")
		local swamp = BiomeLook.looks.swamp.terrain.Mud
		assert(swamp[1] + swamp[2] + swamp[3] <= 150, "swamp mud is dark")
		assert(Kits.GLOW["clutter.volcano.glow-crack"], "glow cracks render emissive")
	end,
	["raptor tail fans are tapered and never near-white"] = function()
		local source = fs.readFile("games/robango-island/assets/blender/gen_creatures.py")
		local taper = tonumber(string.match(source, "\nTAIL_TAPER = ([%d%.]+)"))
		assert(taper and taper < 0.6, "tail cards taper")
		local _, uses = string.gsub(source, "TAIL_TAPER%)", "")
		assert(uses >= 2, "tail fan and plume cards use TAIL_TAPER")
		for _, species in { "gallimimus", "utahraptor", "velociraptor" } do
			local at = assert(string.find(source, "\nFEATHERS = {", 1, true), "FEATHERS table")
			local from = assert(string.find(source, '"' .. species .. '": dict(', at, true), species)
			local block = string.sub(source, from, (string.find(source, "thigh=", from, true)))
			for _, zone in { "tail", "tailcov" } do
				local root, tip = string.match(block, "[^%w]" .. zone .. '=%(%d+, [%d%.]+, [%d%.]+, "#(%x+)", "#(%x+)"')
				assert(root and tip, species .. " " .. zone)
				for _, hex in { root, tip } do
					for i = 1, 5, 2 do
						local channel = tonumber(string.sub(hex, i, i + 1), 16) :: number
						assert(channel <= 0xD0, species .. " " .. zone .. " #" .. hex .. " is near-white")
					end
				end
			end
		end
	end,
}
