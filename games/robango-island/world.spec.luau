--!strict
-- Robango Island world layout: every content node kind is placed, every wildlife species has a
-- home in its biome, and every placement stands on dry land of the deterministic heightfield.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local IslandTerrain = require("./src/shared/IslandTerrain")

local PACK = "games/robango-island"

local function load(path: string): any
	return luau.load(fs.readFile(PACK .. "/" .. path), {
		environment = {
			require = function(dependency)
				assert(dependency == "./SurvivalContent", "unexpected world policy dependency")
				return luau.load(fs.readFile(PACK .. "/src/shared/SurvivalContent.luau"))()
			end,
		},
	})()
end

local function contentIds(kind: string): { string }
	local document = serde.decode("yaml", fs.readFile(PACK .. "/content.yml"))
	local ids = {}
	for _, entry in document[kind] do
		table.insert(ids, entry.id)
	end
	return ids
end

local function expectedBiome(id: string): string
	return if string.sub(id, 1, 7) == "forest-" then "forest" else "marsh"
end

-- Biome of each spawned species (landing stand-ins excluded).
local SPECIES_BIOME: { [string]: string } = {
	["leaper-fernhop"] = "forest",
	["charger-oakbrow"] = "forest",
	["tailswing-mossback"] = "forest",
	["roarer-thicket"] = "forest",
	["scavenger-barkpicker"] = "forest",
	["herd-acorncrest"] = "forest",
	["ridge-strider"] = "forest",
	["bluff-bounder"] = "forest",
	["leaper-reedvault"] = "marsh",
	["charger-mudbrow"] = "marsh",
	["tailswing-shellclub"] = "marsh",
	["roarer-tidecall"] = "marsh",
	["scavenger-flotsam"] = "marsh",
	["herd-sedgewader"] = "marsh",
	["fen-trotter"] = "marsh",
}

local LANDING_NODES =
	{ "fallen-tree", "flint-outcrop", "fiber-bush", "berry-bush", "meat-cache", "branch-pile", "stone-pile" }

local function placementErrors(world: any, policy: any): { string }
	local errors: { string } = {}
	local placed: { [string]: boolean } = {}
	for _, node in world.nodes do
		placed[node.catalogId] = true
		local x, y, z = node.position.x, node.position.y, node.position.z
		if not table.find(LANDING_NODES, node.catalogId) then
			local sample = IslandTerrain.sample(x, z)
			local height = IslandTerrain.NODE_HEIGHT[node.catalogId]
			if height == nil then
				table.insert(errors, node.id .. " has no node height")
			elseif y ~= IslandTerrain.nodeY(x, z, height) then
				table.insert(errors, node.id .. " is not seated on the terrain")
			end
			if sample.top <= IslandTerrain.SEA_LEVEL then
				table.insert(errors, node.id .. " is under water")
			end
			if sample.biome ~= expectedBiome(node.catalogId) then
				table.insert(errors, node.id .. " is in " .. sample.biome)
			end
		end
	end
	for _, kind in contentIds("nodes") do
		if not placed[kind] then
			table.insert(errors, "node kind " .. kind .. " is not placed")
		end
	end
	local spawned: { [string]: boolean } = {}
	for _, spawn in policy.spawns do
		spawned[spawn.catalogId] = true
		local x, y, z = spawn.position.x, spawn.position.y, spawn.position.z
		local sample = IslandTerrain.sample(x, z)
		local ground = if math.abs(x) <= 32 and z >= -16 and z <= 32 then 0 else sample.top
		if sample.top <= IslandTerrain.SEA_LEVEL or sample.biome == "sea" then
			table.insert(errors, spawn.id .. " is off the landmass")
		end
		if y - ground < 3 or y - ground > 8 then
			table.insert(errors, spawn.id .. " spawn height is not just above the ground")
		end
		local biome = SPECIES_BIOME[spawn.catalogId]
		if biome and sample.biome ~= biome then
			table.insert(errors, spawn.id .. " is in " .. sample.biome .. ", expected " .. biome)
		end
	end
	for _, kind in { "grazer", "hunter" } do
		if not spawned[kind] then
			table.insert(errors, "species " .. kind .. " never spawns")
		end
	end
	for kind in SPECIES_BIOME do
		if not spawned[kind] then
			table.insert(errors, "landing species " .. kind .. " never spawns")
		end
	end
	if #policy.spawns > policy.maximum or policy.maximum > 32 then
		table.insert(errors, "wildlife budget exceeded")
	end
	return errors
