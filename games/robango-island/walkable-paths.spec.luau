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

-- Roblox auto-steps about 2 studs; 0.75 studs/stud is about 37 degrees.
local MAX_STEP = 2.5
local MAX_SLOPE = 0.75
local SPACING = 2

local function organic(id: string): boolean
	return id == "rw.harbor" or string.match(id, "^rw%.a%d+%.s%d+$") ~= nil
end

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

return {
	["every path on harbor and stage islands is walkable without jumping"] = function()
		local roblox = require("@lune/roblox")
		local checked, failures = 0, {}
		for _, layout in Content.layouts do
			if not organic(layout.id) then
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
			checked += 1
			world.destroy()
		end
		assert(#failures == 0, table.concat(failures, "\n"))
		assert(checked >= 21, "harbor and stage layouts measured: " .. checked)
	end,
}
