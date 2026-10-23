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

-- Highest solid surface at (x, z) from the recorded fills, binned by 32-stud tiles.
local function topAt(engine: any, roblox: any): (number, number) -> number?
	local bins: { [number]: { any } } = {}
	for _, fill in engine.terrainWrites do
		if fill.material == roblox.Enum.Material.Water or fill.material == roblox.Enum.Material.Air then
			continue
		end
		local hx = if fill.radius then fill.radius else fill.size.X / 2
		local hz = if fill.radius then fill.radius else fill.size.Z / 2
		for bx = math.floor((fill.position.X - hx) / 32), math.floor((fill.position.X + hx) / 32) do
			for bz = math.floor((fill.position.Z - hz) / 32), math.floor((fill.position.Z + hz) / 32) do
				local key = bx * 4096 + bz
				bins[key] = bins[key] or {}
				table.insert(bins[key], fill)
			end
		end
	end
	return function(x: number, z: number): number?
		local best: number? = nil
		for _, fill in bins[math.floor(x / 32) * 4096 + math.floor(z / 32)] or {} do
			local d2 = (x - fill.position.X) ^ 2 + (z - fill.position.Z) ^ 2
			local high: number? = nil
			if fill.height then
				high = if d2 <= fill.radius ^ 2 then fill.position.Y + fill.height / 2 else nil
			elseif fill.radius then
				high = if d2 < fill.radius ^ 2 then fill.position.Y + math.sqrt(fill.radius ^ 2 - d2) else nil
			elseif
				math.abs(x - fill.position.X) <= fill.size.X / 2
				and math.abs(z - fill.position.Z) <= fill.size.Z / 2
			then
				high = fill.position.Y + fill.size.Y / 2
			end
			if high and (best == nil or high > best) then
				best = high
			end
		end
		return best
	end
end

-- Largest height step between 8-stud neighbours on dry land within 32 studs of the sea.
-- Measured at 1776: 813fb07 reached 10 on a3.s3/a3.s4 (the east slab ending in a wall on the
-- beach) and 12-18 on a4/a5; with the coastal ramp every layout stays at or below 9 (a rounded
-- cap plus beach dome over one sample). 9.5 keeps that margin and rejects a 10-stud wall.
local COAST_STEP = 9.5
local function coastStep(engine: any, layout: any, roblox: any): (number, string)
	local top = topAt(engine, roblox)
	local S = 8
	local heights: { [string]: number } = {}
	local low, high = layout.bounds.min, layout.bounds.max
	for x = low.x - 64, high.x + 64, S do
		for z = low.z - 64, high.z + 64, S do
			heights[x .. "," .. z] = top(x, z) or -20
		end
	end
	local worst, at = 0, ""
	for x = low.x - 64, high.x + 64, S do
		for z = low.z - 64, high.z + 64, S do
			local v = heights[x .. "," .. z]
			if v <= SEA + 1 then
				continue
			end
			local coastal = false
			for dx = -4, 4 do
				for dz = -4, 4 do
					local n = heights[x + dx * S .. "," .. z + dz * S]
					coastal = coastal or (n ~= nil and n <= SEA + 1)
				end
			end
			if coastal then
				for _, d in { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } } do
					local n = heights[x + d[1] * S .. "," .. z + d[2] * S]
					if n and n > SEA + 1 and math.abs(n - v) > worst then
						worst, at = math.abs(n - v), x .. "," .. z
					end
				end
			end
		end
	end
	return worst, at
end

-- Share of the high flat ground's boundary that runs straight along x or z. Samples above 12
-- studs whose four 8-stud neighbours are within 0.5 are flat; a boundary sample is straight when
-- it is open on one axis only and both neighbours along the edge are boundary samples open the
-- same way. Square columns cleared along straight catalog paths give 0.64 (a3.s3) and 0.67
-- (a3.s4) at seed 1776; round-lobed cap edges stay near 0.25.
local FLAT_AXIS_SHARE = 0.5
local function flatAxisShare(engine: any, layout: any, roblox: any): (number, number)
	local top = topAt(engine, roblox)
	local S = 8
	local low, high = layout.bounds.min, layout.bounds.max
	local heights: { [string]: number } = {}
	for x = low.x - 64, high.x + 64, S do
		for z = low.z - 64, high.z + 64, S do
			heights[x .. "," .. z] = top(x, z) or -20
		end
	end
	local flat: { [string]: boolean } = {}
	for x = low.x - 64, high.x + 64, S do
		for z = low.z - 64, high.z + 64, S do
			local v = heights[x .. "," .. z]
			if v > 12 then
				local ok = true
				for _, d in { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } } do
					local n = heights[x + d[1] * S .. "," .. z + d[2] * S]
					ok = ok and n ~= nil and math.abs(n - v) <= 0.5
				end
				flat[x .. "," .. z] = ok
			end
		end
	end
	local function at(x: number, z: number): boolean
		return flat[x .. "," .. z] == true
	end
	local edges, straight = 0, 0
	for x = low.x - 64, high.x + 64, S do
		for z = low.z - 64, high.z + 64, S do
			if not at(x, z) then
				continue
			end
			local openX = (if at(x + S, z) then 0 else 1) + (if at(x - S, z) then 0 else 1)
			local openZ = (if at(x, z + S) then 0 else 1) + (if at(x, z - S) then 0 else 1)
			if openX + openZ == 0 then
				continue
			end
			edges += 1
			if openX == 1 and openZ == 0 then
				local side = if at(x + S, z) then -S else S
				if at(x, z + S) and not at(x + side, z + S) and at(x, z - S) and not at(x + side, z - S) then
					straight += 1
				end
			elseif openZ == 1 and openX == 0 then
				local side = if at(x, z + S) then -S else S
				if at(x + S, z) and not at(x + S, z + side) and at(x - S, z) and not at(x - S, z + side) then
					straight += 1
				end
			end
		end
	end
	return if edges > 0 then straight / edges else 0, edges
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
			-- High authored ground ramps down to the beach instead of ending in a wall.
			local step, at = coastStep(engine, layout, roblox)
			assert(
				step <= COAST_STEP,
				string.format("%s coast drops %.1f studs in one 8-stud step at %s", layout.id, step, at)
			)
			-- High flat ground beside straight catalog paths ends in round lobes, not square terraces.
			local share, edges = flatAxisShare(engine, layout, roblox)
			assert(
				share <= FLAT_AXIS_SHARE,
				string.format("%s high flat edge is %.2f axis-aligned over %d samples", layout.id, share, edges)
			)
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
