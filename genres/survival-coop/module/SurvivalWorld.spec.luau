--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Settlement = require("../../../core/domain/settlement/Settlement")
local MountVisual = require("./MountVisual")
local healthSignals: { [any]: any } = {}
local healthValues: { [any]: number } = {}
local deferredHealth: { () -> () }? = nil
-- Lune's method registry is process-global and refuses a second registration
-- for one class method. Folder world methods are therefore registered exactly
-- once here; each spec installs its own handler before exercising them so
-- repeated specs in one process cannot collide and never observe a stale
-- handler from a previously run spec.
local raycastHandler: any = nil
local boundsHandler: any = nil
local folderWorldMethodsRegistered = false
local function ownFolderWorldMethods(): ()
	if folderWorldMethodsRegistered then
		return
	end
	folderWorldMethodsRegistered = true
	roblox.implementMethod("Folder", "Raycast", function(self, ...)
		assert(raycastHandler, "FOLDER_RAYCAST_UNOWNED")
		return raycastHandler(self, ...)
	end)
	roblox.implementMethod("Folder", "GetPartBoundsInBox", function(self, ...)
		assert(boundsHandler, "FOLDER_BOUNDS_UNOWNED")
		return boundsHandler(self, ...)
	end)
end
roblox.implementMethod("Model", "PivotTo", function(instance, cf)
	local root = instance:FindFirstChild("HumanoidRootPart")
	if root then
		root.CFrame = cf
	end
end)
roblox.implementProperty("Humanoid", "HealthChanged", function(instance)
	return healthSignals[instance]
end)
roblox.implementProperty("Humanoid", "Health", function(instance)
	return healthValues[instance] or 100
end, function(instance, value)
	local previous = healthValues[instance] or 100
	healthValues[instance] = value
	local signal = healthSignals[instance]
	local callback = if signal then signal.callback else nil
	if callback and value ~= previous then
		if deferredHealth then
			table.insert(deferredHealth, function()
				callback(value)
			end)
		else
			callback(value)
		end
	end
end)

local function fixture(dependencies: any?)
	local world = roblox.Instance.new("Folder")
	local character = roblox.Instance.new("Model")
	character.Parent = world
	local root = roblox.Instance.new("Part")
	root.Name, root.Parent = "HumanoidRootPart", character
	root.Position = roblox.Vector3.new(0, 0, 0)
	local spawn = roblox.Instance.new("SpawnLocation")
	spawn.Parent, spawn.Anchored = world, true
	local callbacks = {}
	local function signal(name)
		return {
			Connect = function(_, fn)
				callbacks[name] = fn
				return {
					Disconnect = function()
						callbacks[name] = nil
					end,
				}
			end,
		}
	end
	local humanoid = roblox.Instance.new("Humanoid")
	humanoid.Parent = character
	humanoid.Health = 100
	humanoid.MaxHealth = 100
	humanoid.WalkSpeed = 16
	local healthSignal = signal("health")
	healthSignals[humanoid] = healthSignal
	local connect = healthSignal.Connect
	healthSignal.Connect = function(self: any, fn: any)
		self.callback = fn
		return connect(self, fn)
	end
	local actor: any = { Character = character }
	local mate = roblox.Instance.new("Model")
	mate.Name, mate.Parent = "Tribemate", world
	local backpack = roblox.Instance.new("Backpack")
	actor.FindFirstChildOfClass = function(_, name)
		return if name == "Backpack" then backpack else nil
	end
	local tagged = {}
	local queries = 0
	local services: any = {
		Players = {
			GetPlayerByUserId = function(_, id)
				return if id == 1 then actor else nil
			end,
			-- A tribemate standing in the world: reach rays must pass through other characters.
			GetPlayers = function()
				return { actor, { Character = mate } }
			end,
		},
		Workspace = world,
		ServerStorage = roblox.Instance.new("Folder"),
		CollectionService = {
			AddTag = function(_, part, tag)
				tagged[part] = tag
			end,
			HasTag = function(_, part, tag)
				return tagged[part] == tag
			end,
			RemoveTag = function(_, part, tag)
				if tagged[part] == tag then
					tagged[part] = nil
				end
			end,
		},
		RunService = { Heartbeat = signal("heartbeat") },
		HttpService = {
			GenerateGUID = function()
				queries += 1
				return "event-" .. tostring(queries)
			end,
		},
	}
	local source = fs.readFile("genres/survival-coop/module/SurvivalWorld.luau")
	local module = luau.load(source, {
		environment = {
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
			require = function(name)
				if name == "../../../core/domain/inventory/Inventory" then
					return Inventory
				end
				if name == "./MountVisual" then
					return MountVisual :: any
				end
				return if dependencies then dependencies[name] or {} else {}
			end,
			Instance = roblox.Instance,
			Vector3 = roblox.Vector3,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
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
		},
	})()
	local elapsed = 0
	local create = module.new
	module.new = function(config)
		-- Deterministic retry clock: tests advance it explicitly instead of waiting
		-- on wall time, and no test may observe the real os.clock().
		config.now = config.now or function()
			return elapsed
		end
		local api = create(config)
		local bind = api.bind
		api.bind = function(session)
			if not session.personalTransfer then
				session.personalTransfer = function()
					return nil
				end
			end
			bind(session)
		end
		return api
	end
	local function advance(seconds: number)
		elapsed += seconds
	end
	return module, services, world, character, root, spawn, actor, callbacks, humanoid, advance
