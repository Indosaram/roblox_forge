--!strict
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local HomeContent = require("../../core/domain/home/HomeContent")
local Home = require("../../core/domain/home/HomeState")

return {
	["onboarding station anchors sit above terrain rather than inside it"] = function()
		local engine = Engine.new()
		local workspace = engine.game:GetService("Workspace")
		local original = workspace.Raycast
		workspace.Raycast = function(self, origin, direction, params)
			local hit = original(self, origin, direction, params)
			if hit then
				hit.Position = require("@lune/roblox").Vector3.new(origin.X, 8, origin.Z)
			end
			return hit
		end
		engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.onboarding", 79)
		local count = 0
		for _, part in engine.game:GetService("CollectionService"):GetTagged("ForgeSurvivalStation") do
			assert(part.Position.Y - part.Size.Y / 2 >= 8, "station is buried")
			count += 1
		end
		assert(count >= 2, "onboarding workbench and campfire")
	end,
	["a missing terrain ray never aborts a live role boot"] = function()
		local engine = Engine.new()
		engine.game:GetService("Workspace").Raycast = function()
			return nil
		end
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.a1.s1", 1776)
		world.bind({} :: any)
		assert(world.roleSource.worldRevision == "rw.a1.s1:1776", "boot continues after missing support")
	end,
	["every authored wildlife spawn in every layout has a dry terrain column"] = function()
		local terrain = require("../../core/domain/island/ArchipelagoTerrain")
		local document = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
		for _, layout in document.layouts do
			local cell = if layout.id == "rw.onboarding" then 16 else 32
			local columns = terrain.columns(layout, 1776, cell)
			for _, spawn in layout.spawns do
				local supported = false
				for _, column in columns do
					if
						math.abs(column.x - spawn.position.x) <= cell / 2
						and math.abs(column.z - spawn.position.z) <= cell / 2
					then
						supported = supported or column.top >= 0
					end
				end
				assert(supported, layout.id .. ":" .. spawn.id .. " has no dry terrain")
			end
		end
	end,
	["every onboarding spawn has an immediately reachable gather prompt"] = function()
		local roblox = require("@lune/roblox")
		for _, preview in { true, false } do
			local engine = Engine.new()
			if preview then
				engine.preview(Content, Source, nil, nil, "onboarding", true)
			else
				engine.role.build(Content, Source, Policy, function()
					return 0
				end, "rw.onboarding", 79)
			end
			engine.move("1", { x = 0, y = 0, z = 0 })
			local client = engine.gatherClient("1", function()
				return { ok = true }
			end)
			local workspace = engine.game:GetService("Workspace")
			for _, spawn in workspace:GetDescendants() do
				if spawn:IsA("SpawnLocation") then
					local reachable = false
					for _, prompt in workspace:GetDescendants() do
						if prompt:IsA("ProximityPrompt") and prompt.Name == "ForgeGather" then
							reachable = reachable
								or (prompt.Parent.Position - (spawn.Position + roblox.Vector3.new(0, 4, 0))).Magnitude
									<= prompt.MaxActivationDistance
						end
					end
					assert(reachable, "onboarding spawn has no gather prompt in activation range")
				end
			end
			client.destroy()
		end
	end,
	["production onboarding creatures spawn with their lowest part on terrain"] = function()
		local engine = Engine.new()
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.onboarding", 79)
		world.bind({} :: any)
		local count = 0
		for _, model in engine.game:GetService("Workspace"):GetDescendants() do
			if model:IsA("Model") and model:GetAttribute("Species") then
				local lowest = math.huge
				for _, part in model:GetDescendants() do
					if part:IsA("BasePart") then
						local cf, size = part.CFrame, part.Size
						lowest = math.min(
							lowest,
							cf.Position.Y
								- (
										math.abs(cf.RightVector.Y) * size.X
										+ math.abs(cf.UpVector.Y) * size.Y
										+ math.abs(cf.LookVector.Y) * size.Z
									)
									/ 2
						)
					end
				end
				assert(lowest >= -0.001 and lowest <= 0.101, model.Name .. " is not grounded: " .. lowest)
				count += 1
			end
		end
		assert(count >= 8, "all six tutorial species and two arrival grazers")
	end,
	["warehouse prompt approaches keep authority rays and decorative kits unobstructed"] = function()
		local engine = Engine.new()
		local workspace = engine.game:GetService("Workspace")
		local fills = {}
		workspace.Terrain.FillBlock = function(_, frame, size, material)
			table.insert(fills, { position = frame.Position, size = size, material = material.Name })
		end
		engine.preview(Content, Source, nil, nil, "onboarding", true)
		local marker = workspace:FindFirstChild("DevelopmentIsland"):FindFirstChild("Warehouse")
		assert(marker:FindFirstChild("ForgeWarehouse"), "real bootstrap warehouse prompt")
		local target = Source.tribe.warehousePosition
		for _, offset in { { 7, 0 }, { -7, 0 }, { 0, 7 }, { 0, -7 }, { 5, 5 }, { -5, 5 }, { 5, -5 }, { -5, -5 } } do
			local from = { X = marker.Position.X + offset[1], Y = 3.2, Z = marker.Position.Z + offset[2] }
			local to = { X = target.x, Y = target.y, Z = target.z }
			for step = 0, 20 do
				local point, material = {}, "Air"
				for _, axis in { "X", "Y", "Z" } do
					point[axis] = from[axis] + (to[axis] - from[axis]) * step / 20
				end
				for _, fill in fills do
					local overlaps = true
					for _, axis in { "X", "Y", "Z" } do
						if
							fill.position[axis] + fill.size[axis] / 2 <= point[axis]
							or fill.position[axis] - fill.size[axis] / 2 >= point[axis]
						then
							overlaps = false
						end
					end
					if overlaps then
						material = fill.material
					end
				end
				assert(
					material == "Air",
					"warehouse authority ray intersects "
						.. material
						.. " at "
						.. point.X
						.. ","
						.. point.Y
						.. ","
						.. point.Z
				)
			end
		end
		for _, part in workspace:GetDescendants() do
			if
				part:IsA("BasePart")
				and (part.Parent.Name == "IslandScenery" or string.find(part.Name, "WarehouseBaskets", 1, true))
			then
				assert(part.CanCollide == false, part.Name .. " decorative kit blocks reach")
			end
		end
	end,
	["live role bootstrap receives the same structure templates as Studio preview"] = function()
		local engine = Engine.new()
		local bootstrap = engine.load("games/robango-island/src/server/SurvivalWorldBootstrap.luau", {
			["./WorldDressing"] = engine.dressing,
		}, { Parent = { RoleWorld = engine.role, HomeWorld = engine.home, BrawlWorld = {} } })
		local world = bootstrap(Content, Source, Policy, function()
			return 0
		end, "home", false)
		assert(
			world.structureKits == engine.game:GetService("ReplicatedStorage"):FindFirstChild("ForgeStructureKits"),
			"live world owns replicated templates"
		)
		for _, definition in Content.structures do
			assert(world.structureKits:FindFirstChild(definition.id), "live kit missing: " .. definition.id)
		end
		world.destroy()
	end,
	["starter camp berry shrub is rounded and storage uses woven stacked baskets"] = function()
		local engine = Engine.new()
		local world = engine.game:GetService("Workspace")
		engine.preview(Content, Source, nil, nil, "onboarding", true)
		local lobes, berries, baskets, weave = 0, 0, 0, 0
		for _, item in world:GetDescendants() do
			if item:IsA("BasePart") then
				if string.find(item.Name, "-lobe", 1, true) then
					lobes += 1
					assert(item.Shape == require("@lune/roblox").Enum.PartType.Ball, "berry lobe must be rounded")
				elseif string.find(item.Name, "-berry", 1, true) then
					berries += 1
				elseif string.find(item.Name, "WarehouseBaskets.basket", 1, true) then
					baskets += 1
				elseif string.find(item.Name, "WarehouseBaskets.weave", 1, true) then
					weave += 1
				end
			end
		end
		assert(lobes >= 2 and berries >= 5, "multi-lobe shrub with visible berries")
		assert(baskets == 2 and weave == 6, "woven two-basket storage stack")
	end,
	["SurvivalWorldBootstrap clears every gather reach ray after overlapping approach paths"] = function()
		local engine = Engine.new()
		local fills = {}
		local workspace = engine.game:GetService("Workspace")
		workspace.Terrain.FillBlock = function(_, frame, size, material)
			table.insert(fills, { position = frame.Position, size = size, material = material.Name })
		end
		engine.preview(Content, Source, nil, nil, "onboarding", true)
		for _, part in workspace:FindFirstChild("IslandScenery"):GetChildren() do
			if part:IsA("BasePart") then
				assert(part.CanQuery == false and part.CanCollide == false, part.Name .. " dressing blocks reach")
			end
		end
		-- Resolve the last write to each four-stud voxel along a real root-to-node ray.
		-- A partial Ground fill still occupies that voxel, even when its nominal top
		-- is below the ray. This is the mechanism the native gather scenario omitted.
		for _, node in Source.nodes do
			for _, offset in { { 5, 0 }, { -5, 0 }, { 0, 5 }, { 0, -5 } } do
				for step = 0, 10 do
					local t = step / 10
					local p = node.position
					local point = {
						X = p.x + offset[1] * (1 - t),
						Y = p.y + 2 * (1 - t),
						Z = p.z + offset[2] * (1 - t),
					}
					local material = "Air"
					for _, fill in fills do
						local overlaps = true
						for _, axis in { "X", "Y", "Z" } do
							local low = math.floor((point[axis] - (if axis == "Y" then 2 else 0)) / 4) * 4
							if
								fill.position[axis] + fill.size[axis] / 2 <= low
								or fill.position[axis] - fill.size[axis] / 2 >= low + 4
							then
								overlaps = false
							end
						end
						if overlaps then
							material = fill.material
						end
					end
					assert(material == "Air", node.id .. " gather ray intersects " .. material)
				end
			end
		end
	end,
	["Terrain decoration is authored in the place and forbidden at runtime"] = function()
		local project = serde.decode("json", fs.readFile("games/robango-island/default.project.json"))
		assert(project.tree.Workspace.Terrain["$properties"].Decoration == true, "place enables grass decoration")
		local engine = Engine.new()
		local terrain = engine.game:GetService("Workspace").Terrain
		for _, property in { "Decoration", "GrassLength", "UnknownProperty" } do
			local ok = pcall(function()
				terrain[property] = true
			end)
			assert(not ok, property .. " must reject runtime writes")
		end
		for _, property in { "WaterTransparency", "WaterWaveSize", "WaterWaveSpeed", "WaterReflectance" } do
			terrain[property] = 0.2
			terrain[property] = 0.4
			assert(terrain[property] == 0.4, "water settings remain script-writable")
		end
	end,
	["home renders Terrain coast and grass instead of visible square ground"] = function()
		local engine = Engine.new()
		local workspace = engine.game:GetService("Workspace")
		local grass, sand, dirt = 0, 0, 0
		workspace.Terrain.FillBlock = function(_, _frame, _size, material)
			if material.Name == "Grass" then
				grass += 1
			elseif material.Name == "Sand" then
				sand += 1
			elseif material.Name == "Ground" then
				dirt += 1
			end
		end
		local source: any = table.clone(Source)
		source.seed, source.renderRole = 79, engine.role.build
		local world = engine.home.live(Content, source, Policy, function()
			return 0
		end)
		local rules = HomeContent.rules(Content)
		world.publishHome(Home.new("owner", rules, 79), rules)
		assert(grass > 0 and sand > 0 and dirt > 0, "Terrain grass coast and dirt trail")
		for _, p in engine.parts do
			if p.Name == "home-land" or p.Name == "home.path" then
				assert(p.Transparency == 1 and p.CanCollide == false, "hidden ground capability")
			end
			if string.find(p.Name, "home.shelter.post", 1, true) then
				assert(math.abs(p.CFrame.Position.Y - p.Size.X / 2) < 0.5, "post bottom follows terrain ray")
			end
		end
		world.destroy()
	end,
	["production home projects catalog nodes and tier-sized durable land"] = function()
		local engine = Engine.new()
		local source: any = table.clone(Source)
		source.seed, source.renderRole = 79, engine.role.build
		local world = engine.home.live(Content, source, Policy, function()
			return 0
		end)
		local rules = HomeContent.rules(Content)
		assert(
			rules.baseSlots == 20
				and rules.storageGrants.routeGuildPatron == 10
				and rules.storageGrants.wideWarehouse == 10
				and rules.storageGrants.routeGuildMonthly == 5,
			"home entitlements grant 20/30/40/45 without changing bag policy"
		)
		local state = Home.new("11734795308", rules, 79)
		world.publishHome(state, rules)
		local land: any = nil
		for _, part in engine.parts do
			if part.Name == "home-land" and not part.destroyed then
				land = part
			end
		end
		assert(land and land.Size.X == 64 and land.Size.Z == 64, "fresh land is 64 square")
		for _, node in world.roleSource.nodes do
			assert(math.abs(node.position.x) <= 32 and math.abs(node.position.z) <= 32, "home nodes fit starting land")
		end
		state.landRank = 5
		world.publishHome(state, rules)
		assert(land.Size.X == 224 and land.Size.Z == 224, "same durable land part expands to endpoint")
		state.structures.fire = { kind = "campfire", position = { x = 8, y = 0, z = 0 }, owner = state.owner }
		world.publishHome(state, rules)
		engine.move(state.owner, { x = 8, y = 0, z = 0 })
		local station: any = nil
		for _, part in engine.parts do
			if part.Name == "fire" and not part.destroyed then
				station = part
			end
		end
		local handle = station:GetAttribute("ForgeStationId")
		assert(
			world.services.survivalSpatial.campfire(state.owner, handle).reachable,
			"durable fire is a reachable station"
		)
		world.publishHome(state, rules)
		state.structures.fire = nil
		world.publishHome(state, rules)
		assert(
			world.services.survivalSpatial.campfire(state.owner, handle) == nil,
			"recovered fire loses station capability"
		)
		state.structures.fire = { kind = "campfire", position = { x = 8, y = 0, z = 0 }, owner = state.owner }
		world.publishHome(state, rules)
		assert(
			world.services.survivalSpatial.campfire(state.owner, handle).reachable,
			"replaced fire reuses stable handle safely"
		)
		world.destroy()
	end,
	["production archipelago derives rendered layout and nodes from persisted route"] = function()
		local engine = Engine.new()
		local source: any = table.clone(Source)
		source.seed, source.renderRole = 79, engine.role.build
		source.expedition = { status = "active", templateId = "rw.a1", stage = 1, seed = 79 }
		local world = engine.archipelago.live(Content, source, Policy, function()
			return 0
		end)
		assert(world.layout.id == "rw.a1.s1", "persisted route picks first island")
		local found = false
		for _, node in world.roleSource.nodes do
			found = found or node.id == "rw.a1.s1.material.wood"
		end
		assert(found and next(world.surveyMarkers) ~= nil, "real gather and spatial survey bindings exist")
		world.destroy()
	end,
}
