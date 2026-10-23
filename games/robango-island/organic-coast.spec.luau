--!strict
-- p34 coast gate: the harbor and every archipelago stage are organic islands like home.
-- Measured on the production fill-call recording: the coast radius varies with angle (no
-- union of axis-aligned blocks), and every authored gameplay point stands on dry land.
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")

local function organic(id: string): boolean
	return id == "rw.harbor" or string.match(id, "^rw%.a%d+%.s%d+$") ~= nil
end

local function build(layoutId: string): (any, any)
	local engine = Engine.new(nil, true)
	local world = engine.role.build(Content, Source, Policy, function()
		return 0
	end, layoutId, 1776)
	return engine, world
end

-- Highest dry-land surface at (x, z) from the recorded fills (seabed and water excluded).
local function surface(engine: any, x: number, z: number): number?
	local roblox = require("@lune/roblox")
	local workspace = engine.game:GetService("Workspace")
	local hit =
		workspace:Raycast(roblox.Vector3.new(x, 512, z), roblox.Vector3.new(0, -1024, 0), { IgnoreWater = true })
	return if hit then hit.Position.Y else nil
end

local SEA = -4

return {
	["organic coast radius varies with angle on harbor and stage islands"] = function()
		for _, layout in Content.layouts do
			if not organic(layout.id) then
				continue
			end
			local engine, world = build(layout.id)
			local hx = math.max(math.abs(layout.bounds.min.x), math.abs(layout.bounds.max.x))
			local hz = math.max(math.abs(layout.bounds.min.z), math.abs(layout.bounds.max.z))
			-- March inward along 36 rays; the coast is the first dry sample above sea level.
			local normalized = {}
			for index = 0, 35 do
				local angle = index * math.pi * 2 / 36
				local last = 0
				for r = 1.4, 0, -0.025 do
					local top = surface(engine, math.cos(angle) * r * hx, math.sin(angle) * r * hz)
					if top and top > SEA then
						last = r
						break
					end
				end
				-- Box metric: a rectangle (or stack of rectangles at the bounds) keeps this ~constant.
				table.insert(normalized, last * math.max(math.abs(math.cos(angle)), math.abs(math.sin(angle))))
			end
			local low, high, turns = math.huge, 0, 0
			for index, value in normalized do
				low, high = math.min(low, value), math.max(high, value)
				local before = normalized[(index - 2) % #normalized + 1]
				local after = normalized[index % #normalized + 1]
				if value > before and value >= after then
					turns += 1
				end
			end
			assert(
				high - low >= 0.12,
				layout.id .. string.format(" coast box radius spread %.3f is blocky", high - low)
			)
			assert(turns >= 3, layout.id .. " coast has " .. turns .. " lobes, expected an irregular outline")
			-- A union of axis-aligned blocks clipped to the layout bounds puts many rays exactly on
			-- the bounds rectangle (box radius 1). An organic coast crosses it at most a few times.
			local onBounds = 0
			for _, value in normalized do
				if value >= 0.97 and value <= 1.02 then
					onBounds += 1
				end
			end
			assert(onBounds <= 6, layout.id .. " coast follows the bounds rectangle on " .. onBounds .. " of 36 rays")
			-- Beach rim then grass interior; the land stays gently undulating.
			local roblox = require("@lune/roblox")
			local sand, green = 0, 0
			for _, fill in engine.terrainWrites do
				if fill.material == roblox.Enum.Material.Sand and fill.radius then
					sand += 1
				elseif
					fill.material == roblox.Enum.Material.Grass
					or fill.material == roblox.Enum.Material.LeafyGrass
					or fill.material == roblox.Enum.Material.Ground
				then
					green += 1
				end
			end
			assert(sand >= 60, layout.id .. " lacks a round beach rim: " .. sand)
			if layout.biomes[1] == "grassland" or layout.biomes[1] == "beach" then
				assert(green > 0, layout.id .. " lacks a green interior")
			end
			world.destroy()
		end
	end,
	["every authored gameplay point on harbor and stage islands stands on dry land"] = function()
		local checked = 0
		for _, layout in Content.layouts do
			if not organic(layout.id) then
				continue
			end
			local engine, world = build(layout.id)
			local points = {}
			for _, node in layout.resourceNodes do
				table.insert(points, { node.id, node.position })
			end
			for _, anchor in layout.anchors do
				table.insert(points, { anchor.id, anchor.position })
			end
			for _, spawn in layout.spawns do
				table.insert(points, { spawn.id, spawn.position })
			end
			for _, hazard in layout.hazards or {} do
				table.insert(points, { hazard.id or "hazard", hazard.position })
			end
			if layout.id ~= "rw.harbor" then
				for index = 1, 3 do
					table.insert(points, { "survey." .. index, Terrain.survey(layout, index) })
				end
			end
			for _, entry in points do
				local p = entry[2]
				for _, offset in { { 0, 0 }, { 6, 0 }, { -6, 0 }, { 0, 6 }, { 0, -6 } } do
					local top = surface(engine, p.x + offset[1], p.z + offset[2])
					assert(
						top and top > SEA + 1,
						string.format("%s:%s at (%d,%d) is off the island footprint", layout.id, entry[1], p.x, p.z)
					)
				end
				checked += 1
			end
			world.destroy()
		end
		assert(checked > 300, "harbor and stage gameplay points covered: " .. checked)
	end,
}
