--!strict
-- p39 walkability gate: every catalog path on the harbor and every archipelago stage is walkable
-- by a default character without jumping. Each path polyline is sampled every ~2 studs on its
-- centre line and both edges (1 stud inside) over the walk surface the world builds: the highest
-- solid terrain fill from the production fill-call recording, or the path ribbon part where it
-- is higher. Seed 1776 at 6d8fef3: a3 bypass ramps stepped 5 studs, a4 6-7 and a5 8-9.
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")

-- Roblox auto-steps about 2 studs; 0.75 studs/stud is about 37 degrees.
local MAX_STEP = 2.5
local MAX_SLOPE = 0.75
local SPACING = 2
-- An authored point is reached when a flood-filled walk sample within REACH studs stands
-- within MAX_STEP of its height. The water surface is y = -4; drier samples are walkable.
local REACH = 12
local DRY = -3.5

-- Highest solid surface at (x, z) from the recorded fills, binned by 32-stud tiles.
local function topAt(engine: any, roblox: any): (number, number) -> number
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
	return function(x: number, z: number): number
		local best = -math.huge
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
			if high and high > best then
				best = high
			end
		end
		return best
	end
end

-- Top of the highest path ribbon part covering (x, z); RoleWorld lays one per polyline segment
-- at the catalog height, path.width wide.
local function ribbonAt(layout: any): (number, number) -> number
	return function(x: number, z: number): number
		local best = -math.huge
		for _, path in layout.paths do
			for i = 2, #path.points do
				local a, b = path.points[i - 1], path.points[i]
				local dx, dz = b.x - a.x, b.z - a.z
				local length = math.sqrt(dx * dx + dz * dz)
				if length == 0 then
					continue
				end
				local along = ((x - a.x) * dx + (z - a.z) * dz) / length
				local side = math.abs(((x - a.x) * dz - (z - a.z) * dx) / length)
				if along >= -0.5 and along <= length + 0.5 and side <= path.width / 2 then
					best = math.max(best, a.y + (b.y - a.y) * math.clamp(along / length, 0, 1))
				end
			end
		end
		return best
	end
end

