--!strict
-- Headless engine only: positions, tags, signals and ray queries. No gameplay facts.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local M = {}
function M.new(): any
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
	local function instance(className)
		local value: any = {
			ClassName = className,
			Name = className,
			children = {},
			attributes = {},
			Position = roblox.Vector3.zero,
			CFrame = roblox.CFrame.identity,
			Health = if className == "Humanoid" then 100 else nil,
		}
		function value:IsA(kind)
			return kind == self.ClassName
				or (kind == "BasePart" and (self.ClassName == "Part" or self.ClassName == "SpawnLocation"))
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
		function value:SetAttribute(key, data)
			self.attributes[key] = data
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
		value.Triggered, value.Event = signal(), signal()
		table.insert(callbacks, value)
		return value
	end
	local workspace = instance("Workspace")
	workspace.Terrain = { FillBlock = function() end }
	workspace.Terrain.FillBall = function() end
	workspace.Raycast = function(_, origin: any, direction: any): any
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
			IsStudio = function()
				return false
			end,
		},
		ServerStorage = instance("Folder"),
		Lighting = instance("Lighting"),
		HttpService = {
			GenerateGUID = function()
				return "engine-event"
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
				}
				actors[actor] = player
			end
			player.Character:FindFirstChild("HumanoidRootPart").Position =
				roblox.Vector3.new(position.x, position.y, position.z)
		end,
		parts = callbacks,
	}
end
return M
