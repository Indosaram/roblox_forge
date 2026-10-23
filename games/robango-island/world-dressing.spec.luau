--!strict
local Content = require("./src/shared/SurvivalContent")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Dressing = require("./src/server/WorldDressing")
local HomeWorld = require("./src/server/HomeWorld")
local HomeContent = require("../../core/domain/home/HomeContent")
local Home = require("../../core/domain/home/HomeState")
local serde = require("@lune/serde")

local function validate(layout: any, plan: any)
	assert(#plan.parts <= 768 and #plan.props <= 96, "world art budget")
	for _, prop in plan.props do
		assert(not Terrain.protected(layout, prop.position.x, prop.position.z, 16), "prop blocks navigation")
	end
end

return {
	["every buildable structure has a volumetric kit and campfire emits fire and light"] = function()
		local engine = require("../../cli/forge/fixtures/production-worlds/engine").new()
		for _, definition in Content.structures do
			local model = engine.dressing.structure(nil, definition, 4)
			local count, height, flame, light = 0, 0, false, false
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") then
					count += 1
					height = math.max(height, part.CFrame.Position.Y + part.Size.Y / 2)
				elseif part:IsA("Fire") then
					flame = part.Size <= 3 and part.Heat <= 5
				elseif part:IsA("PointLight") then
					light = part.Range <= 12 and part.Brightness <= 1
				end
			end
			assert(count > 1 and height > 0.5, definition.id .. " must not be a flat slab")
			if definition.id == "campfire" then
				assert(count > 8 and flame and light, "stone ring logs fire and light")
			end
		end
	end,
	["art kits have pitched thatch rounded foliage and grounded supports within budget"] = function()
		local palette = Dressing.palette({ biomes = { "grassland" } })
		for _, kind in { "shelter", "bush", "fern", "rock", "workbench", "campfire" } do
			local parts = {}
			Dressing.kit(parts, kind, { x = 0, y = 0, z = 0 }, kind, palette)
			assert(#parts > 0 and #parts <= 90, "kit part budget: " .. kind)
			local roof, lash, ring = 0, 0, 0
			for _, p in parts do
				if string.find(p.id, ".roof", 1, true) then
					roof += 1
					assert(p.shape == "Wedge" and math.abs(p.roll) >= 45, "steep layered thatch")
				elseif string.find(p.id, ".lash", 1, true) then
					lash += 1
				elseif string.find(p.id, ".ring", 1, true) then
					ring += 1
				end
				if kind == "bush" then
					assert(p.shape == "Ball", "rounded bush lobes")
				elseif kind == "fern" then
					assert(p.shape == "Wedge" and p.size.x <= 0.35, "thin fan fronds")
				elseif kind == "rock" then
					assert((p.material == "Slate" or p.material == "Rock") and p.yaw ~= 0, "irregular stone cluster")
				end
				if
					string.find(p.id, ".post", 1, true)
					or string.find(p.id, ".leg", 1, true)
					or string.find(p.id, ".skirt", 1, true)
					or string.find(p.id, ".ring", 1, true)
					or kind == "rock"
					or kind == "bush"
					or kind == "fern"
				then
					local roll = math.rad(p.roll or 0)
					local height = math.abs(math.sin(roll)) * p.size.x + math.abs(math.cos(roll)) * p.size.y
					assert(p.position.y - height / 2 <= 0.5, "ground contact: " .. p.id)
				end
			end
			if kind == "shelter" then
				assert(roof == 40 and lash == 12, "complete thatched frame")
				for _, p in parts do
					local roll = math.rad(p.roll or 0)
					assert(
						p.position.y + (math.abs(math.sin(roll)) * p.size.x + math.abs(math.cos(roll)) * p.size.y) / 2
							<= 15,
						"shelter under three humanoid heights"
					)
				end
			elseif kind == "workbench" then
				assert(lash == 6, "lashed workbench logs")
			elseif kind == "campfire" then
				assert(ring == 8, "stone fire ring")
			end
		end
	end,
	["kit roots ground independently and canopy clusters never stack"] = function()
		for _, layout in Content.layouts :: any do
			local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
			for index, prop in plan.props do
				for previous = 1, index - 1 do
					local other = plan.props[previous].position
					assert(
						(prop.position.x - other.x) ^ 2 + (prop.position.z - other.z) ^ 2 >= 22 ^ 2,
						"canopy spacing"
					)
				end
			end
			for _, part in plan.parts do
				if string.find(part.id, "biome.", 1, true) or string.find(part.id, "understory.", 1, true) then
					assert(part.ground and part.ground.y <= part.position.y + part.size.y, "kit requires terrain root")
				end
				if layout.art and part.id == layout.art.landmark.id .. ".crown.trunk1" then
					assert(
						part.ground.x > layout.art.landmark.position.x + layout.art.landmark.size.x / 2,
						"tree must stand beside boulder"
					)
				end
			end
		end
	end,
	["palm trunk segments chain and carry the crown in every role"] = function()
		-- Cylinder axis is local X after CFrame.Angles(0, yaw, roll).
		local function axis(part: any, sign: number): any
			local r, y, h = math.rad(part.roll or 0), math.rad(part.yaw or 0), sign * part.size.x / 2
			local x = math.cos(r) * h
			return {
				x = part.position.x + x * math.cos(y),
				y = part.position.y + math.sin(r) * h,
				z = part.position.z - x * math.sin(y),
			}
		end
		local function gap(a: any, b: any): number
			return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
		end
		local palms, coastal = 0, false
		for _, layout in Content.layouts :: any do
			local byId, plan = {}, Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
			for _, part in plan.parts do
				byId[part.id] = part
			end
			for _, part in plan.parts do
				local kit = string.match(part.id, "^(.+)%.trunk4$")
				if kit and byId[kit .. ".frond0.1-1"] then
					palms += 1
					coastal = coastal or layout.id == "rw.a1.s1"
					for i = 2, 4 do
						local d = gap(axis(byId[kit .. ".trunk" .. (i - 1)], 1), axis(byId[kit .. ".trunk" .. i], -1))
						assert(d <= 0.1, "palm trunk gap " .. kit .. " " .. d)
					end
					local crown = byId[kit .. ".crown"]
					local base = { x = crown.position.x, y = crown.position.y - crown.size.y / 2, z = crown.position.z }
					assert(gap(base, axis(part, 1)) <= 0.3, "floating palm crown " .. kit)
				end
			end
		end
		assert(palms > 0 and coastal, "coastal grassland palms use the frond kit")
	end,
	["authored landmarks reach the production dressing plan"] = function()
		local count = 0
		for _, layout in Content.layouts :: any do
			if layout.art then
				count += 1
				local landmark = layout.art.landmark
				local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
				local found = false
				for _, part in plan.parts do
					if part.id == landmark.id .. ".base" then
						found = true
						assert(
							part.position.x == landmark.position.x and part.position.z == landmark.position.z,
							"landmark position changed twice"
						)
						assert(
							part.size.x == landmark.size.x and part.size.z == landmark.size.z,
							"landmark footprint changed"
						)
					end
				end
				assert(found, "authored landmark omitted: " .. layout.id)
			end
		end
		assert(count == 20, "all authored expedition landmarks must ship")
	end,
	["volcano has luminous flows ash and hot spring effects"] = function()
		local lava, ash, steam = false, false, false
		for _, layout in Content.layouts :: any do
			local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
			for _, part in plan.parts do
				lava = lava or (part.effect == "lava" and part.material == "Neon")
				ash = ash or part.effect == "ash"
				steam = steam or part.effect == "steam"
			end
		end
		assert(lava and ash and steam, "volcanic effects missing")
	end,
	["home camp includes crops storage fire and path without repeated awnings"] = function()
		local rules = HomeContent.rules(Content)
		local parts = HomeWorld.plan(Content, Home.new("owner", rules, 79), rules)
		local ids = {}
		for _, part in parts do
			ids[part.id] = true
			assert(not string.find(part.id, ".awning", 1, true), "duplicated starter shelters")
		end
		assert(
			ids["home.fire.embers"] and ids["home.farm.soil"] and ids["home.storage.basket0"] and ids["home.path"],
			"home camp components missing"
		)
	end,
	["world dressing is deterministic budgeted and preserves catalog clearance for every role"] = function()
		for _, layout in Content.layouts :: any do
			local columns = Terrain.columns(layout, 79, 32)
			local plan = Dressing.plan(layout, columns, Terrain)
			validate(layout, plan)
			assert(
				serde.encode("json", plan)
					== serde.encode("json", Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)),
				layout.id
			)
			local wet, dry = false, false
			for _, column in columns do
				wet = wet or column.top < -4
				dry = dry or column.top > 0
			end
			if string.match(layout.id, "^rw%.a%d+%.s%d+$") then
				-- Organic coasts leave offshore cells to the sea fill instead of emitting wet
				-- columns, so the shore shows as authored-bounds cells with no land column.
				local full = 0
				for _ = layout.bounds.min.x + 16, layout.bounds.max.x - 16, 32 do
					for _ = layout.bounds.min.z + 16, layout.bounds.max.z - 16, 32 do
						full += 1
					end
				end
				local inside = 0
				for _, column in columns do
					if
						column.x > layout.bounds.min.x
						and column.x < layout.bounds.max.x
						and column.z > layout.bounds.min.z
						and column.z < layout.bounds.max.z
					then
						inside += 1
					end
				end
				wet = wet or inside < full
				assert(wet and dry, "archipelago must have shore and dry land: " .. layout.id)
			end
		end
	end,
	["world dressing negative mutation rejects props inside objective and over budget"] = function()
		local layout: any = (Content.layouts :: any)[1]
		local p = layout.anchors[1].position
		local plan: any = { parts = {}, props = { { position = p } } }
		assert(not pcall(validate, layout, plan), "clearance mutation must fail")
		plan.props = {}
		for i = 1, 769 do
			plan.parts[i] = {}
		end
		assert(not pcall(validate, layout, plan), "part budget mutation must fail")
		assert(not pcall(Terrain.columns, layout, 79, 0), "zero cell must fail instead of looping")
	end,
	["home art expands fenced shelter without replacing durable land"] = function()
		local rules = HomeContent.rules(Content)
		local home = Home.new("owner", rules, 79)
		for _, rank in { 1, 5 } do
			home.landRank = rank
			local parts = HomeWorld.plan(Content, home, rules)
			local shelter, fence = false, false
			for _, part in parts do
				shelter = shelter or part.id == "home.shelter.bedroll"
				fence = fence or string.find(part.id, "home.fence.", 1, true) ~= nil
			end
			assert(shelter and fence and parts[1].size.x == rules.landSizes[rank], "home visual rank projection")
			for _, part in parts do
				if string.find(part.id, "home.tree", 1, true) then
					assert(math.sqrt(part.position.x ^ 2 + part.position.z ^ 2) >= 24, "tall prop inside camp radius")
				end
			end
		end
	end,
}
