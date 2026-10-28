--!strict
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local HomeContent = require("../../core/domain/home/HomeContent")
local Home = require("../../core/domain/home/HomeState")
require("./PackText.fixture") -- installs the strings.csv lookup that ExtensionPanels.travelText reads

return {
	["every role is reachable from onboarding through in-game travel and gates show their refusal"] = function()
		local Topology = require("../../core/domain/island/Topology")
		local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
		local Expedition = require("../../genres/survival-coop/module/ExpeditionExtension")
		local function exits(role: string): { [string]: boolean }
			local found = {}
			Expedition.new({
				content = Content,
				now = function()
					return 0
				end,
				facts = function()
					return { level = 60, developmentRank = 9, instabilityAccess = 9 }
				end,
				onExpedition = function()
					return false
				end,
				document = function()
					return nil
				end,
				travel = function(_, destination)
					found[destination] = true
					return { ok = true }
				end,
			}).command("1", Expedition.ACTION, { "depart", "1" }, {}, "client", function()
				return { ok = true }
			end)
			local engine = Engine.new()
			local world = engine.role.build(Content, Source, Policy, function()
				return 0
			end, if role == "archipelago" then "rw.a1.s1" else "rw." .. role, 1776)
			world.bind({} :: any)
			world.services.survivalDeath.reachable = function()
				return true
			end
			-- Topology walk, not reach: travel prompts check world.nearPart (covered with real terrain below).
			world.nearPart = function()
				return true
			end
			world.travel = function(_, destination)
				found[destination] = true
				return false, "studio_no_teleport"
			end
			for _, prompt in engine.game:GetService("Workspace"):GetDescendants() do
				if prompt:IsA("ProximityPrompt") then
					prompt.Triggered:Fire({ UserId = 1, SetAttribute = function() end })
				end
			end
			world.destroy()
			if found["next-island"] then
				found["next-island"], found.archipelago, found.home = nil, true, true
			end
			for destination in found do
				found[destination] = Topology.validateRoleTransition(role, destination, 60) or nil
			end
			return found
		end
		local reached, queue = { onboarding = true }, { "onboarding" }
		while #queue > 0 do
			for destination in exits(table.remove(queue, 1) :: string) do
				if not reached[destination] then
					reached[destination] = true
					table.insert(queue, destination)
				end
			end
		end
		for role in Topology.ROLES do
			assert(reached[role], role .. " is unreachable through live travel")
		end
		local engine = Engine.new()
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.harbor", 1776)
		world.bind({} :: any)
		world.services.survivalDeath.reachable = function()
			return true
		end
		world.nearPart = function()
			return true
		end
		local post =
			engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld"):FindFirstChild("rw.harbor.frontier60")
		for _, case in { { 59, "level_gate" }, { 60, "studio_no_teleport" } } do
			world.travel = function(_, destination)
				local ok, reason = Topology.validateRoleTransition("harbor", destination, case[1])
				return false, if ok then "studio_no_teleport" else reason
			end
			local shown: any = nil
			post:FindFirstChild("ForgeDock").Triggered:Fire({
				UserId = 1,
				SetAttribute = function(_self, key, value)
					shown = if key == "ForgeTravelResult" then value else shown
				end,
			})
			assert(string.match(shown, "^" .. case[2] .. "|"), "frontier60 post publishes " .. case[2])
			for _, locale in { "en-us", "ko-kr" } do
				assert(not string.find(Panels.travelText(locale, case[2]), case[2], 1, true), locale .. " reason text")
			end
		end
		world.destroy()
	end,
	["home has one dock prompt (two at one spot blocked each other's line of sight, p55)"] = function()
		local engine = Engine.new()
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.home", 1776)
		local docks = {}
		for _, prompt in engine.game:GetService("Workspace"):GetDescendants() do
			if prompt:IsA("ProximityPrompt") and prompt.Name == "ForgeDock" then
				table.insert(docks, prompt:GetAttribute("ForgeDestination"))
			end
		end
		world.destroy()
		assert(#docks == 1 and docks[1] == "harbor", "home docks: " .. table.concat(docks, ","))
		local server = fs.readFile("games/robango-island/src/server/RobangoIslandServer.server.luau")
		assert(
			string.find(server, "Topology.validateRoleTransition(worldRole, destination", 1, true),
			"Studio travel applies the live role/level gate before studio_no_teleport"
		)
	end,
	["visitor portal publishes its travel result like a dock (p125)"] = function()
		local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
		local engine = Engine.new()
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.harbor", 1776)
		world.bind({} :: any)
		local near = true
		world.nearPart = function()
			return near
		end
		local portal = engine.game
			:GetService("Workspace")
			:FindFirstChild("ForgeRoleWorld")
			:FindFirstChild("rw.harbor.visitor-portal")
		local prompt: any = nil
		for _, child in portal:GetChildren() do
			prompt = if child:IsA("ProximityPrompt") then child else prompt
		end
		local function trigger(): string?
			local shown: any = nil
			prompt.Triggered:Fire({
				UserId = 1,
				SetAttribute = function(_self, key, value)
					shown = if key == "ForgeTravelResult" then value else shown
				end,
			})
			return if type(shown) == "string" then string.match(shown, "^([^|]+)|") else nil
		end
		local destination: any = nil
		world.travel = function(_, actual)
			destination = actual
			return false, "studio_no_teleport"
		end
		assert(trigger() == "studio_no_teleport", "Studio no-teleport is published")
		assert(destination == "home", "portal travels home")
		world.travel = function()
			return false, "level_gate"
		end
		assert(trigger() == "level_gate", "a refusal is published")
		world.travel = function()
			return true
		end
		assert(trigger() == "travelling", "success is published")
		near = false
		destination = nil
		world.travel = function(_, actual)
			destination = actual
			return true
		end
		assert(trigger() == "portal_unreachable" and destination == nil, "out of reach: refused, no travel")
		for _, locale in { "en-us", "ko-kr" } do
			local text = Panels.travelText(locale, "portal_unreachable")
			assert(not string.find(text, "portal_unreachable", 1, true), locale .. " portal reason text")
		end
		world.destroy()
	end,
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
					-- p123: travel authority is the station reach rule on the prompt's own part (real
					-- terrain, real SurvivalWorld raycast), never a ray to a point inside that part.
					local traveled = false
					world.travel = function(_, actual)
						assert(actual == destination, "travel destination")
						traveled = true
						return false, "studio_no_teleport"
					end
					-- As in Studio the prompt's part is solid to rays that do not exclude it (the headless
					-- terrain engine models terrain only); the nearer of part and terrain hits wins.
					local raycast = workspace.Raycast
					local function solid(origin: any, direction: any, params: any): number?
						if params and params.FilterType == roblox.Enum.RaycastFilterType.Include then
							return nil
						end
						for _, ignored in if params then params.FilterDescendantsInstances or {} else {} do
							if ignored == target or target:IsDescendantOf(ignored) then
								return nil
							end
						end
						local low, high = 0, 1
						for _, axis in { "X", "Y", "Z" } do
							local minimum = target.Position[axis] - target.Size[axis] / 2
							local maximum = target.Position[axis] + target.Size[axis] / 2
							if direction[axis] == 0 then
								if origin[axis] < minimum or origin[axis] > maximum then
									return nil
								end
							else
								local a = (minimum - origin[axis]) / direction[axis]
								local b = (maximum - origin[axis]) / direction[axis]
								low, high = math.max(low, math.min(a, b)), math.min(high, math.max(a, b))
							end
						end
						return if low <= high then low else nil
					end
					local function travels(at: any): boolean
						traveled = false
						engine.move("1", { x = at.X, y = at.Y, z = at.Z })
						workspace.Raycast = function(self, origin, direction, params)
							local hit = raycast(self, origin, direction, params)
							local t = solid(origin, direction, params)
							if t and (not hit or (hit.Position - origin).Magnitude > direction.Magnitude * t) then
								return { Instance = target, Position = origin + direction * t }
							end
							return hit
						end
						prompt.Triggered:Fire({ UserId = 1, SetAttribute = function() end })
						workspace.Raycast = raycast
						return traveled
					end
					local top = p.Y + target.Size.Y / 2
					assert(
						travels(roblox.Vector3.new(p.X, top + 3, p.Z)),
						layout.id .. ":" .. target.Name .. " standing on it travels"
					)
					for _, offset in { { 5, 0 }, { -5, 0 }, { 0, 5 }, { 0, -5 } } do
						local x, z = p.X + offset[1], p.Z + offset[2]
						local ground = workspace:Raycast(
							roblox.Vector3.new(x, 512, z),
							roblox.Vector3.new(0, -1024, 0),
							{ IgnoreWater = true }
						)
						local y = math.max(if ground then ground.Position.Y else top, top) + 3
						assert(
							travels(roblox.Vector3.new(x, y, z)),
							layout.id
								.. ":"
								.. target.Name
								.. " next to it travels at "
								.. offset[1]
								.. ","
								.. offset[2]
						)
					end
					assert(
						not travels(roblox.Vector3.new(p.X + 30, top + 3, p.Z)),
						layout.id .. ":" .. target.Name .. " refused 30 studs away"
					)
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
	["home republishing an unchanged state does no render work"] = function()
		local engine = Engine.new()
		local workspace = engine.game:GetService("Workspace")
		local fills = 0
		workspace.Terrain.FillBlock = function()
			fills += 1
		end
		local source: any = table.clone(Source)
		source.seed, source.renderRole = 79, engine.role.build
		local world = engine.home.live(Content, source, Policy, function()
			return 0
		end)
		local rules = HomeContent.rules(Content)
		local state = Home.new("owner", rules, 79)
		world.publishHome(state, rules)
		local first = fills
		assert(first > 0, "the first publish renders the land")
		-- Snapshot reads publish a fresh copy every server frame; none of them may re-render.
		for _ = 1, 5 do
			world.publishHome(Home.copy(state), rules)
		end
		assert(fills == first, "unchanged home re-rendered " .. (fills - first) .. " terrain blocks")
		state.landRank = 2
		world.publishHome(state, rules)
		assert(fills > first, "a changed home still renders")
		world.destroy()
	end,
	["every archipelago stage arrival is inside a gather prompt's activation range"] = function()
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
			world.bind({} :: any)
			engine.move("1", { x = 0, y = 0, z = 0 })
			local client = engine.gatherClient("1", function()
				return { ok = true }
			end)
			local root = workspace:FindFirstChild("ForgeRoleWorld")
			-- SurvivalWorld places an arriving character at the spawn + 4 studs.
			local at = root:FindFirstChild("SurvivalSpawn").Position + roblox.Vector3.new(0, 4, 0)
			local best = math.huge
			for _, prompt in root:GetDescendants() do
				if prompt:IsA("ProximityPrompt") and prompt.Name == "ForgeGather" then
					best = math.min(best, (prompt.Parent.Position - at).Magnitude - prompt.MaxActivationDistance)
				end
			end
			assert(best <= 0, layout.id .. " arrival is " .. best .. " studs outside every gather prompt")
			client.destroy()
			world.destroy()
			checked += 1
		end
		assert(checked == 20, "all 20 archipelago stages checked")
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
			["./StructureMeshes"] = engine.meshes,
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
	["every live Topology role boots through SurvivalWorldBootstrap with a world builder"] = function()
		local Topology = require("../../core/domain/island/Topology")
		local roles = {}
		for role in Topology.ROLES do
			if role ~= "onboarding" then
				table.insert(roles, role)
			end
		end
		table.sort(roles)
		assert(#roles == 12, "every non-onboarding role covered")
		for _, region in Content.supportRegions do
			assert(Topology.ROLES[region.role], region.id .. " names unknown live role " .. tostring(region.role))
		end
		for _, role in roles do
			local engine = Engine.new()
			local bootstrap = engine.load("games/robango-island/src/server/SurvivalWorldBootstrap.luau", {
				["./WorldDressing"] = engine.dressing,
				["./StructureMeshes"] = engine.meshes,
			}, {
				Parent = {
					RoleWorld = engine.role,
					HomeWorld = engine.home,
					BrawlWorld = require("./src/server/BrawlWorld"),
				},
			})
			local source: any = table.clone(Source)
			if role == "archipelago" then
				source.expedition = { status = "active", templateId = "rw.a1", stage = 1, seed = 79 }
			end
			local ok, world = pcall(bootstrap, Content, source, Policy, function()
				return 0
			end, role, false)
			assert(ok, role .. " boot failed: " .. tostring(world))
			assert(world.roleSource and #world.roleSource.nodes >= 0, role .. " world has a role source")
			world.destroy()
		end
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
	["Saltmeadow town renders 28 claimable plot stakes, docks to harbor and rift, and flags claims"] = function()
		local TownPlots = require("./src/shared/TownPlots")
		local engine = Engine.new()
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.town", 1776)
		local root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
		local plots = root:FindFirstChild("ForgeTownPlots")
		assert(plots and #plots:GetChildren() == 28, "28 plot models")
		local claims, docks = 0, {}
		for _, prompt in root:GetDescendants() do
			if prompt:IsA("ProximityPrompt") and prompt.Name == "ForgeTownClaim" then
				claims += 1
				assert(prompt:GetAttribute("ForgeActionKey") == "claim", "claim prompt is localized")
			elseif prompt:IsA("ProximityPrompt") and prompt.Name == "ForgeDock" then
				docks[prompt:GetAttribute("ForgeDestination")] = true
			end
		end
		assert(claims == 28, "one claim prompt per plot")
		assert(docks.harbor and docks.archipelago, "town docks reach the harbor and the rift")
		local called: any = nil
		world.missionAction = function(actor, operation, target)
			called = { actor, operation, target }
			return { ok = true }
		end
		local w01 = plots:FindFirstChild("W01"):FindFirstChild("plot.W01")
		w01:FindFirstChild("ForgeTownClaim").Triggered:Fire({ UserId = 5, SetAttribute = function() end })
		assert(called and called[2] == "town-claim" and called[3] == "W01", "stake sends town-claim")
		local doc = assert(TownPlots.claim(world.townLayout, "town-01", nil, "W01", "5", { developmentRank = 1 }, 0))
		world.publishTownPlot("W01", doc)
		local flag = plots:FindFirstChild("W01"):FindFirstChild("flag.W01")
		assert(flag.Transparency == 0 and not w01:FindFirstChild("ForgeTownClaim").Enabled, "claimed plot flies a flag")
		world.destroy()
		local onboarding = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.onboarding", 1776)
		local towns = 0
		for _, prompt in engine.game:GetService("Workspace"):GetDescendants() do
			if
				prompt:IsA("ProximityPrompt")
				and prompt.Name == "ForgeDock"
				and prompt:GetAttribute("ForgeDestination") == "town"
			then
				towns += 1
			end
		end
		assert(towns == 1, "onboarding sails to the town")
		onboarding.destroy()
	end,
	-- D2 F2: on 2 of 3 cold starts the engine auto-loaded the character at (0, y, 0) before the relief
	-- terrain existed; it fell to Y~-520 (below FallenPartsDestroyHeight) and waited out RespawnTime
	-- 270 (the C6 down hold). The place must not auto-load, the role world must publish when the
	-- ground under its spawn is written, and SpawnGate loads characters only after that.
	["D2: the place never auto-loads characters and every role spawn stands on written ground"] = function()
		local project = serde.decode("json", fs.readFile("games/robango-island/default.project.json"))
		local players = project.tree.Players
		assert(players and players["$properties"].CharacterAutoLoads == false, "Players.CharacterAutoLoads is false")
		assert(project.tree.ServerScriptService.SpawnGate, "SpawnGate ships in ServerScriptService")
		local roblox: any = require("@lune/roblox")
		local Kits = require("./src/shared/BiomeKits")
		for _, layoutId in { "rw.onboarding", "rw.explore10", "rw.a1.s1", "rw.harbor", "rw.town" } do
			local engine = Engine.new(nil, true)
			local world = engine.role.build(Content, Source, Policy, function()
				return 0
			end, layoutId, 1776)
			assert(type(world.spawnReady) == "function" and world.spawnPart, layoutId .. " publishes its spawn gate")
			assert(world.spawnReady(), layoutId .. ": spawn ground is written once the build returns")
			local at = world.spawnPart.Position
			local hit = engine.game:GetService("Workspace"):Raycast(
				roblox.Vector3.new(at.X, 512, at.Z),
				roblox.Vector3.new(0, -1024, 0),
				{ IgnoreWater = true }
			)
			assert(hit, layoutId .. ": no terrain under the spawn")
			assert(at.Y >= hit.Position.Y, layoutId .. ": spawn sits below the written ground")
			assert(at.Y - hit.Position.Y <= 4, layoutId .. ": spawn floats " .. at.Y - hit.Position.Y .. " studs up")
			local layout: any = nil
			for _, candidate in Content.layouts do
				layout = if candidate.id == layoutId then candidate else layout
			end
			local near = false
			for _, point in Kits.arrivals(layout) do
				near = near or (point.x - at.X) ^ 2 + (point.z - at.Z) ^ 2 <= 1
			end
			assert(near, layoutId .. ": the spawn is one of the kit arrival clearings")
			world.destroy()
		end
	end,
	["D2: SpawnGate holds characters until the spawn is ready, returns void falls, reloads non-down deaths"] = function()
		local roblox: any = require("@lune/roblox")
		local engine = Engine.new()
		local Gate = engine.load("games/robango-island/src/server/SpawnGate.luau", {}, nil)
		local function signal(): any
			local handlers = {}
			return {
				Connect = function(_, fn)
					table.insert(handlers, fn)
					return {
						Disconnect = function()
							table.remove(handlers, table.find(handlers, fn) :: number)
						end,
					}
				end,
				Fire = function(_, ...)
					for _, fn in table.clone(handlers) do
						fn(...)
					end
				end,
			}
		end
		local spawn = engine.newInstance("SpawnLocation")
		spawn.CFrame = roblox.CFrame.new(10, 30, -20)
		local list, added, heartbeat = {}, signal(), signal()
		local players = { PlayerAdded = added, PlayerRemoving = signal() }
		function players.GetPlayers()
			return list
		end
		local function newPlayer(id: number): any
			local player: any = { UserId = id, Parent = players, Character = nil, CharacterAdded = signal(), loads = 0 }
			function player.LoadCharacterAsync(self)
				self.loads += 1
				local character = engine.newInstance("Model")
				local root = engine.newInstance("Part")
				root.Name, root.Parent = "HumanoidRootPart", character
				local humanoid = engine.newInstance("Humanoid")
				humanoid.Died, humanoid.Parent = signal(), character
				self.Character = character
				self.CharacterAdded:Fire(character)
			end
			return player
		end
		local ready, alive = false, { ["1"] = true, ["2"] = true }
		local delayed: { () -> () } = {}
		local gate = Gate.start({
			players = players,
			heartbeat = heartbeat,
			spawn = spawn,
			ready = function()
				return ready
			end,
			alive = function(actor)
				return alive[actor]
			end,
			delay = function(seconds, fn)
				assert(seconds == Gate.RESPAWN_SECONDS, "reload delay")
				table.insert(delayed, fn)
			end,
		})
		local one, two = newPlayer(1), newPlayer(2)
		for _, player in { one, two } do
			table.insert(list, player)
			added:Fire(player)
		end
		for _ = 1, 3 do
			heartbeat:Fire()
		end
		assert(one.loads == 0 and two.loads == 0, "no character before the role's ground exists")
		ready = true
		heartbeat:Fire()
		heartbeat:Fire()
		assert(one.loads == 1 and two.loads == 1, "each player loads exactly once when ready")
		assert(one.RespawnLocation == spawn, "respawns target the role spawn")
		local root = one.Character:FindFirstChild("HumanoidRootPart")
		assert(
			(root.Position - (spawn.CFrame.Position + roblox.Vector3.new(0, Gate.LIFT, 0))).Magnitude < 1e-6,
			"seated"
		)
		-- A void fall goes back to the spawn before the engine's FallenPartsDestroyHeight (-500).
		assert(Gate.VOID_Y > -500, "void return fires above the destroy height")
		root.Position = roblox.Vector3.new(0, Gate.VOID_Y - 1, 0)
		heartbeat:Fire()
		assert(root.Position.Y > 0 and one.loads == 1, "void fall teleported to the spawn, no death")
		-- A death outside the down flow (durable health above 0) reloads after RESPAWN_SECONDS, not 270.
		assert(Gate.RESPAWN_SECONDS <= 10, "non-down respawn is quick")
		one.Character:FindFirstChildOfClass("Humanoid").Died:Fire()
		-- A downed actor (durable health 0) stays with the C6 down hold.
		alive["2"] = false
		two.Character:FindFirstChildOfClass("Humanoid").Died:Fire()
		assert(#delayed == 2, "both deaths scheduled a check")
		for _, fn in delayed do
			fn()
		end
		assert(one.loads == 2, "a non-down death reloads at the spawn")
		assert(two.loads == 1, "a downed actor is left to the down hold")
		gate.destroy()
	end,
}
