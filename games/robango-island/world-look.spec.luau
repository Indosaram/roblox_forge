--!strict
-- D2 look pins (Durango side-by-side, R12/R13/R17/R20): the night fog never closes in before the
-- far edge of the play camera's frame on any role, warm lights pool at the spawn, the camp and
-- the town, the town layout holds real buildings, plots show a border and a claim sign, and the
-- opening set pieces are multi-part models that take their B3 mesh rows when those load.
local fs = require("@lune/fs")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local SkyCycle = require("./src/shared/SkyCycle")
local CameraConfig = require("./src/shared/CameraConfig")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Dressing = require("./src/server/WorldDressing")
local roblox: any = require("@lune/roblox")

local CLIENT = "games/robango-island/src/client/RobangoIslandClient.client.luau"
local FOG = { 192, 215, 205 }

-- Far edge of the play camera's frame: the ground point under the top of the view, at the
-- widest zoom the client allows (CameraConfig.maxDistance, its pitch and FOV).
local function cameraReach(): number
	local source = fs.readFile(CLIENT)
	assert(string.find(source, "require(Shared.CameraConfig)", 1, true), "client camera config")
	local height = CameraConfig.maxDistance * math.sin(math.rad(CameraConfig.pitch))
	return height / math.sin(math.rad(CameraConfig.pitch - CameraConfig.fieldOfView / 2))
end

local function warm(light: any): boolean
	local c = light.Color
	return c.R > c.B + 0.2 and c.R >= c.G
end

local function lightsNear(root: any, x: number, z: number, radius: number): number
	local count = 0
	for _, light in root:GetDescendants() do
		if light.ClassName == "PointLight" and warm(light) and light.Parent then
			-- The headless fake keeps Position and CFrame apart: torches set CFrame, parts Position.
			local host = light.Parent
			local p = if host.Position.Magnitude > 0 then host.Position else host.CFrame.Position
			if (p.X - x) ^ 2 + (p.Z - z) ^ 2 <= radius * radius then
				count += 1
			end
		end
	end
	return count
end

local function anchor(layout: any, id: string): any
	for _, value in layout.anchors do
		if value.id == id then
			return value.position
		end
	end
	error("anchor " .. id)
end

