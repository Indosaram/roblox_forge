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

-- Fast top-down material sampler over the recorded fills (latest write wins), binned by
-- 32-stud tiles; true for a dry, non-sand surface.
local function greenAt(engine: any, roblox: any): (number, number) -> boolean
	local bins: { [number]: { number } } = {}
	for index, fill in engine.terrainWrites do
		local hx = if fill.radius then fill.radius else fill.size.X / 2
		local hz = if fill.radius then fill.radius else fill.size.Z / 2
		for bx = math.floor((fill.position.X - hx) / 32), math.floor((fill.position.X + hx) / 32) do
			for bz = math.floor((fill.position.Z - hz) / 32), math.floor((fill.position.Z + hz) / 32) do
				local key = bx * 4096 + bz
				bins[key] = bins[key] or {}
				table.insert(bins[key], index)
			end
		end
	end
	return function(x: number, z: number): boolean
		local spans, bounds = {}, {}
		for _, index in bins[math.floor(x / 32) * 4096 + math.floor(z / 32)] or {} do
			local fill = engine.terrainWrites[index]
			local low, high = nil, nil
			local d2 = (x - fill.position.X) ^ 2 + (z - fill.position.Z) ^ 2
			if fill.height then
				if d2 <= fill.radius ^ 2 then
					low, high = fill.position.Y - fill.height / 2, fill.position.Y + fill.height / 2
				end
			elseif fill.radius then
				if d2 < fill.radius ^ 2 then
					local h = math.sqrt(fill.radius ^ 2 - d2)
					low, high = fill.position.Y - h, fill.position.Y + h
				end
			elseif
				math.abs(x - fill.position.X) <= fill.size.X / 2
				and math.abs(z - fill.position.Z) <= fill.size.Z / 2
			then
				low, high = fill.position.Y - fill.size.Y / 2, fill.position.Y + fill.size.Y / 2
			end
			if low and high then
				table.insert(spans, { low, high, index, fill.material })
				table.insert(bounds, low)
				table.insert(bounds, high)
			end
		end
		table.sort(bounds, function(a, b)
			return a > b
		end)
		for i = 2, #bounds do
			local y = (bounds[i - 1] + bounds[i]) / 2
			local latest, material = 0, nil
			for _, span in spans do
				if span[1] <= y and span[2] >= y and span[3] > latest then
					latest, material = span[3], span[4]
				end
			end
			if material and material ~= roblox.Enum.Material.Water and material ~= roblox.Enum.Material.Air then
				return bounds[i - 1] > SEA and material ~= roblox.Enum.Material.Sand
			end
		end
		return false
	end
end

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
				table.insert(points, { node.id, node.position, true })
			end
			for _, anchor in layout.anchors do
				table.insert(points, { anchor.id, anchor.position, true })
			end
			for _, spawn in layout.spawns do
				table.insert(points, { spawn.id, spawn.position, true })
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
				if entry[3] then
					-- Plateau smoothing never moves authored ground: nodes, anchors and spawns keep
					-- their catalog height.
					local top = surface(engine, p.x, p.z)
					assert(
						top and math.abs(top - p.y) <= 0.5,
						string.format("%s:%s ground %s, authored %.1f", layout.id, entry[1], tostring(top), p.y)
					)
				end
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
	["grass plateau edge follows the coast curve, not the square column grid"] = function()
		local roblox = require("@lune/roblox")
		local checked = 0
		for _, layout in Content.layouts do
			-- Desert stages are sand throughout, so they have no grass edge to measure.
			if not organic(layout.id) or layout.biomes[1] == "desert" then
				continue
			end
			local engine, world = build(layout.id)
			local green = greenAt(engine, roblox)
			local hx = math.max(math.abs(layout.bounds.min.x), math.abs(layout.bounds.max.x))
			local hz = math.max(math.abs(layout.bounds.min.z), math.abs(layout.bounds.max.z))
			-- Outermost grass point on 180 rays, refined by bisection to the sub-stud edge.
			local contour = {}
			for index = 0, 179 do
				local angle = index * math.pi * 2 / 180
				local c, s = math.cos(angle), math.sin(angle)
				for r = 1.4 * math.max(hx, hz), 0, -3 do
					if green(c * r, s * r) then
						local low, high = r, r + 3
						for _ = 1, 8 do
							local mid = (low + high) / 2
							if green(c * mid, s * mid) then
								low = mid
							else
								high = mid
							end
						end
						table.insert(contour, { c * low, s * low })
						break
					end
				end
			end
			assert(#contour >= 170, layout.id .. " grass edge found on " .. #contour .. " of 180 rays")
			-- A union of square columns puts its edge on x/z-parallel segments; a coast-following
			-- curve has only a small share of its length within 4 degrees of an axis.
			local total, aligned = 0, 0
			for index, p in contour do
				local q = contour[index % #contour + 1]
				local dx, dz = math.abs(q[1] - p[1]), math.abs(q[2] - p[2])
				local length = math.sqrt(dx * dx + dz * dz)
				total += length
				if math.min(dx, dz) <= length * math.sin(math.rad(4)) then
					aligned += length
				end
			end
			assert(
				aligned / total <= 0.5,
				string.format("%s grass edge is %.0f%% axis-aligned (stepped)", layout.id, aligned / total * 100)
			)
			checked += 1
			world.destroy()
		end
		assert(checked >= 15, "non-desert organic islands measured: " .. checked)
	end,
}
