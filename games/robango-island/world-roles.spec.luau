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
	["dock authority does not raycast into its own collidable platform"] = function()
		local engine = Engine.new(true)
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.a1.s1", 1776)
		world.bind({} :: any)
		local traveled = false
		world.travel = function()
			traveled = true
			return false, "mission_gate"
		end
		local dock = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld"):FindFirstChild("entry")
		local p = dock.Position
		engine.move("1", { x = p.X + 4, y = p.Y + 3, z = p.Z })
		local shown: any = nil
		dock:FindFirstChild("ForgeDock").Triggered:Fire({
			UserId = 1,
			SetAttribute = function(_self, key, value)
				shown = if key == "ForgeTravelResult" then value else shown
			end,
		})
		assert(traveled, "dock must not block its own travel authority ray")
		assert(type(shown) == "string" and string.match(shown, "^mission_gate|"), "dock publishes the server result")
		world.destroy()
	end,
	["every live layout grounds resource nodes and keeps standing reach rays clear"] = function()
		local roblox = require("@lune/roblox")
		local terrain = require("../../core/domain/island/ArchipelagoTerrain")
		local total, interactions = 0, 0
		for _, layout in Content.layouts do
			local engine = Engine.new(nil, true)
			local workspace = engine.game:GetService("Workspace")
			local world = engine.role.build(Content, Source, Policy, function()
				return 0
			end, layout.id, 1776)
			if layout.id == "rw.home" then
				local rules = HomeContent.rules(Content)
				world.renderHome(engine.home.plan(Content, Home.new("owner", rules, 1776), rules))
			end
			for _, node in world.roleSource.nodes do
				local target = workspace:FindFirstChild("ForgeRoleWorld"):FindFirstChild(node.id)
				local p = target.Position
				local hit = workspace:Raycast(
					p + roblox.Vector3.new(0, 64, 0),
					roblox.Vector3.new(0, -128, 0),
					{ IgnoreWater = true }
				)
				assert(hit, layout.id .. ":" .. node.id .. " lacks terrain")
				assert(p.Y - target.Size.Y / 2 >= hit.Position.Y, node.id .. " is buried")
				assert(node.position.y == p.Y, node.id .. " authority differs from prompt anchor")
				for _, offset in { { 5, 0 }, { -5, 0 }, { 0, 5 }, { 0, -5 } } do
					local x, z = p.X + offset[1], p.Z + offset[2]
					local support = workspace:Raycast(
						roblox.Vector3.new(x, 512, z),
						roblox.Vector3.new(0, -1024, 0),
						{ IgnoreWater = true }
					)
					if support then
						local from = roblox.Vector3.new(x, support.Position.Y + 3.2, z)
						assert(
							not workspace:Raycast(from, p - from, { IgnoreWater = true }),
							node.id .. " terrain blocks standing reach"
						)
					end
				end
				total += 1
			end
			if string.match(layout.id, "^rw%.a%d+%.s%d+$") then
				local at = workspace:FindFirstChild("ForgeRoleWorld"):FindFirstChild("SurvivalSpawn").Position
				local nearest = math.huge
				for _, node in world.roleSource.nodes do
					nearest = math.min(nearest, math.sqrt((node.position.x - at.X) ^ 2 + (node.position.z - at.Z) ^ 2))
				end
				assert(nearest <= 40, layout.id .. " spawn is " .. nearest .. " studs from nearest node")
			end
			world.bind({} :: any)
			for _, target in workspace:FindFirstChild("ForgeRoleWorld"):GetChildren() do
				local prompt = target:FindFirstChild("ForgeDock")
				if not prompt and world.surveyMarkers[target.Name] then
					prompt = target:FindFirstChildOfClass("ProximityPrompt")
				end
				if not prompt and target:GetAttribute("ForgeHarborFacility") then
					prompt = target:FindFirstChildOfClass("ProximityPrompt")
				end
				if not prompt then
					continue
				end
				local p = target.Position
				local support = workspace:Raycast(
					p + roblox.Vector3.new(0, 64, 0),
					roblox.Vector3.new(0, -128, 0),
					{ IgnoreWater = true }
				)
				assert(
					support and p.Y - target.Size.Y / 2 >= support.Position.Y,
					layout.id .. ":" .. target.Name .. " interactable buried"
				)
				for _, offset in { { 5, 0 }, { -5, 0 }, { 0, 5 }, { 0, -5 } } do
					local x, z = p.X + offset[1], p.Z + offset[2]
					local ground = workspace:Raycast(
						roblox.Vector3.new(x, 512, z),
						roblox.Vector3.new(0, -1024, 0),
						{ IgnoreWater = true }
					)
					if ground then
						local from = roblox.Vector3.new(x, ground.Position.Y + 3.2, z)
						assert(
							(p - from).Magnitude <= prompt.MaxActivationDistance,
							target.Name .. " prompt out of range"
						)
						assert(
							not workspace:Raycast(from, p - from, { IgnoreWater = true }),
							target.Name .. " prompt terrain obstruction"
						)
					end
				end
				local destination = if prompt.Name == "ForgeDock" then prompt:GetAttribute("ForgeDestination") else nil
				for _, facility in world.harborFacilities or {} do
					if facility.id == target.Name then
						assert(facility.position.y == p.Y, "harbor authority position")
						destination = facility.destination
					end
				end
				if destination then
					local checked, traveled = false, false
					world.services.survivalDeath.reachable = function(_, position)
						assert(
							position.x == p.X
								and position.y == p.Y + (if prompt.Name == "ForgeDock" then 2 else 0)
								and position.z == p.Z,
							target.Name .. " travel authority position"
						)
						checked = true
						return true
					end
					world.travel = function(_, actual)
						assert(actual == destination, "travel destination")
						traveled = true
					end
					prompt.Triggered:Fire({ UserId = 1, SetAttribute = function() end })
					assert(checked and traveled, target.Name .. " prompt failed to travel")
				end
				interactions += 1
			end
			for _, fill in engine.terrainWrites do
				if fill.material == roblox.Enum.Material.Grass or fill.material == roblox.Enum.Material.LeafyGrass then
					for _, node in layout.resourceNodes do
						assert(
							(fill.position.X - node.position.x) ^ 2 + (fill.position.Z - node.position.z) ^ 2 > 24 ^ 2,
							node.id .. " animated grass at node"
						)
					end
					for _, path in layout.paths do
						for index = 2, #path.points do
							assert(
								terrain.distance(
									fill.position.X,
									fill.position.Z,
									path.points[index - 1],
									path.points[index]
								) > path.width / 2 + 24,
								path.id .. " animated grass on approach"
							)
						end
					end
					for _, spawn in layout.spawns do
						assert(
							(fill.position.X - spawn.position.x) ^ 2 + (fill.position.Z - spawn.position.z) ^ 2
								> (spawn.radius + 24) ^ 2,
							spawn.id .. " animated grass at spawn"
						)
					end
				end
			end
			world.destroy()
		end
		assert(total > 100, "all live role nodes covered")
		print("grounded role nodes with unobstructed standing reach: " .. total)
		assert(interactions > 20, "all live role docks and harbor interactions covered")
		print("grounded role docks and harbor interactables: " .. interactions)
	end,
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
	["decorative arrival fauna is a seeded anchored ghost rig the client can pose"] = function()
		local function decor(layoutId: string): { [string]: any }
			local engine = Engine.new()
			engine.role.build(Content, Source, Policy, function()
				return 0
			end, layoutId, 79)
			local found = {}
			for _, model in engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld"):GetChildren() do
				if model:IsA("Model") and model:GetAttribute("Species") then
					found[model.Name] = model
				end
			end
			return found
		end
		for _, layoutId in { "rw.onboarding", "rw.a1.s1" } do
			local first, again = decor(layoutId), decor(layoutId)
			local phases, count = {}, 0
			for name, model in first do
				count += 1
				assert(model:GetAttribute("ForgeDecorFauna") == true, name .. " is tagged for the client graze idle")
				local phase, period = model:GetAttribute("ForgeGrazePhase"), model:GetAttribute("ForgeGrazePeriod")
				assert(type(phase) == "number" and phase >= 0 and phase < 1, name .. " graze phase")
				assert(type(period) == "number" and period >= 6 and period <= 14, name .. " graze period")
				local twin = again[name]
				assert(
					twin:GetAttribute("ForgeGrazePhase") == phase and twin:GetAttribute("ForgeGrazePeriod") == period,
					name .. " phase is deterministic per rig"
				)
				assert(not phases[phase], name .. " shares a phase with another rig")
				phases[phase] = true
				for _, part in model:GetDescendants() do
					if part:IsA("BasePart") then
						assert(
							not part.CanCollide and not part.CanTouch and not part.CanQuery,
							name .. " part is interactive: " .. part.Name
						)
						-- Only the root is anchored: the assembly stays fixed while Motor6D poses move limbs.
						assert(part.Anchored == (part == model.PrimaryPart), name .. " anchoring: " .. part.Name)
					end
				end
			end
			assert(count >= 1, layoutId .. " has decorative fauna")
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
	["home renders Terrain coast and clear interaction ground instead of visible square ground"] = function()
		local engine = Engine.new()
		local workspace = engine.game:GetService("Workspace")
		local sand, dirt = 0, 0
		workspace.Terrain.FillBlock = function(_, _frame, _size, material)
			if material.Name == "Sand" then
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
		assert(sand > 0 and dirt > 0, "Terrain coast and clear interaction ground")
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
	["station and boundary prompts open modify, technical support and island rank"] = function()
		local function prompts(layoutId: string, home: boolean?): { [string]: any }
			local engine = Engine.new()
			local world = engine.role.build(Content, Source, Policy, function()
				return 0
			end, layoutId, 1776)
			if home then
				local rules = HomeContent.rules(Content)
				local state = Home.new("owner", rules, 1776)
				state.structures.bench2 = { kind = "workbench-t2", position = { x = 8, y = 0, z = 8 }, owner = "owner" }
				world.renderHome(engine.home.plan(Content, state, rules))
			end
			local out = {}
			for _, part in engine.parts do
				for _, child in part:GetChildren() do
					if child.ClassName == "ProximityPrompt" and child:GetAttribute("ForgeStationPanel") then
						out[part.Name] = child
					end
				end
			end
			world.destroy()
			return out
		end
		local harbor = prompts("rw.harbor")
		assert(
			harbor["station.signal-relay.t1"]
				and harbor["station.signal-relay.t1"]:GetAttribute("ForgePanel") == "technical-support",
			"harbor communication station opens technical support"
		)
		local home = prompts("rw.home", true)
		assert(
			home["station.workbench.t2"] and home["station.workbench.t2"]:GetAttribute("ForgePanel") == "modify",
			"home tier-2 workbench opens modify"
		)
		assert(home.bench2 and home.bench2:GetAttribute("ForgePanel") == "modify", "placed tier-2 bench opens modify")
		assert(not home["station.workbench.t1"], "a tier-1 workbench has no modify prompt")
		local island = prompts("rw.a1.s1")
		local marker = island.IslandBoundary
		assert(marker and marker:GetAttribute("ForgePanel") == "island-rank", "boundary marker opens island rank")
		local at, low, high =
			marker.Parent.Position,
			marker.Parent:GetAttribute("ForgeCellMin"),
			marker.Parent:GetAttribute("ForgeCellMax")
		assert(at.X >= low.X and at.X <= high.X and at.Z >= low.Z and at.Z <= high.Z, "marker inside its cell bounds")
		assert(marker.Parent:GetAttribute("ForgeCell") == "rw.a1.s1", "marker names its cell")
	end,
	["home world exposes station.workbench.t2 and a placed tier-2 bench serves the workbench kind"] = function()
		local engine = Engine.new()
		local source: any = table.clone(Source)
		source.seed, source.renderRole = 79, engine.role.build
		local world = engine.home.live(Content, source, Policy, function()
			return 0
		end)
		local rules = HomeContent.rules(Content)
		local state = Home.new("11734795308", rules, 79)
		state.structures.bench2 = { kind = "workbench-t2", position = { x = 8, y = 0, z = 8 }, owner = state.owner }
		world.publishHome(state, rules)
		local bench: any = nil
		for _, part in engine.parts do
			if part.Name == "bench2" and not part.destroyed then
				bench = part
			end
		end
		assert(bench and bench:GetAttribute("ForgeStationKind") == "workbench", "serves the workbench kind")
		local fixed = world.services.survivalSpatial.station(state.owner, "station.workbench.t2")
		assert(fixed and fixed.kind == "workbench", "home world registers station.workbench.t2")
		world.destroy()
	end,
	["every archipelago island puts its first survey target on land near the spawn"] = function()
		local roblox = require("@lune/roblox")
		local checked = 0
		for _, layout in Content.layouts do
			if not string.match(layout.id, "^rw%.a%d+%.s%d+$") then
				continue
			end
			local engine = Engine.new(nil, true)
			local workspace = engine.game:GetService("Workspace")
			local world = engine.role.build(Content, Source, Policy, function()
				return 0
			end, layout.id, 1776)
			local target = require("../../core/domain/island/ArchipelagoTerrain").survey(layout, 1)
			for _, stage in Content.stages do
				for _, objective in if stage.layout == layout.id then stage.objectives else {} do
					if objective.action == "survey" then
						target = world.surveyMarkers[objective.id .. ".1"].position
					end
				end
			end
			local at = workspace:FindFirstChild("ForgeRoleWorld"):FindFirstChild("SurvivalSpawn").Position
			local d = math.sqrt((target.x - at.X) ^ 2 + (target.z - at.Z) ^ 2)
			assert(d >= 40 and d <= 70, layout.id .. " first survey is " .. d .. " studs from spawn")
			local ground = workspace:Raycast(
				roblox.Vector3.new(target.x, 512, target.z),
				roblox.Vector3.new(0, -1024, 0),
				{ IgnoreWater = true }
			)
			assert(ground and ground.Position.Y >= 1, layout.id .. " first survey is not on land")
			checked += 1
			world.destroy()
		end
		assert(checked == 20, "all 20 archipelago islands checked")
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