end

local function catalogPlacementErrors(document: any): { string }
	local errors: { string } = {}
	local placed: { [string]: boolean } = {}
	local biomes: { [string]: { string } } = {}
	for _, species in document.wildlifeDetails do
		biomes[species.id] = species.biomes
	end
	for _, layout in document.layouts do
		for _, spawn in layout.spawns do
			placed[spawn.speciesId] = true
			local allowed = biomes[spawn.speciesId]
			if allowed then
				local compatible = false
				for _, biome in layout.biomes do
					if table.find(allowed, biome) then
						compatible = true
					end
				end
				if not compatible then
					table.insert(errors, spawn.id .. " has no compatible biome in " .. layout.id)
				end
			end
			local p, bounds = spawn.position, layout.bounds
			if
				p.x < bounds.min.x
				or p.x > bounds.max.x
				or p.y < bounds.min.y
				or p.y > bounds.max.y
				or p.z < bounds.min.z
				or p.z > bounds.max.z
			then
				table.insert(errors, spawn.id .. " is outside its layout")
			end
		end
	end
	for _, species in document.wildlife do
		if not placed[species.id] then
			table.insert(errors, "catalog species " .. species.id .. " never spawns")
		end
	end
	return errors
end

return {
	["every catalog species has a bounded v2 placement in an allowed biome"] = function()
		local document = serde.decode("yaml", fs.readFile(PACK .. "/content.yml"))
		local errors = catalogPlacementErrors(document)
		assert(#errors == 0, table.concat(errors, "; "))
	end,

	["NEGATIVE: missing v2 species and incompatible habitat are reported"] = function()
		local document = serde.decode("yaml", fs.readFile(PACK .. "/content.yml"))
		local missing = document.wildlifeDetails[1].id
		for _, layout in document.layouts do
			local kept = {}
			for _, spawn in layout.spawns do
				if spawn.speciesId ~= missing then
					table.insert(kept, spawn)
				end
			end
			layout.spawns = kept
		end
		document.wildlifeDetails[2].biomes = { "invalid-habitat" }
		local errors = catalogPlacementErrors(document)
		assert(#errors >= 2, table.concat(errors, "; "))
	end,

	["every node kind and species is placed on dry land inside its biome"] = function()
		local errors =
			placementErrors(load("src/shared/SurvivalWorldConfig.luau"), load("src/shared/WildlifePolicy.luau"))
		assert(#errors == 0, table.concat(errors, "; "))
	end,

	["NEGATIVE: a spawn in the sea and a missing node kind are reported"] = function()
		local world = load("src/shared/SurvivalWorldConfig.luau")
		local policy = load("src/shared/WildlifePolicy.luau")
		table.remove(world.nodes)
		policy.spawns[#policy.spawns].position = { x = 0, y = 4, z = -140 }
		local errors = placementErrors(world, policy)
		assert(#errors >= 2, "expected a sea spawn and an unplaced node kind, got " .. table.concat(errors, "; "))
	end,

	["aggressive species live at least 60 studs from the landing spawn"] = function()
		local document = serde.decode("yaml", fs.readFile(PACK .. "/content.yml"))
		local aggressive: { [string]: boolean } = {}
		for _, entry in document.wildlife do
			if entry.behavior ~= "grazer" and entry.behavior ~= "herd-grazer" and entry.id ~= "hunter" then
				aggressive[entry.id] = true
			end
		end
		for _, spawn in load("src/shared/WildlifePolicy.luau").spawns do
			if aggressive[spawn.catalogId] then
				local distance = math.sqrt(spawn.position.x ^ 2 + spawn.position.z ^ 2)
				assert(distance >= 60, spawn.id .. " is only " .. math.floor(distance) .. " studs from spawn")
			end
		end
	end,

	["the heightfield is deterministic and has a shoreline"] = function()
		local a, b = IslandTerrain.sample(-80, 20), IslandTerrain.sample(-80, 20)
		assert(a.top == b.top and a.material == b.material, "same input, same sample")
		assert(IslandTerrain.sample(0, 0).biome == "landing", "landing at the centre")
		assert(IslandTerrain.sample(0, 99).top < IslandTerrain.SEA_LEVEL, "shore drops below sea level")
		assert(IslandTerrain.sample(0, 150).biome == "sea", "open sea beyond the island")
	end,
}