-- Worst single step between neighbouring samples and worst rise over 8 studs, along every path.
local function measure(engine: any, layout: any, roblox: any): (number, string, number, string)
	local top, ribbon = topAt(engine, roblox), ribbonAt(layout)
	local low, high = layout.bounds.min, layout.bounds.max
	local step, stepAt, slope, slopeAt = 0, "", 0, ""
	for _, path in layout.paths do
		for i = 2, #path.points do
			local a, b = path.points[i - 1], path.points[i]
			local length = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
			if length == 0 then
				continue
			end
			local ux, uz = (b.x - a.x) / length, (b.z - a.z) / length
			local n = math.max(1, math.ceil(length / SPACING))
			local spacing = length / n
			local window = math.max(1, math.round(8 / spacing))
			for _, offset in { -(path.width / 2 - 1), 0, path.width / 2 - 1 } do
				local history: { number } = {}
				for s = 0, n do
					local t = s / n
					local x, z = a.x + (b.x - a.x) * t - uz * offset, a.z + (b.z - a.z) * t + ux * offset
					-- Habitat approaches start offshore, where RoleWorld lays no ribbon.
					if x < low.x or x > high.x or z < low.z or z > high.z then
						table.clear(history)
						continue
					end
					local y = math.max(top(x, z), ribbon(x, z))
					local where = string.format("%s#%d (%.0f,%.0f) offset %.0f", path.id, i, x, z, offset)
					local previous = history[#history]
					if previous and math.abs(y - previous) > step then
						step, stepAt = math.abs(y - previous), where
					end
					table.insert(history, y)
					if #history > window then
						local rise = math.abs(y - history[#history - window]) / (window * spacing)
						if rise > slope then
							slope, slopeAt = rise, where
						end
					end
				end
			end
		end
	end
	return step, stepAt, slope, slopeAt
end

-- Flood-fills the walk surface on a SPACING grid from the entry dock: a move between 4-neighbours
-- is allowed when both are dry and the step is at most MAX_STEP. Returns authored points that no
-- reached sample within REACH studs (and within MAX_STEP of the point's height) supports.
local function unreachable(engine: any, layout: any, roblox: any): { string }
	local top, ribbon = topAt(engine, roblox), ribbonAt(layout)
	local low, high = layout.bounds.min, layout.bounds.max
	local heights: { [number]: number } = {}
	local function key(i: number, j: number): number
		return i * 65536 + j
	end
	local function height(i: number, j: number): number
		local k = key(i, j)
		local y = heights[k]
		if y == nil then
			y = math.max(top(i * SPACING, j * SPACING), ribbon(i * SPACING, j * SPACING))
			heights[k] = y
		end
		return y
	end
	local entry = layout.anchors[1].position
	for _, anchor in layout.anchors do
		if anchor.id == "entry" then
			entry = anchor.position
		end
	end
	local margin = 64 / SPACING
	local i0, i1 = math.floor(low.x / SPACING) - margin, math.ceil(high.x / SPACING) + margin
	local j0, j1 = math.floor(low.z / SPACING) - margin, math.ceil(high.z / SPACING) + margin
	local start = { math.round(entry.x / SPACING), math.round(entry.z / SPACING) }
	local reached: { [number]: boolean } = { [key(start[1], start[2])] = true }
	local queue, head = { start }, 1
	while head <= #queue do
		local at = queue[head]
		head += 1
		local y = height(at[1], at[2])
		for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local i, j = at[1] + d[1], at[2] + d[2]
			local k = key(i, j)
			if not reached[k] and i >= i0 and i <= i1 and j >= j0 and j <= j1 then
				local n = height(i, j)
				if n > DRY and math.abs(n - y) <= MAX_STEP then
					reached[k] = true
					table.insert(queue, { i, j })
				end
			end
		end
	end
	local missing = {}
	local r = math.ceil(REACH / SPACING)
	for _, list in { layout.resourceNodes, layout.anchors, layout.spawns } do
		for _, item in list do
			local p = item.position
			local ci, cj = math.round(p.x / SPACING), math.round(p.z / SPACING)
			local best = math.huge
			for i = ci - r, ci + r do
				for j = cj - r, cj + r do
					local distance = math.sqrt((i * SPACING - p.x) ^ 2 + (j * SPACING - p.z) ^ 2)
					if
						distance < best
						and distance <= REACH
						and reached[key(i, j)]
						and math.abs(height(i, j) - p.y) <= MAX_STEP
					then
						best = distance
					end
				end
			end
			if best == math.huge then
				table.insert(missing, string.format("%s (%.0f,%.0f,%.0f)", item.id, p.x, p.y, p.z))
			end
		end
	end
	return missing
end

return {
	["every path on harbor, stage and frontier islands is walkable without jumping"] = function()
		local roblox = require("@lune/roblox")
		local checked, failures = 0, {}
		for _, layout in Content.layouts do
			if not Terrain.graded(layout) then
				continue
			end
			local engine = Engine.new(nil, true)
			local world = engine.role.build(Content, Source, Policy, function()
				return 0
			end, layout.id, 1776)
			local step, stepAt, slope, slopeAt = measure(engine, layout, roblox)
			if step > MAX_STEP then
				table.insert(failures, string.format("%s step %.2f at %s", layout.id, step, stepAt))
			end
			if slope > MAX_SLOPE then
				table.insert(failures, string.format("%s slope %.2f at %s", layout.id, slope, slopeAt))
			end
			for _, missing in unreachable(engine, layout, roblox) do
				table.insert(failures, string.format("%s unreachable %s", layout.id, missing))
			end
			checked += 1
			world.destroy()
		end
		assert(#failures == 0, table.concat(failures, "\n"))
		assert(checked >= 25, "harbor, stage and frontier layouts measured: " .. checked)
	end,
}