end

return {
	["settlement ports enforce reach support obstruction and publish only confirmed structures"] = function()
		local module, _, world, _, root, spawn = fixture()
		local obstructed, supported = false, true
		raycastHandler = function(_, rayOrigin, delta)
			if delta.Y == -64 then
				return if supported
					then {
						Instance = spawn,
						Normal = roblox.Vector3.new(0, 1, 0),
						Position = roblox.Vector3.new(rayOrigin.X, 4, rayOrigin.Z),
					}
					else nil
			end
			return if obstructed then { Instance = spawn } else nil
		end
		boundsHandler = function(_, _center, _size, overlap)
			local ignored = false
			for _, instance in overlap.FilterDescendantsInstances do
				ignored = ignored or instance.Name == "Tribemate"
			end
			assert(ignored, "a tribemate standing on the plot never blocks a build")
			return if obstructed then { spawn } else {}
		end
		ownFolderWorldMethods()
		local api = module.new({
			content = { structures = { { id = "bench", station = true } } },
			worldRevision = "map",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local ports = api.settlementPorts(roblox.Vector3.zero, roblox.Vector3.new(0, 2, 0))
		local state = Settlement.new({ tribeId = "camp", width = 8, depth = 8, cellStuds = 4, maxMembers = 4 }, "1")
		state = assert(Settlement.reserve(state, "1", 0, 0, {
			id = "build",
			x = 1,
			z = 1,
			rotation = 0,
			definition = { id = "bench", footprintX = 1, footprintZ = 1, cost = {} },
		}))
		local placement = state.reservations.build
		assert(
			ports.verify("1", placement, state) and ports.warehouse("1"),
			'ports.verify("1", placement, state) and ports.warehouse("1")'
		)
		root.Position = roblox.Vector3.new(100, 0, 0)
		assert(
			not ports.verify("1", placement, state) and not ports.warehouse("1"),
			"displaced root must fail verification"
		)
		root.Position = roblox.Vector3.zero
		obstructed = true
		assert(
			not ports.verify("1", placement, state) and not ports.warehouse("1"),
			"obstructed placement must fail verification"
		)
		obstructed, supported = false, false
		assert(not ports.verify("1", placement, state), 'not ports.verify("1", placement, state)')
		supported = true
		ports.publish(state)
		assert(not world:FindFirstChild("bench"), "reservation has no authoritative geometry")
		state = assert(Settlement.commit(state, "1", 1, "build"))
		ports.publish(state)
		local part = assert(world:FindFirstChild("bench"))
		assert(part.Position.Y == 4.5, "placed structure rests on raised terrain rather than plot origin")
		ports.publish(state)
		assert(world:FindFirstChild("bench") == part, "republication preserves instance")
		root.Position = roblox.Vector3.new(6, 2, 2)
		local stationId = part:GetAttribute("ForgeStationId")
		assert(type(stationId) == "string" and #stationId <= 64, 'type(stationId) == "string" and #stationId <= 64')
		assert(
			api.services.survivalSpatial.station("1", stationId).reachable,
			'api.services.survivalSpatial.station("1", stationId).reachable'
		)
		state = assert(Settlement.demolish(state, "1", 2, 0, "camp:build"))
		ports.publish(state)
		assert(
			not world:FindFirstChild("bench") and api.services.survivalSpatial.station("1", stationId) == nil,
			'not world:FindFirstChild("bench") and api.services.survivalSpatial.station("1", stationId) == nil'
		)
		api.destroy()
		world:Destroy()
	end,
	["canonical claimed tools equip revoke and rebuild across character and membership lifecycle"] = function()
		local equipped: any = nil
		local module, _, world, character, _, spawn, actor, callbacks = fixture({
			["./WildlifeWorld"] = {
				new = function(config)
					equipped = config.equipment
					return {
						access = function(id)
							return { equipped = equipped(id) }
						end,
						destroy = function() end,
					}
				end,
			},
		})
		local bag: any = { items = {}, reservations = {} }
		local joined = true
		local api = module.new({
			content = {
				structures = {},
				items = { { id = "spear", name = "Spear", tags = { "tool" }, maxDurabilityMilli = 100000 } },
			},
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
			wildlife = {
				catalog = {},
				spawns = {},
				maximum = 1,
				nowMillis = function()
					return 0
				end,
			},
		})
		api.bind({
			members = function()
				return if joined then { "1" } else {}
			end,
			snapshot = function()
				return {
					["survival-coop"] = { vitals = { healthMilli = 100000 }, inventory = { bag = { items = {} } } },
				}
			end,
			personalTransfer = function()
				return {
					profile = function()
						return {
							data = {
								envelope = { genres = { ["survival-coop"] = { data = { inventory = { bag = bag } } } } },
							},
						}
					end,
				}
			end,
		})
		local backpack = actor:FindFirstChildOfClass("Backpack")
		callbacks.heartbeat()
		assert(#backpack:GetChildren() == 0, "no tool before durable crafting claim")
		bag.items.claimed = { itemId = "claimed", catalogId = "spear", quantity = 1, durabilityMilli = 100000 }
		callbacks.heartbeat()
		local tool = assert(backpack:FindFirstChildOfClass("Tool"), "claimed spear projected")
		assert(
			tool:FindFirstChild("Handle") and tool:FindFirstChild("StoneHead") and not tool.CanBeDropped,
			"physical spear handle and tip"
		)
		tool.Name = "untrusted display name"
		tool.Parent = character -- Engine Humanoid equip reparents the SAME Tool.
		assert(api.wildlifeAccess("1", "hunter").equipped.claimed, "canonical registry not tool name")
		callbacks.heartbeat()
		assert(#backpack:GetChildren() == 0 and tool.Parent == character, "snapshot preserves equipped instance")
		for _, reason in { "reserved", "broken", "moved" } do
			if reason == "reserved" then
				bag.reservations.job = { claimed = 1 }
			elseif reason == "broken" then
				bag.items.claimed.durabilityMilli = 0
			else
				bag.items.claimed = nil
			end
			assert(not api.wildlifeAccess("1", "hunter").equipped.claimed, "immediate authority revocation")
			callbacks.heartbeat()
			assert(tool.Parent == nil, "unusable projection destroyed")
			bag.reservations = {}
			bag.items.claimed = { itemId = "claimed", catalogId = "spear", quantity = 1, durabilityMilli = 100000 }
			callbacks.heartbeat()
			tool = assert(backpack:FindFirstChildOfClass("Tool"), "restored claim projected")
			tool.Parent = character
		end
		local replacement = roblox.Instance.new("Model")
		replacement.Parent = world
		actor.Character = replacement
		callbacks.heartbeat()
		assert(tool.Parent == nil and #backpack:GetChildren() == 1, "respawn replaces old registry once")
		callbacks.heartbeat()
		assert(#backpack:GetChildren() == 1, "no duplicate after respawn")
		joined = false
		callbacks.heartbeat()
		assert(#backpack:GetChildren() == 0, "departure removes projection")
		joined = true
		callbacks.heartbeat()
		callbacks.heartbeat()
		assert(
			#backpack:GetChildren() == 1 and bag.items.claimed.quantity == 1,
			"rejoin projects without mint or duplication"
		)
		api.destroy()
		assert(#backpack:GetChildren() == 0, "world cleanup removes owned tool")
	end,
	["wildlife strikes retain stable queue identity while epoch and commit unavailable"] = function()
		local damage: any = nil
		local registered = 0
		local destroyed = false
		local module, _, world, _, _, spawn, _, callbacks, _, advance = fixture({
			["./WildlifeWorld"] = {
				new = function(config)
					damage = config.damage
					return {
						register = function()
							registered += 1
						end,
						destroy = function()
							destroyed = true
						end,
					}
				end,
			},
			["./DinosaurRig"] = {
				new = function(_, id, _, parent)
					local model = roblox.Instance.new("Model")
					model.Name, model.Parent = id, parent
					return model
				end,
				ground = function() end,
			},
		})
		local api = module.new({
			content = { structures = {} },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
			wildlife = {
				catalog = {},
				maximum = 2,
				nowMillis = function()
					return 100000
				end,
				spawns = { { id = "hunter-01", catalogId = "hunter", position = { x = 0, y = 4, z = 0 } } },
			},
		})
		local available = false
		local attempts = {}
		local health = 100000
		api.bind({
			members = function()
				return { "1" }
			end,
			snapshot = function()
				return {
					["survival-coop"] = {
						vitals = { healthMilli = health },
						speedMultiplierMilli = 1000,
						vitalsMovementMilli = 1000,
					},
				}
			end,
			commandEpoch = function()
				return if available then 7 else nil
			end,
			commandServer = function(_, request): { ok: boolean, reason: string?, stateVersion: number? }
				table.insert(attempts, request.requestId)
				if #attempts == 1 then
					return { ok = false, reason = "COMMIT_FAILED" }
				end
				health -= request.args[1]
				return { ok = true, stateVersion = 1 }
			end,
		})
		assert(registered == 1 and world:FindFirstChild("ForgeWildlife"), "configured actual world binding")
		damage("1", "hunter-01:1", 10000)
		callbacks.heartbeat()
		assert(#attempts == 0, "epoch unavailable retains unsubmitted strike")
		available = true
		-- The retained head is paced: each retry waits for the injected interval.
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		assert(#attempts == 2 and attempts[1] == attempts[2] and health == 90000, "same command identity retried once")
		api.destroy()
		assert(destroyed and not world:FindFirstChild("ForgeWildlife"), "wildlife bindings and owned rigs removed")
	end,
	["durable death automatically respawns only after a fenced successful command"] = function()
		local module, _, world, _, _, spawn, actor, callbacks, humanoid, advance = fixture()
		local api = module.new({
			content = { structures = {} },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local state = { vitals = { healthMilli = 100000 } }
		local requests: { { action: string, args: { number }, sessionEpoch: number } } = {}
		local loaded = 0
		actor.LoadCharacterAsync = function()
			assert(state.vitals.healthMilli == 100000, "durable respawn precedes engine load")
			loaded += 1
			local replacement = roblox.Instance.new("Model")
			replacement.Parent = world
			local replacementHumanoid = roblox.Instance.new("Humanoid")
			replacementHumanoid.Parent = replacement
			replacementHumanoid.Health = 100
			replacementHumanoid.MaxHealth = 100
			healthSignals[replacementHumanoid] = {
				Connect = function(self, callback)
					self.callback = callback
					return {
						Disconnect = function()
							self.callback = nil
						end,
					}
				end,
			}
			actor.Character = replacement
		end
		api.bind({
			members = function()
				return { "1" }
			end,
			snapshot = function()
				return { ["survival-coop"] = state }
			end,
			commandEpoch = function()
				return 7
			end,
			commandServer = function(_, request): { ok: boolean, reason: string?, stateVersion: number? }
				table.insert(requests, request)
				if request.action == "survival-coop:vitals-damage" then
					state.vitals.healthMilli = 0
				elseif #requests == 2 then
					return { ok = false, reason = "COMMIT_FAILED" }
				else
					assert(request.action == "survival-coop:respawn", "server respawn action")
					assert(
						request.args[1] == 100000 and request.args[2] == 50000 and request.args[3] == 0,
						"configured respawn values"
					)
					state.vitals.healthMilli = request.args[1]
				end
				return { ok = true, stateVersion = #requests }
			end,
		})
		callbacks.heartbeat()
		humanoid.Health = 0
		callbacks.heartbeat()
		assert(state.vitals.healthMilli == 0 and loaded == 0, "external death committed first")
		callbacks.heartbeat()
		assert(loaded == 0, "unconfirmed respawn never reloads character")
		-- The retained respawn head is paced: the retry waits for the injected interval.
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		assert(requests[2] == requests[3] and requests[3].sessionEpoch == 7, "retry retains exact fenced envelope")
		assert(loaded == 1 and actor.RespawnLocation == spawn, "automatic spawn after durable success")
		callbacks.heartbeat()
		callbacks.health(0)
		callbacks.heartbeat()
		assert(#requests == 3 and loaded == 1, "old character signals cannot damage replacement or repeat respawn")
		api.destroy()
		world:Destroy()
	end,
	["deferred health signals do not echo authored health as damage"] = function()
		local module, _, world, _, _, spawn, _, callbacks, humanoid = fixture()
		local api = module.new({
			content = { structures = {} },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local state = { vitals = { healthMilli = 100000 } }
		local requests = {}
		api.bind({
			members = function()
				return { "1" }
			end,
			snapshot = function()
				return { ["survival-coop"] = state }
			end,
			commandEpoch = function()
				return 7
			end,
			commandServer = function(_, request)
				table.insert(requests, request)
				state.vitals.healthMilli -= request.args[1]
				return { ok = true, stateVersion = #requests }
			end,
		})
		local function flush()
			local events = assert(deferredHealth, "deferred event queue enabled")
			deferredHealth = {}
			for _, deliver in events do
				deliver()
			end
		end
		deferredHealth = {}
		callbacks.heartbeat()
		humanoid.Health = 90
		-- A Heartbeat can project durable health before the damage signal resumes.
		callbacks.heartbeat()
		flush()
		callbacks.heartbeat()
		flush()
		callbacks.heartbeat()
		flush()
		assert(#requests == 1 and state.vitals.healthMilli == 90000, "only actual external damage is committed")
		assert(humanoid.Health == 90, "authored correction cannot feed back into damage")
		deferredHealth = nil
		api.destroy()
		world:Destroy()
	end,
	["node display accepts confirmed versions and cleanup removes only owned metadata"] = function()
		local module, services, world, _, _, spawn = fixture()
		local api = module.new({
			content = { structures = {}, nodes = { { id = "wood" } } },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local part = roblox.Instance.new("Part")
		part.Parent, part.Anchored = world, true
		part:SetAttribute("Unrelated", "preserved")
		api.registerNode(part, "wood-1", "wood", 0, "map-v1")
		assert(not pcall(api.registerNode, part, "wood-2", "wood", 0, "map-v1"), "duplicate instance refused")
		local function publish(version, charges)
			api.publishNodes({
				worldRevision = "map-v1",
				version = version,
				nodes = {
					["wood-1"] = { id = "wood-1", catalogId = "wood", charges = charges },
				},
			})
		end
		publish(2, 0)
		assert(part:GetAttribute("ForgeNodeVersion") == 2, "confirmed version displayed")
		assert(part:GetAttribute("ForgeNodeDepleted") == true, "depletion displayed")
		publish(1, 3)
		assert(part:GetAttribute("ForgeNodeCount") == 0, "older snapshot cannot refill display")
		publish(3, 3)
		assert(part:GetAttribute("ForgeNodeDepleted") == false, "confirmed respawn displayed")
		api.destroy()
		assert(not services.CollectionService:HasTag(part, "ForgeSurvivalNode"), "owned tag removed")
		assert(part:GetAttribute("ForgeNodeId") == nil, "owned identity removed")
		assert(part:GetAttribute("ForgeNodeCount") == nil, "owned display removed")
		assert(part:GetAttribute("Unrelated") == "preserved", "unrelated metadata preserved")
		world:Destroy()
	end,
	["world ports use registered canonical stations root positions and raycast obstruction"] = function()
		local module, services, world, _, root, spawn = fixture()
		-- Lune Instances do not implement Workspace.Raycast. Bind the real Folder
		-- method through the runtime method registry instead of inventing reachability.
		services.Workspace = world
		local blocked = false
		raycastHandler = function(_, _, _, params)
			local filtered = params.FilterDescendantsInstances
			assert(#filtered == 2 and filtered[1] == root.Parent, "own character excluded once")
			assert(filtered[2].Name == "Tribemate", "tribemate character never blocks reach")
			return if blocked then { Instance = root } else nil
		end
		-- This spec never exercises bounds queries; a stale handler from another
		-- spec must not answer for it.
		boundsHandler = nil
		ownFolderWorldMethods()
		local api = module.new({
			content = { structures = { { id = "campfire", station = true }, { id = "bench", station = true } } },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 12,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local fire = roblox.Instance.new("Part")
		fire.Parent, fire.Anchored, fire.Position = world, true, roblox.Vector3.new(12, 0, 0)
		api.registerStation(fire, "fire-1", "campfire")
		assert(api.services.survivalSpatial.campfire("1", "fire-1").reachable, "inclusive twelve studs")
		fire.Position = roblox.Vector3.new(13, 0, 0)
		assert(not api.services.survivalSpatial.campfire("1", "fire-1").reachable, "out of range")
		fire.Position = roblox.Vector3.new(10, 0, 0)
		blocked = true
		assert(not api.services.survivalSpatial.campfire("1", "fire-1").reachable, "obstruction denies")
		blocked = false
		assert(api.services.survivalSpatial.station("1", "unregistered") == nil, "no fabricated station")
		fire.Size, fire.Position = roblox.Vector3.new(4, 2, 3), roblox.Vector3.new(-32, 2, -4)
		root.Position = roblox.Vector3.new(-32.08, 7.83, -8.45)
		assert(api.services.survivalSpatial.station("1", "fire-1").reachable, "Studio workbench coordinates in reach")
		fire.Position, root.Position = roblox.Vector3.new(-48, 2, -4), roblox.Vector3.new(-46.779, 7.130, -8.345)
		assert(api.services.survivalSpatial.campfire("1", "fire-1").reachable, "Studio campfire coordinates in reach")
		root.Position = roblox.Vector3.new(0, 0, 0)
		fire:SetAttribute("ForgeStationKind", "unknown")
		assert(api.services.survivalSpatial.station("1", "fire-1") == nil, "catalog mismatch denies")
		local position = api.services.survivalDeath.position("1")
		assert(position.x == 0 and position.y == 0 and position.z == 0, "actual root position")
		assert(api.services.survivalDeath.position("2") == nil, "missing player")
		assert(not api.services.survivalDeath.reachable("1", { x = 0 / 0, y = 0, z = 0 }), "nonfinite bundle position")
		assert(api.services.survivalDeath.worldRevision == "map-v1", "pinned revision")
		api.destroy()
		world:Destroy()
	end,
	["engine events preserve request identity suppress health feedback and enforce equipment ownership"] = function()
		local module, _, world, character, root, spawn, actor, callbacks, humanoid, advance = fixture()
		local api = module.new({
			content = {
				structures = {},
				items = { { id = "axe", name = "Axe", tags = { "tool" }, maxDurabilityMilli = 1000 } },
			},
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local state: any = {
			speedMultiplierMilli = 700,
			vitalsMovementMilli = 800,
			vitals = { healthMilli = 90000, resting = true },
			inventory = {
				bag = {
					items = { axe = { quantity = 1, catalogId = "axe", durabilityMilli = 1000 } },
					reservations = {},
				},
			},
		}
		local requests: { any } = {}
		local failures = { "COMMIT_FAILED", "STALE_PERSONAL_REVISION", "COMMAND_PENDING", "raw backend unavailable" }
		api.bind({
			members = function()
				return { "1" }
			end,
			snapshot = function()
				local projection = table.clone(state)
				projection.inventory = { bag = { items = { staleSnapshotItem = { quantity = 1 } } } }
				return { ["survival-coop"] = projection }
			end,
			personalTransfer = function(id)
				assert(id == "1", "authenticated personal owner")
				return {
					profile = function()
						return { data = { envelope = { genres = { ["survival-coop"] = { data = state } } } } }
					end,
				}
			end,
			commandEpoch = function()
				return 7
			end,
			commandServer = function(_, request): any
				table.insert(requests, request)
				if #requests <= #failures then
					return { ok = false, reason = failures[#requests] }
				end
				if request.action == "survival-coop:rest-stop" then
					state.vitals.resting = false
				end
				if request.action == "survival-coop:vitals-damage" then
					state.vitals.healthMilli -= request.args[1]
				end
				return { ok = true, stateVersion = 1 }
			end,
		})
		callbacks.heartbeat()
		assert(math.abs(humanoid.WalkSpeed - 8.96) < 0.0001, "both domain multipliers applied")
		assert(#requests == 0 and humanoid.Health == 90, "authoritative write does not enqueue damage")
		root.Position = roblox.Vector3.new(1, 0, 0)
		for index = 1, 5 do
			callbacks.heartbeat()
			assert(requests[index] == requests[1], "every transient preserves exact request envelope")
			-- A paced retry is admitted only after the injected interval elapses.
			advance(module.RETRY_INTERVAL_SECONDS)
		end
		assert(#requests == 5, "terminal stateVersion ends retry")
		assert(
			requests[1].action == "survival-coop:rest-stop" and not state.vitals.resting,
			"actual root movement stops rest"
		)
		humanoid.Health = 80
		callbacks.health(80)
		callbacks.heartbeat()
		assert(
			#requests == 6 and requests[6].args[1] == 10000 and state.vitals.healthMilli == 80000,
			"external damage command"
		)
		callbacks.heartbeat()
		assert(#requests == 6, "no health feedback loop")
		local tool = roblox.Instance.new("Tool")
		tool.Parent = character
		tool:SetAttribute("itemId", "forged")
		api.registerTool(tool, "1", "axe")
		assert(api.services.survivalDeath.equipment("1").axe, "registered actual equip retained")
		assert(not api.services.survivalDeath.equipment("1").forged, "client attribute not identity")
		state.inventory.bag.items.axe = nil
		assert(next(api.services.survivalDeath.equipment("1")) == nil, "ownership rechecked")
		local loaded = 0
		actor.LoadCharacterAsync = function()
			loaded += 1
		end
		assert(
			api.respawn("1", "respawn-one").ok and loaded == 1 and actor.RespawnLocation == spawn,
			"server spawn destination"
		)
		assert(requests[7].requestId == "respawn-one", "caller retains respawn identity")
		api.destroy()
		assert(callbacks.heartbeat == nil and callbacks.health == nil, "connections removed")
		world:Destroy()
	end,
	["a failed durable attempt retries only at the injected retry interval"] = function()
		local module, _, world, _, root, spawn, _, callbacks, _, advance = fixture()
		local api = module.new({
			content = { structures = {} },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local state: any = { vitals = { healthMilli = 100000, resting = true } }
		local attempts: { any } = {}
		api.bind({
			members = function()
				return { "1" }
			end,
			snapshot = function()
				return { ["survival-coop"] = state }
			end,
			commandEpoch = function()
				return 7
			end,
			commandServer = function(_, request): any
				table.insert(attempts, request)
				return { ok = false, reason = "LOCAL_TRANSPORT_UNAVAILABLE" }
			end,
		})
		callbacks.heartbeat()
		root.Position = roblox.Vector3.new(1, 0, 0)
		callbacks.heartbeat()
		assert(#attempts == 1 and attempts[1].action == "survival-coop:rest-stop", "the first attempt fails once")
		for _ = 1, 120 do
			callbacks.heartbeat()
		end
		assert(#attempts == 1, "heartbeats before the retry interval cause no new attempt")
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		assert(#attempts == 2, "the eligible time admits exactly one retry")
		assert(attempts[2] == attempts[1] and attempts[2].sessionEpoch == 7, "retry retains the exact queued head")
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		assert(#attempts == 3, "each elapsed interval admits exactly one retry")
		api.destroy()
		world:Destroy()
	end,
	["a confirmed retry drains the same queued head and resumes projection"] = function()
		local module, _, world, _, root, spawn, _, callbacks, humanoid, advance = fixture()
		local api = module.new({
			content = { structures = {} },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local state: any = { vitals = { healthMilli = 90000, resting = true } }
		local attempts: { any } = {}
		local confirmed = false
		api.bind({
			members = function()
				return { "1" }
			end,
			snapshot = function()
				return { ["survival-coop"] = state }
			end,
			commandEpoch = function()
				return 7
			end,
			commandServer = function(_, request): any
				table.insert(attempts, request)
				if not confirmed then
					confirmed = true
					return { ok = false, reason = "LOCAL_TRANSPORT_UNAVAILABLE" }
				end
				state.vitals.resting = false
				return { ok = true, stateVersion = 1 }
			end,
		})
		callbacks.heartbeat()
		assert(humanoid.Health == 90, "initial durable projection")
		state.vitals.healthMilli = 80000
		root.Position = roblox.Vector3.new(1, 0, 0)
		callbacks.heartbeat()
		assert(#attempts == 1 and humanoid.Health == 90, "a queued head holds the stale projection")
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		assert(#attempts == 2 and attempts[2] == attempts[1], "the retry drains the same queued head")
		assert(humanoid.Health == 80, "a confirmed command resumes the durable projection")
		callbacks.heartbeat()
		assert(#attempts == 2, "a drained head is never replayed")
		api.destroy()
		world:Destroy()
	end,
	["an in-flight durable attempt blocks a reentrant heartbeat"] = function()
		local module, _, world, _, root, spawn, _, callbacks, _, advance = fixture()
		local api = module.new({
			content = { structures = {} },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local state: any = { vitals = { healthMilli = 100000, resting = true } }
		local attempts = 0
		local released = false
		api.bind({
			members = function()
				return { "1" }
			end,
			snapshot = function()
				return { ["survival-coop"] = state }
			end,
			commandEpoch = function()
				return 7
			end,
			commandServer = function(): any
				attempts += 1
				while not released do
					coroutine.yield()
				end
				return { ok = false, reason = "LOCAL_TRANSPORT_UNAVAILABLE" }
			end,
		})
		callbacks.heartbeat()
		root.Position = roblox.Vector3.new(1, 0, 0)
		local first = coroutine.create(function()
			callbacks.heartbeat()
		end)
		assert(coroutine.resume(first), "the attempt parks on the in-flight backend call")
		assert(attempts == 1, "the first attempt reached the backend")
		callbacks.heartbeat()
		assert(attempts == 1, "a reentrant heartbeat cannot start a second concurrent attempt")
		released = true
		assert(coroutine.resume(first))
		assert(attempts == 1 and coroutine.status(first) == "dead", "the in-flight attempt settled once")
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		assert(attempts == 2, "the paced retry is admitted after the in-flight attempt settles")
		api.destroy()
		world:Destroy()
	end,
	["a departed member's retry pacing does not survive rejoin"] = function()
		local module, _, world, _, root, spawn, _, callbacks, _, advance = fixture()
		local api = module.new({
			content = { structures = {} },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local state: any = { vitals = { healthMilli = 100000, resting = true } }
		local joined = true
		local attempts: { any } = {}
		api.bind({
			members = function()
				return if joined then { "1" } else {}
			end,
			snapshot = function()
				return { ["survival-coop"] = state }
			end,
			commandEpoch = function()
				return 7
			end,
			commandServer = function(_, request): any
				table.insert(attempts, request)
				return { ok = false, reason = "LOCAL_TRANSPORT_UNAVAILABLE" }
			end,
		})
		callbacks.heartbeat()
		root.Position = roblox.Vector3.new(1, 0, 0)
		callbacks.heartbeat()
		assert(#attempts == 1, "the queued command failed once")
		joined = false
		callbacks.heartbeat()
		assert(#attempts == 1, "a departed member is not attempted")
		joined = true
		callbacks.heartbeat()
		-- Scoped to pacing state for ONE session's retained head: this does not exercise a
		-- new session identity or any cross-session replay, so it claims nothing there.
		assert(#attempts == 2, "rejoin does not inherit the departed member's pacing")
		assert(attempts[2] == attempts[1], "the same session's queue head keeps its identity")
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		assert(#attempts == 3, "pacing restarts from the rejoined member's own retry")
		api.destroy()
		world:Destroy()
	end,
	["an unavailable respawn epoch retains and paces the death reconciliation"] = function()
		local module, _, world, _, _, spawn, actor, callbacks, _, advance = fixture()
		local api = module.new({
			content = { structures = {} },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local state: any = { vitals = { healthMilli = 0 } }
		local available = false
		local epochCalls = 0
		local requests: { any } = {}
		local loads = 0
		actor.LoadCharacterAsync = function()
			loads += 1
		end
		api.bind({
			members = function()
				return { "1" }
			end,
			snapshot = function()
				return { ["survival-coop"] = state }
			end,
			commandEpoch = function(_, action)
				if action == "survival-coop:respawn" then
					epochCalls += 1
				end
				return if available then 7 else nil
			end,
			commandServer = function(_, request): any
				table.insert(requests, request)
				state.vitals.healthMilli = request.args[1]
				return { ok = true, stateVersion = #requests }
			end,
		})
		for _ = 1, 120 do
			callbacks.heartbeat()
		end
		assert(#requests == 0, "no command is attempted without an epoch")
		-- The death is retained, so the epoch is resolved once and then paced. Dropping
		-- it instead re-derives the respawn on every frame, which is the storm shape.
		assert(epochCalls <= 3, "an unavailable epoch is not re-resolved every frame")
		available = true
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		assert(#requests == 1 and requests[1].action == "survival-coop:respawn", "the retained death reconciles")
		assert(loads == 1, "the retained respawn reloads the character")
		assert(state.vitals.healthMilli == 100000, "durable health is restored by the retained command")
		api.destroy()
		world:Destroy()
	end,
	["two death and respawn cycles commit with distinct request identity"] = function()
		local module, _, world, _, _, spawn, actor, callbacks = fixture()
		local api = module.new({
			content = { structures = {} },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local state: any = { vitals = { healthMilli = 100000 } }
		local requests: { any } = {}
		local loads = 0
		actor.LoadCharacterAsync = function()
			loads += 1
		end
		api.bind({
			members = function()
				return { "1" }
			end,
			snapshot = function()
				return { ["survival-coop"] = state }
			end,
			commandEpoch = function()
				return 7
			end,
			commandServer = function(_, request): any
				table.insert(requests, request)
				state.vitals.healthMilli = request.args[1]
				return { ok = true, stateVersion = #requests }
			end,
		})
		state.vitals.healthMilli = 0
		callbacks.heartbeat()
		assert(#requests == 1 and state.vitals.healthMilli == 100000, "first death reconciles")
		state.vitals.healthMilli = 0
		callbacks.heartbeat()
		assert(#requests == 2 and state.vitals.healthMilli == 100000, "second death reconciles")
		-- A retained durable outcome is replayed by requestId for a whole window, so a
		-- fixed identity would turn the second death into a false success.
		assert(requests[1].requestId ~= requests[2].requestId, "each death carries its own request identity")
		assert(loads == 2, "both deaths reload the character")
		api.destroy()
		world:Destroy()
	end,
	["a stale window re-enqueue is paced rather than attempted every frame"] = function()
		local module, _, world, _, _, spawn, _, callbacks, _, advance = fixture()
		local api = module.new({
			content = { structures = {} },
			worldRevision = "map-v1",
			spawn = spawn,
			carriedContainer = "bag",
			reachStuds = 8,
			baseWalkSpeed = 16,
			respawnValues = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 },
		})
		local state: any = { vitals = { healthMilli = 0 } }
		local attempts: { any } = {}
		api.bind({
			members = function()
				return { "1" }
			end,
			snapshot = function()
				return { ["survival-coop"] = state }
			end,
			commandEpoch = function()
				return 7
			end,
			commandServer = function(_, request): any
				table.insert(attempts, request)
				return { ok = false, reason = "REQUEST_EXPIRED" }
			end,
		})
		callbacks.heartbeat()
		assert(#attempts == 1, "the retained death is attempted once")
		for _ = 1, 120 do
			callbacks.heartbeat()
		end
		-- REQUEST_EXPIRED drops the head and the death re-enqueues with a fresh
		-- identity, so the re-enqueued attempt must be paced.
		assert(#attempts == 1, "a stale window does not re-attempt every frame")
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		assert(#attempts == 2, "the paced re-enqueue is attempted once")
		assert(attempts[2].requestId ~= attempts[1].requestId, "a stale window re-enqueues a fresh identity")
		advance(module.RETRY_INTERVAL_SECONDS)
		callbacks.heartbeat()
		assert(#attempts == 3, "each elapsed interval admits exactly one attempt")
		api.destroy()
		world:Destroy()
	end,
}
