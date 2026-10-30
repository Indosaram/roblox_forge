--!strict
-- L12 biome look: every biome island (rw.aN.sM) gets its own day grade, water, material colours,
-- far-ground grading and a coast shelf + foam line; every other role keeps the global look, the
-- L10 spawn-screen materials are never recoloured, the arrival ring is never graded and night is
-- the same on every role.
local Content = require("./src/shared/SurvivalContent")
local BiomeLook = require("./src/shared/BiomeLook")
local BiomeKits = require("./src/shared/BiomeKits")
local SkyCycle = require("./src/shared/SkyCycle")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")

local FOG = { 192, 215, 205 }

local function islands(): { any }
	local list = {}
	for _, layout in Content.layouts do
		if string.match(layout.id, "^rw%.a%d+%.s%d+$") then
			table.insert(list, layout)
		end
	end
	assert(#list == 20, "biome islands: " .. #list)
	return list
end

return {
	["every biome island has a look and no other role does"] = function()
		local biomes = {}
		for _, layout in islands() do
			local look = assert(BiomeLook.of(layout), layout.id)
			biomes[look.biome] = true
			for name in look.terrain do
				assert(not BiomeLook.RESERVED[name], layout.id .. " recolours L10 material " .. name)
			end
		end
		for _, biome in { "grassland", "desert", "tropical", "swamp", "snow", "volcano" } do
			assert(biomes[biome], "no island uses the " .. biome .. " look")
		end
		for _, layout in Content.layouts do
			if not string.match(layout.id, "^rw%.a%d+%.s%d+$") then
				assert(BiomeLook.of(layout) == nil, layout.id .. " must keep the global look")
			end
		end
	end,
	["the arrival ring and authored ground are never graded; the far ground is"] = function()
		for _, layout in islands() do
			local look = assert(BiomeLook.of(layout))
			local arrivals = BiomeKits.arrivals(layout)
			local changed = 0
			for _, column in Terrain.columns(layout, 1776, 32) do
				local base = Terrain.ground(layout, column.x)
				local away = BiomeLook.away(layout, arrivals, column.x, column.z)
				local out = BiomeLook.grade(look, column.material, base, column.x, column.z, column.top, away)
				if not away then
					assert(out == column.material, layout.id .. " graded inside the arrival ring")
				elseif out ~= column.material then
					assert(column.material == base, layout.id .. " graded a non-base column " .. column.material)
					changed += 1
				end
			end
			assert(changed > 0, layout.id .. " far ground is one material")
		end
	end,
	["biome days differ, nights match the global night and fog caps hold"] = function()
		local seen = {}
		for _, layout in islands() do
			local look = BiomeLook.of(layout)
			local noon, night = SkyCycle.at(12, FOG, look), SkyCycle.at(1, FOG, look)
			local base = SkyCycle.at(1, FOG)
			assert(night.water[1] == base.water[1] and night.grade.tint[3] == base.grade.tint[3], "night is global")
			assert(night.atmosphere.density == base.atmosphere.density, "night air is global")
			local fog = SkyCycle.fog(noon, SkyCycle.VISUALS.clear)
			assert(fog.density <= SkyCycle.DAY_FOG.density and fog.haze <= SkyCycle.DAY_FOG.haze, "day fog cap")
			seen[table.concat(noon.water, ",") .. "|" .. table.concat(noon.grade.tint, ",")] = true
		end
		local count = 0
		for _ in seen do
			count += 1
		end
		assert(count >= 6, "distinct biome days: " .. count)
		local plain = SkyCycle.at(12, FOG)
		assert(plain.water[1] == 69 and plain.water[2] == 139 and plain.water[3] == 153, "global day water unchanged")
	end,
	["coast shelf stays under the sea and the foam line rings the island"] = function()
		for _, layout in islands() do
			local look = assert(BiomeLook.of(layout))
			local coast = Terrain.field(layout, 1776).coast
			local out = BiomeLook.coast(look, coast, Terrain.SEA)
			assert(#out.foam >= 200 and #out.shelf >= 300, layout.id .. " coast too sparse")
			for _, ball in out.shelf do
				assert(ball.y + ball.radius <= Terrain.SEA - 0.5, layout.id .. " shelf breaks the surface")
				assert(coast.depth(ball.x, ball.z) < 0, layout.id .. " shelf on land")
			end
			for _, strip in out.foam do
				assert(strip.top == Terrain.SEA and strip.width >= 5, layout.id .. " foam must fill the surface voxel")
			end
		end
	end,
}
