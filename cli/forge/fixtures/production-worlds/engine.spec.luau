--!strict
-- The fake engine's raycast spatial index must return exactly what the full scan over every
-- settled fill returns. Compared ray by ray on a real production layout and on a dense synthetic
-- field (balls, blocks, cylinders, air carve-outs, water, wide fills, diagonal and long rays).
local roblox: any = require("@lune/roblox")
local Engine = require("./engine")
local Rng = require("../../../../core/domain/random/Rng")

local V = roblox.Vector3.new

local function describe(hit: any): string
	if hit == nil then
		return "nil"
	end
	return string.format("%.6f,%.6f,%.6f", hit.Position.X, hit.Position.Y, hit.Position.Z)
end

local function compare(build: (engine: any) -> (), rays: { { any } })
	local results: { { string } } = {}
	for pass, full in { false, true } do
		Engine.fullScan = full
		local ok, err = pcall(function()
			local engine = Engine.new(nil, true)
			build(engine)
			local workspace = engine.game:GetService("Workspace")
			local list = {}
			for _, ray in rays do
				table.insert(list, describe(workspace:Raycast(ray[1], ray[2], ray[3])))
			end
			results[pass] = list
		end)
		Engine.fullScan = false
		assert(ok, err)
	end
	local hits = 0
	for index = 1, #rays do
		assert(
			results[1][index] == results[2][index],
			string.format("ray %d: indexed %s vs full %s", index, results[1][index], results[2][index])
		)
		if results[1][index] ~= "nil" then
			hits += 1
		end
	end
	return hits
end

return {
	["indexed raycasts equal the full scan on a dense synthetic field"] = function()
		local rng = Rng.new(4242)
		local mats = { roblox.Enum.Material.Grass, roblox.Enum.Material.Sand, roblox.Enum.Material.Rock }
		local build = function(engine: any)
			local terrain = engine.game:GetService("Workspace").Terrain
			local r = Rng.new(99)
			for _ = 1, 300 do
				local x, z = r:nextInteger(-600, 600), r:nextInteger(-600, 600)
				local kind = r:nextInteger(1, 4)
				local mat = mats[r:nextInteger(1, #mats)]
				if kind == 1 then
					terrain:FillBall(V(x, r:nextInteger(-10, 20), z), r:nextInteger(2, 40), mat)
				elseif kind == 2 then
					terrain:FillBlock(roblox.CFrame.new(x, 0, z), V(r:nextInteger(1, 80), 8, r:nextInteger(1, 80)), mat)
				elseif kind == 3 then
					terrain:FillCylinder(roblox.CFrame.new(x, 2, z), r:nextInteger(2, 12), r:nextInteger(3, 50), mat)
				else
					terrain:FillBall(V(x, 4, z), r:nextInteger(2, 20), roblox.Enum.Material.Air)
				end
			end
			-- Wide fills land in the unbinned list.
			terrain:FillBlock(roblox.CFrame.new(0, -20, 0), V(4000, 4, 4000), roblox.Enum.Material.Water)
			terrain:FillBlock(roblox.CFrame.new(0, -30, 0), V(3000, 2, 3000), roblox.Enum.Material.Sand)
			engine.game:GetService("RunService").Heartbeat:Wait()
		end
		local rays = {}
		for _ = 1, 1500 do
			local x, z = rng:nextNumber() * 1300 - 650, rng:nextNumber() * 1300 - 650
			local style = rng:nextInteger(1, 4)
			local params = if rng:nextInteger(1, 2) == 1 then { IgnoreWater = true } else nil
			if style == 1 then
				table.insert(rays, { V(x, 512, z), V(0, -1024, 0), params })
			elseif style == 2 then
				table.insert(
					rays,
					{ V(x, 6, z), V(rng:nextNumber() * 40 - 20, -2, rng:nextNumber() * 40 - 20), params }
				)
			elseif style == 3 then
				table.insert(
					rays,
					{ V(x, 30, z), V(rng:nextNumber() * 4000 - 2000, -60, rng:nextNumber() * 9 - 4), params }
				)
			else
				table.insert(rays, { V(x, -100, z), V(0, 300, 0), params })
			end
		end
		local hits = compare(build, rays)
		assert(hits > 300 and hits < #rays, "field too sparse or too dense to compare: " .. hits)
	end,

	["indexed raycasts equal the full scan on the production harbor and a stage island"] = function()
		local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
		local Source = require("../../../../games/robango-island/src/shared/SurvivalWorldConfig")
		local Policy = require("../../../../games/robango-island/src/shared/WildlifePolicy")
		for _, layoutId in { "rw.harbor", "rw.a1.s1" } do
			local rng = Rng.new(7):fork(layoutId)
			local rays = {}
			for _ = 1, 600 do
				local x, z = rng:nextNumber() * 700 - 350, rng:nextNumber() * 700 - 350
				if rng:nextInteger(1, 3) == 1 then
					table.insert(rays, { V(x, 8, z), V(rng:nextNumber() * 30 - 15, -1, rng:nextNumber() * 30 - 15) })
				else
					table.insert(rays, { V(x, 512, z), V(0, -1024, 0), { IgnoreWater = true } })
				end
			end
			local hits = compare(function(engine: any)
				engine.role.build(Content, Source, Policy, function()
					return 0
				end, layoutId, 1776)
				engine.game:GetService("RunService").Heartbeat:Wait()
			end, rays)
			assert(hits > 50, layoutId .. " rays hit too little land to compare: " .. hits)
		end
	end,
}
