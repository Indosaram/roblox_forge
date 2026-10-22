--!strict
-- Headless engine only: positions, tags, signals and ray queries. No gameplay facts.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local M = {}
function M.new(physicalWarehouse: boolean?, physicalTerrain: boolean?): any
	local callbacks: { any } = {}
	local actors: any = {}
	local tags: any = {}
	local terrainWrites: { any } = {}
	-- Like Roblox, voxel writes become raycastable only after the engine steps.
	local pendingTerrain: { any } = {}
	local function settleTerrain()
		for _, write in pendingTerrain do
			table.insert(terrainWrites, write)
		end
		table.clear(pendingTerrain)
	end
	local function signal()
		local handlers: { (...any) -> () } = {}
		return {
			Wait = function() end,
			Connect = function(_, fn)
				table.insert(handlers, fn)
				return { Disconnect = function() end }
			end,
			Fire = function(_, ...)
				for _, fn in handlers do
					fn(...)
				end
			end,
		}
	end
	-- Terrain accepts only these materials; Roblox throws "Invalid terrain material" otherwise.
	local terrainMaterials = {}
	for _, name in
		{
			"Air",
			"Water",
			"Grass",
			"LeafyGrass",
			"Sand",
			"Rock",
			"Slate",
			"Ground",
			"Mud",
			"Snow",
			"Ice",
			"Glacier",
			"Basalt",
			"CrackedLava",
			"Sandstone",
			"Limestone",
			"Asphalt",
			"Concrete",
			"Brick",
			"Cobblestone",
			"Pavement",
			"Salt",
			"WoodPlanks",
		}
	do
		terrainMaterials[name] = true
	end
	local function terrainMaterial(material)
		local name = if type(material) == "string" then material else tostring(material and material.Name or material)
		assert(terrainMaterials[name], "Invalid terrain material " .. name)
	end
	local function instance(className): any
		if className == "Terrain" then
			local properties: any = {
				FillBlock = function(_, frame, size, material)
					terrainMaterial(material)
					if physicalTerrain then
						table.insert(pendingTerrain, { position = frame.Position, size = size, material = material })
					end
				end,
				FillBall = function(_, position, radius, material)
					terrainMaterial(material)
					if physicalTerrain then
						table.insert(pendingTerrain, { position = position, radius = radius, material = material })
					end
				end,
				FillCylinder = function(_, frame, height: number, radius: number, material)
					terrainMaterial(material)
					if physicalTerrain then
						-- Upright cylinder; its bounding box is close enough for downward ground rays.
						local size = roblox.Vector3.new(radius * 2, height, radius * 2)
						table.insert(pendingTerrain, { position = frame.Position, size = size, material = material })
					end
				end,
				SetMaterialColor = function(_, material)
					terrainMaterial(material)
				end,
			}
			local writable = {
				WaterColor = true,
				WaterTransparency = true,
				WaterWaveSize = true,
				WaterWaveSpeed = true,
				WaterReflectance = true,
				FillBlock = true,
				FillBall = true,
			}
			-- Keep every value behind a proxy so repeated writes also hit __newindex.
			return setmetatable({}, {
				__index = properties,
				__newindex = function(_, key, data)
					assert(writable[key], tostring(key) .. " is not a script-writable Terrain property")
					properties[key] = data
				end,
			})
		end
		local value: any = {
			ClassName = className,
			Name = className,
			children = {},
			attributes = {},
			Position = roblox.Vector3.zero,
			CFrame = roblox.CFrame.identity,
			CanCollide = className == "Part" or className == "SpawnLocation",
			Health = if className == "Humanoid" then 100 else nil,
		}
		function value:IsA(kind)
			return kind == self.ClassName
				or (
					kind == "BasePart"
					and (self.ClassName == "Part" or self.ClassName == "SpawnLocation" or self.ClassName == "WedgePart")
				)
		end
		function value:IsDescendantOf(parent)
			local current = self.Parent
			while current do
				if current == parent then
					return true
				end
				current = current.Parent
			end
			return false
		end
		function value:FindFirstChild(name)
			for _, child in callbacks do
				if child.Parent == self and child.Name == name and not child.destroyed then
					return child
				end
			end
			return nil
		end
		function value:FindFirstChildOfClass(kind)
			for _, child in callbacks do
				if child.Parent == self and child.ClassName == kind and not child.destroyed then
					return child
				end
			end
			return nil
		end
		function value:GetChildren()
			local result = {}
			for _, child in callbacks do
				if child.Parent == self and not child.destroyed then
					table.insert(result, child)
				end
			end
			return result
		end
		function value:GetDescendants()
			local result = {}
			for _, child in callbacks do
				if child:IsDescendantOf(self) and not child.destroyed then
					table.insert(result, child)
				end
			end
			return result
		end
		function value:PivotTo(cf)
			local previous = self.WorldPivot or roblox.CFrame.identity
			for _, child in self:GetDescendants() do
				if child:IsA("BasePart") then
					child.CFrame = cf * previous:ToObjectSpace(child.CFrame)
					child.Position = child.CFrame.Position
				end
			end
			self.WorldPivot = cf
		end
		function value:GetPivot()
			return self.WorldPivot or roblox.CFrame.identity
		end
		function value:ScaleTo(scale)
			for _, child in self:GetDescendants() do
				if child:IsA("BasePart") then
					child.Size *= scale
					child.CFrame = roblox.CFrame.new(child.CFrame.Position * scale) * child.CFrame.Rotation
					child.Position = child.CFrame.Position
				end
			end
		end
		function value:Clone()
			local clone = instance(self.ClassName)
			for key, data in self do
				if type(data) ~= "function" and key ~= "Parent" and key ~= "children" then
					clone[key] = data
				end
			end
			for _, child in self:GetChildren() do
				child:Clone().Parent = clone
			end
			return clone
		end
		function value:WaitForChild(name)
			return assert(self:FindFirstChild(name), name)
		end
		function value:SetAttribute(key, data)
			-- Roblox rejects tables ("Dictionary is not a supported attribute type"); the
			-- fake must too, or a live startup crash passes every production-world spec.
			assert(
				type(data) ~= "table" or getmetatable(data) ~= nil,
				"Dictionary is not a supported attribute type: " .. key
			)
			self.attributes[key] = data
			self.AttributeChanged:Fire(key)
		end
		function value:GetAttribute(key)
			return self.attributes[key]
		end
		function value:Destroy()
			self.destroyed, self.Parent = true, nil
		end
		function value:Fire(...)
			self.Event:Fire(...)
		end
		value.Triggered, value.Event, value.Activated = signal(), signal(), signal()
		value.AttributeChanged, value.AncestryChanged = signal(), signal()
		table.insert(callbacks, value)
		return value
	end
	local workspace = instance("Workspace")
	function workspace:GetServerTimeNow()
		return 0
	end
	workspace.Terrain = instance("Terrain")
	workspace.Raycast = function(_, origin: any, direction: any, params: any): any
		if physicalTerrain then
			local intervals, boundaries = {}, { 0, 1 }
			for index, fill in terrainWrites do
				local low, high = 0, 1
				if fill.radius then
					local offset = origin - fill.position
					local a, b = direction:Dot(direction), 2 * offset:Dot(direction)
					local c = offset:Dot(offset) - fill.radius ^ 2
					local discriminant = b * b - 4 * a * c
					if discriminant < 0 then
						low = 2
					else
						low = math.max(low, (-b - math.sqrt(discriminant)) / (2 * a))
						high = math.min(high, (-b + math.sqrt(discriminant)) / (2 * a))
					end
				else
					for _, axis in { "X", "Y", "Z" } do
						local minimum = fill.position[axis] - fill.size[axis] / 2
						local maximum = fill.position[axis] + fill.size[axis] / 2
						if direction[axis] == 0 then
							if origin[axis] < minimum or origin[axis] > maximum then
								low = 2
							end
						else
							local a = (minimum - origin[axis]) / direction[axis]
							local b = (maximum - origin[axis]) / direction[axis]
							low, high = math.max(low, math.min(a, b)), math.min(high, math.max(a, b))
						end
					end
				end
				if low < high then
					table.insert(intervals, { low = low, high = high, index = index })
					table.insert(boundaries, low)
					table.insert(boundaries, high)
				end
			end
			table.sort(boundaries)
			for index = 2, #boundaries do
				local t = (boundaries[index - 1] + boundaries[index]) / 2
				local latest = 0
				for _, interval in intervals do
					if interval.low <= t and interval.high >= t then
						latest = math.max(latest, interval.index)
					end
				end
				local fill = terrainWrites[latest]
				if
					fill
					and fill.material ~= roblox.Enum.Material.Air
					and not (params and params.IgnoreWater and fill.material == roblox.Enum.Material.Water)
				then
					return {
						Instance = workspace.Terrain,
						Position = origin + direction * boundaries[index - 1],
						Normal = roblox.Vector3.yAxis,
					}
				end
			end
			return nil
		end
		-- The preview depot is a real collidable box, not an always-clear reach mock.
		if physicalWarehouse then
			for _, value in callbacks do
				if
					-- Name first: FindFirstChild on every ray candidate made long scenarios crawl.
					(
						value.Name == "Warehouse"
						or ((value.Name == "entry" or value.Name == "exit") and value:FindFirstChild("ForgeDock"))
					)
					and value.CanCollide
					and value.CanQuery ~= false
					and value.Parent
				then
					local low, high = 0, 1
					for _, axis in { "X", "Y", "Z" } do
						local minimum = value.Position[axis] - value.Size[axis] / 2
						local maximum = value.Position[axis] + value.Size[axis] / 2
						if direction[axis] == 0 then
							if origin[axis] < minimum or origin[axis] > maximum then
								low = 2
							end
						else
							local a = (minimum - origin[axis]) / direction[axis]
							local b = (maximum - origin[axis]) / direction[axis]
							low, high = math.max(low, math.min(a, b)), math.min(high, math.max(a, b))
						end
					end
					if low <= high then
						return { Instance = value, Position = origin + direction * low }
					end
				end
			end
		end
		if direction.Y < 0 and direction.X == 0 and direction.Z == 0 then
			if origin.Y >= 0 and origin.Y + direction.Y <= 0 then
				return { Position = roblox.Vector3.new(origin.X, 0, origin.Z), Normal = roblox.Vector3.yAxis }
			end
		end
		return nil
	end
	workspace.GetPartBoundsInBox = function()
		return {}
	end
	local heartbeat: any = signal()
	local heartbeatFire: any = heartbeat.Fire
	heartbeat.Wait = function()
		settleTerrain()
	end
	heartbeat.Fire = function(self, ...)
		settleTerrain()
		return heartbeatFire(self, ...)
	end
	local added, removed = signal(), signal()
	local guid = 0
	local services: any = {
		Workspace = workspace,
		Players = {
			GetPlayerByUserId = function(_, id)
				return actors[tostring(id)]
			end,
			GetPlayers = function()
				local result = {}
				for _, actor in actors do
					table.insert(result, actor)
				end
				return result
			end,
		},
		CollectionService = {
			GetTagged = function(_, tag)
				local result = {}
				for target, labels in tags do
					if labels[tag] then
						table.insert(result, target)
					end
				end
				return result
			end,
			GetInstanceAddedSignal = function()
				return added
			end,
			GetInstanceRemovedSignal = function()
				return removed
			end,
			AddTag = function(_, target, tag)
				tags[target] = tags[target] or {}
				tags[target][tag] = true
			end,
			HasTag = function(_, target, tag)
				return tags[target] and tags[target][tag] == true
			end,
			RemoveTag = function(_, target, tag)
				if tags[target] then
					tags[target][tag] = nil
				end
			end,
		},
		RunService = {
			Heartbeat = heartbeat,
			RenderStepped = signal(),
			IsStudio = function()
				return false
			end,
		},
		ProximityPromptService = { PromptShown = signal(), PromptHidden = signal() },
		UserInputService = { TouchEnabled = false },
		ServerStorage = instance("Folder"),
		Lighting = instance("Lighting"),
		HttpService = {
			GenerateGUID = function()
				guid += 1
				return "engine-event-" .. guid
			end,
		},
	}
	local forge: any = {
		core = {
			domain = {
				random = { Rng = require("../../../../core/domain/random/Rng") },
				command = { Journal = require("../../../../core/domain/command/Journal") },
				island = { ArchipelagoTerrain = require("../../../../core/domain/island/ArchipelagoTerrain") },
			},
		},
		genres = { ["survival-coop"] = { module = {} } },
	}
	services.ReplicatedStorage = instance("Folder")
	services.ReplicatedStorage.WaitForChild = function()
		return forge
	end
	local game = {
		GetService = function(_, key)
			return services[key]
		end,
	}
	local function load(path: string, dependencies: any, scriptObject: any): any
		return luau.load(fs.readFile(path), {
			environment = {
				task = require("@lune/task"),
				game = game,
				workspace = workspace,
				Instance = { new = instance },
				Vector3 = roblox.Vector3,
				CFrame = roblox.CFrame,
				Color3 = roblox.Color3,
				UDim2 = roblox.UDim2,
				UDim = roblox.UDim,
				NumberRange = roblox.NumberRange,
				NumberSequence = roblox.NumberSequence,
				NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
				ColorSequence = roblox.ColorSequence,
				Enum = roblox.Enum,
				RaycastParams = {
					new = function()
						return {}
					end,
				},
				OverlapParams = {
					new = function()
						return {}
					end,
				},
				script = scriptObject,
				require = function(key)
					return if type(key) ~= "string" then key else dependencies[key] or {}
				end,
			},
		})()
	end
	local module = forge.genres["survival-coop"].module
	module.SurvivalWorld = load("genres/survival-coop/module/SurvivalWorld.luau", {
		["../../../core/domain/inventory/Inventory"] = require("../../../../core/domain/inventory/Inventory"),
		["../../../core/domain/settlement/Settlement"] = require("../../../../core/domain/settlement/Settlement"),
		["../../../core/domain/survival/Archetype"] = require("../../../../core/domain/survival/Archetype"),
		["./CharacterRules"] = require("../../../../genres/survival-coop/module/CharacterRules"),
		["./WildlifeWorld"] = {
			new = function(config)
				local states: any = {}
				return {
					register = function(model, id, _catalogId)
						states[id] = { home = { x = model.Position.X, y = model.Position.Y, z = model.Position.Z } }
					end,
					publish = function(state)
						states[state.id] = state
					end,
					destroy = function() end,
					access = function(actor, target): any
						local state, player = states[target], actors[actor]
						if not state or not player then
							return nil
						end
						local position = player.Character:FindFirstChild("HumanoidRootPart").Position
						local point = { x = position.X, y = position.Y, z = position.Z }
						local delta =
							{ x = state.home.x - point.x, y = state.home.y - point.y, z = state.home.z - point.z }
						return {
							actorId = actor,
							alive = config.alive(actor),
							position = point,
							facing = delta,
							targetPosition = state.home,
							lineOfSight = true,
							equipped = config.equipment(actor) or {},
						}
					end,
				}
			end,
		},
		["./DinosaurRig"] = load("genres/survival-coop/module/DinosaurRig.luau", {}, nil),
		["./MountVisual"] = {
			species = function()
				return nil
			end,
			plan = function()
				return { attach = {}, detach = {} }
			end,
		},
	}, nil)
	module.DinosaurRig = load("genres/survival-coop/module/DinosaurRig.luau", {}, nil)
	module.HarborFacilities = require("../../../../genres/survival-coop/module/HarborFacilities")
	module.CharacterRules = require("../../../../genres/survival-coop/module/CharacterRules")
	local dressing = load("games/robango-island/src/server/WorldDressing.luau", {}, nil)
	forge.core.infra = {
		render = {
			ProcAssets = {
				build = function()
					return { ScaleTo = function() end, PivotTo = function() end }
				end,
			},
		},
	}
	forge.games = { ["robango-island"] = { src = { shared = { ProcAssets = {} } } } }
	forge.games["robango-island"].src.shared.IslandTerrain =
		require("../../../../games/robango-island/src/shared/IslandTerrain")
	local preview = load("games/robango-island/src/server/SurvivalWorldBootstrap.luau", {
		["./WorldDressing"] = dressing,
	}, nil)
	local role = load("games/robango-island/src/server/RoleWorld.luau", { ["./WorldDressing"] = dressing }, nil)
	local home = load("games/robango-island/src/server/HomeWorld.luau", { ["./WorldDressing"] = dressing }, nil)
	local archipelago = require("../../../../games/robango-island/src/server/ArchipelagoWorld")
	return {
		dressing = dressing,
		forge = forge,
		game = game,
		load = load,
		role = role,
		home = home,
		archipelago = archipelago,
		preview = preview,
		gatherClient = function(actor, invoke)
			local player = assert(actors[actor], "client actor joined")
			services.Players.LocalPlayer = player
			local gui = instance("PlayerGui")
			gui.Name, gui.Parent = "PlayerGui", player
			local state = signal()
			local storage = services.ReplicatedStorage
			local original = storage.WaitForChild
			storage.WaitForChild = function(_, name): any
				if name == "ForgeAction" then
					return {
						InvokeServer = function(_, ...)
							return invoke(...)
						end,
					}
				elseif name == "ForgeState" then
					return { OnClientEvent = state }
				end
				return original(storage, name)
			end
			local lastResult: any = nil
			local client = load("genres/survival-coop/module/GatheringClient.luau", {
				["../../../core/infra/genre/CommandTransport"] = require(
					"../../../../core/infra/genre/CommandTransport"
				),
			}, nil).start({
				onResult = function(result, diagnostic)
					lastResult = result
					assert(
						result.ok or (result.data and result.data.status == "pending"),
						tostring(result.reason) .. ": " .. tostring(diagnostic)
					)
				end,
			})
			storage.WaitForChild = original
			return {
				destroy = client.destroy,
				result = function()
					return lastResult
				end,
			}
		end,
		interact = function(actor, target)
			for index = #callbacks, 1, -1 do
				local value = callbacks[index]
				if value.ClassName == "ProximityPrompt" and value.Parent and value.Parent.Name == target then
					value.Triggered:Fire(actors[actor])
					return
				end
			end
			error("missing physical interaction: " .. target)
		end,
		equip = function(world, actor, itemId)
			local tool = instance("Tool")
			tool.Parent = actors[actor].Character
			world.registerTool(tool, actor, itemId)
		end,
		move = function(actor, position)
			local player = actors[actor]
			if not player then
				local character = instance("Model")
				character.Parent = workspace
				local root = instance("Part")
				root.Name, root.Parent = "HumanoidRootPart", character
				local humanoid = instance("Humanoid")
				humanoid.Parent = character
				player = {
					UserId = tonumber(actor),
					Character = character,
					FindFirstChildOfClass = function()
						return nil
					end,
					FindFirstChild = function(self, name)
						for _, value in callbacks do
							if value.Parent == self and value.Name == name then
								return value
							end
						end
						return nil
					end,
				}
				player.WaitForChild = player.FindFirstChild
				actors[actor] = player
			end
			player.Character:FindFirstChild("HumanoidRootPart").Position =
				roblox.Vector3.new(position.x, position.y, position.z)
		end,
		parts = callbacks,
		terrainWrites = terrainWrites,
	}
end
return M