return {
	["night fog ends beyond the play camera's far frame edge on every role and weather"] = function()
		local reach = cameraReach()
		assert(reach > 60, "camera reach measured: " .. reach)
		local night = SkyCycle.at(1, FOG)
		local brawl = { startsAt = 0, policy = Content.brawlPolicy }
		for _, layout in Content.layouts do
			for window = 0, 23 do
				local t = window * SkyCycle.WINDOW_SECONDS + 5
				local weather = SkyCycle.weatherAt(Content, layout, 1776, t, 0, brawl)
				local fog = SkyCycle.fog(night, weather)
				local visible = SkyCycle.visibility(fog.density, fog.haze)
				assert(
					visible >= reach,
					string.format("%s %s night fog ends at %.0f < camera %.0f", layout.id, weather.id, visible, reach)
				)
			end
		end
		-- Daytime weather keeps its look: the cap only closes in with night.
		local noon = SkyCycle.fog(SkyCycle.at(12, FOG), SkyCycle.VISUALS.fog)
		assert(noon.density >= 0.5, "day fog weather stays thick")
	end,
	["night is moonlit blue light, not a blue filter or a black frame"] = function()
		-- R17 lane (Studio-tuned): the blue lives in the light (ambients, sky shift); the grade tint
		-- stays near neutral and fires stay local pools (day-night.spec has the full lane spec).
		local night = SkyCycle.at(1, FOG)
		local lum = function(c: { number }): number
			return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
		end
		assert(lum(night.outdoorAmbient) >= 70, "moonlit outdoor ambient is not black")
		assert(lum(night.ambient) >= 60, "moonlit ambient is not black")
		local tint = night.grade.tint
		assert(tint[3] - tint[1] <= 72, "a light grade tint, not a saturated blue filter")
		assert(night.fire.range <= 12, "fire pools stay local at night")
	end,
	["warm lights pool at the spawn, the explore camp and the town at night"] = function()
		local engine = Engine.new()
		local explore = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.explore10", 1776)
		local root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
		local layout = explore.layout
		local camp, entry = anchor(layout, "station.campfire.t1"), anchor(layout, "entry")
		assert(lightsNear(root, camp.x, camp.z, 40) >= 4, "explore camp: >= 4 warm lights")
		assert(lightsNear(root, entry.x, entry.z, 40) >= 2, "explore spawn: >= 2 warm lights")
		explore.destroy()
		local town = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.town", 1776)
		root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
		entry = anchor(town.layout, "entry")
		assert(lightsNear(root, entry.x, entry.z, 40) >= 2, "town spawn: >= 2 warm lights")
		assert(lightsNear(root, 0, 200, 420) >= 12, "town core: >= 12 warm lights")
		town.destroy()
	end,
	["the town layout places houses, market, workshop, quest board and docks off the roads"] = function()
		local layout
		for _, value in Content.layouts do
			layout = if value.id == "rw.town" then value else layout
		end
		local plan = Dressing.plan(layout, Terrain.columns(layout, 1776, 32), Terrain)
		local kinds: { [string]: number } = {}
		for _, building in plan.buildings do
			kinds[building.kind] = (kinds[building.kind] or 0) + 1
			assert(
				not Terrain.protected(layout, building.x, building.z, 6),
				building.id .. " sits on a road or node approach"
			)
		end
		assert((kinds.house or 0) >= 8, "town has >= 8 houses")
		for _, kind in { "market", "workshop", "quest-board", "dock" } do
			assert((kinds[kind] or 0) >= 1, "town has a " .. kind)
		end
		assert(#plan.buildings >= 16, "town building count " .. #plan.buildings)
		-- Every building renders as composed parts when no mesh row loads (headless fixture).
		local engine = Engine.new()
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.town", 1776)
		local root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
		for _, building in plan.buildings do
			local pieces = 0
			for _, item in root:GetChildren() do
				if string.sub(item.Name, 1, #building.id + 1) == building.id .. "." then
					pieces += 1
				end
			end
			assert(pieces >= 4, building.id .. " renders " .. pieces .. " parts")
		end
		world.destroy()
	end,
	["town ground has no square river pits"] = function()
		local engine = Engine.new(nil, true)
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.town", 1776)
		local workspace = engine.game:GetService("Workspace")
		local pits = 0
		for _, column in Terrain.columns(world.layout, 1776, 32) do
			local river = math.abs(column.x - math.sin(column.z / 75 + 1776) * 42)
			if
				column.top > 0
				and river < column.cell * 0.55
				and not Terrain.protected(world.layout, column.x, column.z, column.cell)
			then
				local hit =
					workspace:Raycast(roblox.Vector3.new(column.x, 64, column.z), roblox.Vector3.new(0, -128, 0))
				if hit and hit.Position.Y < 0 then
					pits += 1
				end
			end
		end
		assert(pits == 0, pits .. " square river pits in the town")
		world.destroy()
	end,
	["every plot shows a fenced border along all four sides and a claim sign"] = function()
		local engine = Engine.new()
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.town", 1776)
		local root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
		local folder = root:FindFirstChild("ForgeTownPlots")
		for _, plot in world.townLayout.plots do
			local model = assert(folder:FindFirstChild(plot.id), plot.id)
			local sides = { n = 0, s = 0, w = 0, e = 0 }
			local posts, sign = 0, false
			for _, item in model:GetDescendants() do
				if item.ClassName ~= "Part" then
					continue
				end
				local p, size = item.Position, item.Size
				if string.find(item.Name, "border.", 1, true) then
					local long = math.max(size.X, size.Z)
					if math.abs(p.Z - plot.min.z) < 1.5 then
						sides.n += long
					elseif math.abs(p.Z - plot.max.z) < 1.5 then
						sides.s += long
					elseif math.abs(p.X - plot.min.x) < 1.5 then
						sides.w += long
					elseif math.abs(p.X - plot.max.x) < 1.5 then
						sides.e += long
					end
					assert(not item.CanCollide, plot.id .. " border never blocks the build cells")
				elseif string.find(item.Name, "post.", 1, true) then
					posts += 1
				elseif string.find(item.Name, "sign.", 1, true) then
					sign = true
				end
			end
			for side, length in sides do
				-- Two rails per side; one 12-stud entrance gap per plot is allowed.
				assert(length >= 2 * (64 - 12), plot.id .. " " .. side .. " border " .. length)
			end
			assert(posts >= 4 and sign, plot.id .. " corner posts and claim sign")
		end
		world.destroy()
	end,
	["opening stakes, beacon and boat are multi-part models that take their mesh rows"] = function()
		local function census(engine: any): any
			local folder =
				engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld"):FindFirstChild("ForgeOpening")
			local result = { stakes = {}, beacon = 0, boat = 0 }
			for index = 1, 3 do
				local stake = assert(folder:FindFirstChild("OpeningStake" .. index), "stake " .. index)
				local parts = 1
				for _, item in stake:GetDescendants() do
					parts += if item.ClassName == "Part" or item.ClassName == "WedgePart" then 1 else 0
				end
				result.stakes[index] = parts
			end
			for key, name in { beacon = "OpeningBeacon", boat = "OpeningGannet" } do
				local model = assert(folder:FindFirstChild(name), name)
				for _, item in model:GetDescendants() do
					result[key] += if item.ClassName == "Part" or item.ClassName == "WedgePart" then 1 else 0
				end
				result[key .. "Model"] = model
			end
			return result
		end
		local engine = Engine.new()
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.onboarding", 1776)
		local plain = census(engine)
		for index, parts in plain.stakes do
			assert(parts >= 3, "stake " .. index .. " is a peg with rope, not one block")
		end
		assert(plain.beacon >= 8, "composed beacon tower: " .. plain.beacon .. " parts")
		assert(plain.boat >= 8, "composed boat: " .. plain.boat .. " parts")
		world.destroy()
		-- With the B3 town kit loaded the set pieces carry the mesh rows and hide the blocks.
		local meshed = Engine.new()
		local rows = {}
		for _, key in { "town.beacon-tower", "town.boat" } do
			local model = meshed.newInstance("Model")
			model.Name = key
			local body = meshed.newInstance("MeshPart")
			body.Name, body.Size = key, roblox.Vector3.new(6, 6, 6)
			body.Position, body.CFrame = roblox.Vector3.new(0, 3, 0), roblox.CFrame.new(0, 3, 0)
			body.Parent = model
			rows[key] = model
		end
		meshed.meshes.setTemplates(rows)
		world = meshed.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.onboarding", 1776)
		local dressed = census(meshed)
		for key, row in { beacon = "town.beacon-tower", boat = "town.boat" } do
			local model = dressed[key .. "Model"]
			local visual = model:FindFirstChild("ForgeMeshVisual", true)
			assert(visual and visual:GetAttribute("ForgeMeshRow") == row, key .. " takes mesh row " .. row)
			for _, item in model:GetDescendants() do
				if item.ClassName == "Part" then
					assert(item.Transparency == 1, key .. " block " .. item.Name .. " hidden behind the mesh")
				end
			end
		end
		world.destroy()
		meshed.meshes.setTemplates(nil)
	end,
}
