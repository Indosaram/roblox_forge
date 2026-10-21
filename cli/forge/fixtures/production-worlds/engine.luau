--!strict
-- Headless engine only: positions, tags, signals and ray queries. No gameplay facts.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local M = {}
function M.new(physicalWarehouse: boolean?): any
	local callbacks: { any } = {}
	local actors: any = {}
	local tags: any = {}
	local function signal()
		local handlers: { (...any) -> () } = {}
		return {
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
	local function instance(className): any
		if className == "Terrain" then
			local properties: any = {
				FillBlock = function() end,
				FillBall = function() end,
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
		function value:WaitForChild(name)
			return assert(self:FindFirstChild(name), name)
		end
		function value:SetAttribute(key, data)
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
	workspace.Raycast = function(_, origin: any, direction: any): any
		-- The preview depot is a real collidable box, not an always-clear reach mock.
		if physicalWarehouse then
			for _, value in callbacks do
				if value.Name == "Warehouse" and value.CanCollide and value.CanQuery ~= false and value.Parent then
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
	local heartbeat = signal()
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
	services.ReplicatedStorage = {
		WaitForChild = function()
			return forge
		end,
	}
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
		["./DinosaurRig"] = {
			new = function(_, id, position, parent)
				local model = instance("Model")
				model.Name, model.Position, model.Parent = id, position, parent
				return model
			end,
		},
		["./MountVisual"] = {
			species = function()
				return nil
			end,
			plan = function()
				return { attach = {}, detach = {} }
			end,
		},
	}, nil)
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
	}
end
return M
