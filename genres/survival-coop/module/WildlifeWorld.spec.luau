--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local Wildlife = require("./Wildlife")
local Content = require("../../../core/domain/survival/Content")
local Herd = require("./Herd")
local DinosaurMotion = luau.load(fs.readFile("genres/survival-coop/module/DinosaurMotion.luau"), {
	environment = {
		Instance = roblox.Instance,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
	},
})()
local function signal()
	local callbacks = {}
	return {
		Connect = function(_, callback)
			callbacks[callback] = true
			return {
				Disconnect = function()
					callbacks[callback] = nil
				end,
			}
		end,
		fire = function(...)
			for callback in table.clone(callbacks) do
				callback(...)
			end
		end,
		count = function()
			local n = 0
			for _ in callbacks do
				n += 1
			end
			return n
		end,
	}
end
-- This spec file shares one Lune mock across its cases, so the engine methods below are installed
-- exactly once, here, and read the per-case state through `active`. Registering them per case would
-- either raise on re-registration or - worse - let a case silently inherit another case's closures,
-- and wrapping that registration in a blanket pcall would hide a real failure in exactly that path.
local active: any = { owners = {}, moved = {}, finished = nil, obstacle = false, world = nil, surface = nil }
local mocksInstalled = false
local function installMocks()
	if mocksInstalled then
		return
	end
	mocksInstalled = true
	roblox.implementMethod("BasePart", "SetNetworkOwner", function(part, owner)
		assert(owner == nil, "server owns physics")
		active.owners[part] = true
	end)
	roblox.implementMethod("Humanoid", "MoveTo", function(_, goal)
		table.insert(active.moved, goal)
	end)
	roblox.implementProperty("Humanoid", "MoveToFinished", function()
		return active.finished
	end)
	roblox.implementMethod("Workspace", "Raycast", function(_, origin, direction, params): any
		-- `surface`: terrain at a land height and a water surface above it (the shallows).
		local surface = active.surface
		if params and params.FilterType == roblox.Enum.RaycastFilterType.Include then
			if not surface then
				return nil -- no terrain in this case
			end
			local y = if params.IgnoreWater then surface.land else math.max(surface.land, surface.water)
			local t = (y - origin.Y) / direction.Y
			return if t >= 0 and t <= 1
				then { Instance = active.world, Position = roblox.Vector3.new(origin.X, y, origin.Z) }
				else nil
		end
		return if active.obstacle then { Instance = active.world } else nil
	end)
end

return {
	["engine binding reads physical positions fences stale paths and disposes signals"] = function()
		local heartbeat, finished, blocked = signal(), signal(), signal()
		active.moved, active.owners = {}, {}
		active.finished, active.obstacle, active.surface = finished, false, nil
		installMocks()
		local computations = 0
		local world = roblox.Instance.new("Workspace")
		active.world = world
		local function rig(x: number)
			local model = roblox.Instance.new("Model")
			model.Parent = world
			local root = roblox.Instance.new("Part")
			root.Name, root.Parent, root.Position = "HumanoidRootPart", model, roblox.Vector3.new(x, 0, 0)
			root.AssemblyLinearVelocity = roblox.Vector3.zero
			local humanoid = roblox.Instance.new("Humanoid")
			humanoid.Parent = model
			return model, root
		end
		local npc, npcRoot = rig(0)
		local character, actorRoot = rig(8)
		local actor = { UserId = 1, Character = character }
		local paths = {
			CreatePath = function()
				return {
					Status = roblox.Enum.PathStatus.Success,
					Blocked = blocked,
					ComputeAsync = function()
						computations += 1
						coroutine.yield()
					end,
					GetWaypoints = function()
						return { { Position = npcRoot.Position }, { Position = actorRoot.Position } }
					end,
				}
			end,
		}
		local threads = {}
		local services = {
			Workspace = world,
			Players = {
				GetPlayerByUserId = function(_, id)
					return if id == 1 then actor else nil
				end,
				GetPlayers = function()
					return { actor }
				end,
			},
			RunService = {
				Heartbeat = heartbeat,
				IsStudio = function()
					return true
				end,
			},
			PathfindingService = paths,
		}
		local module = luau.load(fs.readFile("genres/survival-coop/module/WildlifeWorld.luau"), {
			environment = {
				game = {
					GetService = function(_, name)
						return services[name]
					end,
				},
				require = function(name)
					return if name == "./Wildlife"
						then Wildlife
						elseif name == "./DinosaurMotion" then DinosaurMotion
						else Content
				end,
				Vector3 = roblox.Vector3,
				Enum = roblox.Enum,
				RaycastParams = {
					new = function()
						return {}
					end,
				},
				task = {
					spawn = function(callback)
						local thread = coroutine.create(callback)
						table.insert(threads, thread)
						assert(coroutine.resume(thread), "path computation starts")
					end,
				},
			},
		})()
		local content, errors = Content.canonicalize({
			survival_content = 1,
			rules = Content.RULES,
			limits = Content.DEFAULT_LIMITS,
			items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
			wildlife = { { id = "hunter", behavior = "hunter" } },
		})
		assert(content, table.concat(errors, "; "))
		local now, damage = 0, 0
		local observations: { any } = {}
		local api = module.new({
			observePath = function(event: any)
				assert(table.isfrozen(event) and table.isfrozen(event.position), "immutable observation")
				table.insert(observations, event)
			end,
			content = content,
			catalog = { species = { hunter = { healthMilli = 40000, damageMilli = 10000, drops = {} } }, weapons = {} },
			maximum = 1,
			nowMillis = function()
				return now
			end,
			alive = function()
				return true
			end,
			equipment = function()
				return {}
			end,
			damage = function()
				damage += 1
			end,
		})
		api.register(npc, "h1", "hunter")
		local probe = api.probeCapacity()
		assert(
			probe.boundary.kind == "existing-census" and probe.boundary.census.ids[1] == "h1",
			"existing full boundary"
		)
		assert(probe.boundary.accepted == nil and #probe.operations == 1, "census is not a registration")
		assert(probe.limit == 1 and probe.attempts == 1 and probe.retryLimit == 0, "loaded cap and bounded attempt")
		assert(not probe.refusal.accepted and probe.refusal.attemptedCount == 2, "real register rejects plus one")
		assert(string.find(probe.refusal.reason, "NPC_BUDGET_OR_ID", 1, true), "actual refusal reason")
		assert(probe.before.count == probe.after.count and #probe.cleanup.remaining == 0, "owned probe rigs removed")
		assert(active.owners[npcRoot] and not pcall(api.register, npc, "h2", "hunter"), "budget and server ownership")
		heartbeat.fire()
		now = 1000
		heartbeat.fire()
		assert(computations == 1 and coroutine.status(threads[1]) == "suspended", "exact path barrier")
		assert(observations[1].phase == "requested", "subscription precedes path completion")
		actorRoot.Position = roblox.Vector3.new(11, 0, 0)
		now = 1001
		heartbeat.fire()
		assert(computations == 1, "one in flight path per NPC")
		assert(coroutine.resume(threads[1]), "resolve path event")
		assert(active.moved[#active.moved].X == 11, "resolved path drives actual Humanoid movement")
		blocked.fire(2)
		now = 1002
		heartbeat.fire()
		assert(api.snapshot("h1").mode == "idle" and damage == 0, "lost path idles without hit")
		assert(
			observations[2].status == "Success" and observations[3].status == "Blocked",
			'observations[2].status == "Success" and observations[3].status == "Blocked"'
		)
		assert(
			observations[4].phase == "consumed" and observations[5].phase == "refused",
			'observations[4].phase == "consumed" and observations[5].phase == "refused"'
		)
		for _, event in observations do
			assert(event.serial == observations[1].serial, "cancel cannot replace failed request identity")
		end
		local access = api.access("1", "h1")
		assert(
			access.position.x == 11 and access.targetPosition.x == 0 and access.lineOfSight,
			"physical root positions"
		)
		active.obstacle = true
		assert(not api.access("1", "h1").lineOfSight, "engine ray blocks")
		local confirmed = api.snapshot("h1")
		confirmed.healthMilli, confirmed.version = 30000, confirmed.version + 1
		now = 1100
		api.publish(confirmed)
		assert(
			npc:GetAttribute("ForgeWildlifeFeedback") == "hurt" and damage == 0,
			"published hurt does not enqueue damage"
		)
		heartbeat.fire()
		assert(npc:GetAttribute("ForgeWildlifeKiller") == nil, "a living creature has no carcass owner")
		-- p134 v53: the killer's client marks the carcass and routes its tap from the published kill.
		local killed = api.snapshot("h1")
		killed.healthMilli, killed.version, killed.killer, killed.killedAt = 0, killed.version + 1, "1", 1100
		api.publish(killed)
		heartbeat.fire()
		assert(npc:GetAttribute("ForgeWildlifeHealthMilli") == 0, "dead published")
		-- The client's death fall (CreaturePose dead -> DinosaurRig/BonePose roll onto the flank) keys on it.
		assert(npc:GetAttribute("ForgeWildlifeState") == "dead", "the dead state drives the death fall")
		assert(
			npc:GetAttribute("ForgeWildlifeKiller") == "1" and npc:GetAttribute("ForgeWildlifeKilledAt") == 1100,
			"the carcass owner and kill clock are published"
		)
		npc.Parent = nil
		heartbeat.fire()
		assert(
			api.snapshot("h1") == nil and not npc:FindFirstChild("WildlifeFeedback"),
			"removed rig releases controller"
		)
		assert(npc:GetAttribute("ForgeWildlifeId") == nil, "removed rig clears world attributes")
		assert(pcall(api.publish, confirmed), "publish for a removed rig is skipped, not an error")
		npc.Parent = world
		api.register(npc, "h2", "hunter")
		assert(npc:FindFirstChild("WildlifeFeedback"), "removed rig frees budget")
		api.destroy()
		assert(heartbeat.count() == 0 and finished.count() == 0 and blocked.count() == 0, "all signals disposed")
		assert(
			npcRoot.Position.X == 0 and npc:GetAttribute("ForgeWildlifeId") == nil,
			"no teleport and attributes removed"
		)
		assert(not npc:FindFirstChild("WildlifeFeedback"), "world destroys motion feedback")
	end,
	-- A rig is created above the floor and falls onto it. Home must be the resting root coordinate at the
	-- spawn location: a home taken from the placement spends the domain's own one-stud arrival on a
	-- permanent vertical error, so a return that ends at the resting height never reports idle. This
	-- drives the real spawn fall and the real return, and never restates the attribute to make itself pass.
	["home settles to the resting root so a return at rest reports idle"] = function()
		local heartbeat = signal()
		-- The shared mock is installed once for the whole file; this case only publishes its own state,
		-- so no registration is attempted and no error can be swallowed here.
		active.moved, active.owners = {}, {}
		active.finished, active.obstacle, active.surface = signal(), false, nil
		installMocks()
		local world = roblox.Instance.new("Workspace")
		active.world = world
		local function rig(position: any)
			local model = roblox.Instance.new("Model")
			model.Parent = world
			local root = roblox.Instance.new("Part")
			root.Name, root.Parent, root.Position = "HumanoidRootPart", model, position
			root.AssemblyLinearVelocity = roblox.Vector3.zero
			local humanoid = roblox.Instance.new("Humanoid")
			humanoid.Parent = model
			return model, root
		end
		local npc, npcRoot = rig(roblox.Vector3.new(0, 4, 0))
		local character = rig(roblox.Vector3.new(60, 3, 0))
		local actor = { UserId = 1, Character = character }
		local services = {
			Workspace = world,
			Players = {
				GetPlayerByUserId = function(_, id)
					return if id == 1 then actor else nil
				end,
				GetPlayers = function()
					return { actor }
				end,
			},
			RunService = {
				Heartbeat = heartbeat,
				IsStudio = function()
					return true
				end,
			},
			PathfindingService = {
				CreatePath = function()
					return {
						Status = roblox.Enum.PathStatus.Success,
						Blocked = signal(),
						ComputeAsync = function() end,
						GetWaypoints = function()
							return { { Position = npcRoot.Position }, { Position = npcRoot.Position } }
						end,
					}
				end,
			},
		}
		local module = luau.load(fs.readFile("genres/survival-coop/module/WildlifeWorld.luau"), {
			environment = {
				game = {
					GetService = function(_, name)
						return services[name]
					end,
				},
				require = function(name)
					return if name == "./Wildlife"
						then Wildlife
						elseif name == "./DinosaurMotion" then DinosaurMotion
						else Content
				end,
				Vector3 = roblox.Vector3,
				Enum = roblox.Enum,
				RaycastParams = {
					new = function()
						return {}
					end,
				},
				task = {
					spawn = function(callback)
						assert(coroutine.resume(coroutine.create(callback)), "path computation starts")
					end,
				},
			},
		})()
		local content, errors = Content.canonicalize({
			survival_content = 1,
			rules = Content.RULES,
			limits = Content.DEFAULT_LIMITS,
			items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
			wildlife = { { id = "hunter", behavior = "hunter" } },
		})
		assert(content, table.concat(errors, "; "))
		local api = module.new({
			content = content,
			catalog = { species = { hunter = { healthMilli = 40000, damageMilli = 10000, drops = {} } }, weapons = {} },
			maximum = 1,
			nowMillis = function()
				return 0
			end,
			alive = function()
				return true
			end,
			equipment = function()
				return {}
			end,
			damage = function() end,
		})
		api.register(npc, "h1", "hunter")
		-- Frame 1: the rig is falling, so its placement is not yet the authoritative home.
		npcRoot.AssemblyLinearVelocity = roblox.Vector3.new(0, -10, 0)
		heartbeat.fire()
		local placed = npc:GetAttribute("ForgeWildlifeHome")
		assert(placed.X == 0 and placed.Y == 4 and placed.Z == 0, "placement home while falling")
		-- Frame 2: still falling, and drifting horizontally. Home must not follow the drift.
		npcRoot.Position = roblox.Vector3.new(7, 3.5, 2)
		npcRoot.AssemblyLinearVelocity = roblox.Vector3.new(0, -5, 0)
		heartbeat.fire()
		local drifting = api.snapshot("h1")
		assert(drifting.home.x == 0 and drifting.home.z == 0, "drift before landing does not move home")
		-- Frame 3: it lands one stud below the spawn and stops falling. Only the height is taken from the
		-- root, so home is the spawn location at its resting height.
		npcRoot.Position = roblox.Vector3.new(7, 3, 2)
		npcRoot.AssemblyLinearVelocity = roblox.Vector3.zero
		heartbeat.fire()
		local settled = api.snapshot("h1")
		assert(settled.home.x == 0 and settled.home.y == 3 and settled.home.z == 0, "home is the resting root")
		local published = npc:GetAttribute("ForgeWildlifeHome")
		assert(published.Y == 3, "the published home is the resting coordinate")
		-- Beyond the leash: the return begins, aimed at the settled home.
		npcRoot.Position = roblox.Vector3.new(41, 3, 0)
		heartbeat.fire()
		assert(api.snapshot("h1").mode == "return", "leash escape returns home")
		-- Back at rest, half a stud off the home in X. Against the placement home that is 1.118 studs in
		-- 3D and the return can never end; against the resting home it is inside the one-stud arrival.
		npcRoot.Position = roblox.Vector3.new(0.5, 3, 0)
		heartbeat.fire()
		assert(api.snapshot("h1").mode == "idle", "return at the resting height reports idle")
		api.destroy()
	end,
	-- QA-WILD-01: the world budget is 32 NPCs; the 33rd spawn request is refused and a budget above
	-- 32 cannot be configured. The refusal is the real register gate, not a restated constant.
	["thirty third NPC spawn is refused and the cap cannot be raised"] = function()
		local heartbeat = signal()
		active.moved, active.owners = {}, {}
		active.finished, active.obstacle, active.surface = signal(), false, nil
		installMocks()
		local world = roblox.Instance.new("Workspace")
		active.world = world
		local function rig(x: number)
			local model = roblox.Instance.new("Model")
			model.Parent = world
			local root = roblox.Instance.new("Part")
			root.Name, root.Parent, root.Position = "HumanoidRootPart", model, roblox.Vector3.new(x, 0, 0)
			root.AssemblyLinearVelocity = roblox.Vector3.zero
			local humanoid = roblox.Instance.new("Humanoid")
			humanoid.Parent = model
			return model
		end
		local services = {
			Workspace = world,
			Players = {
				GetPlayerByUserId = function()
					return nil
				end,
				GetPlayers = function()
					return {}
				end,
			},
			RunService = {
				Heartbeat = heartbeat,
				IsStudio = function()
					return true
				end,
			},
			PathfindingService = {},
		}
		local module = luau.load(fs.readFile("genres/survival-coop/module/WildlifeWorld.luau"), {
			environment = {
				game = {
					GetService = function(_, name)
						return services[name]
					end,
				},
				require = function(name)
					return if name == "./Wildlife"
						then Wildlife
						elseif name == "./DinosaurMotion" then DinosaurMotion
						else Content
				end,
				Vector3 = roblox.Vector3,
				Enum = roblox.Enum,
				RaycastParams = {
					new = function()
						return {}
					end,
				},
				task = { spawn = function() end },
			},
		})()
		local content, errors = Content.canonicalize({
			survival_content = 1,
			rules = Content.RULES,
			limits = Content.DEFAULT_LIMITS,
			items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
			wildlife = { { id = "hunter", behavior = "hunter" } },
		})
		assert(content, table.concat(errors, "; "))
		local function config(maximum: number): any
			return {
				content = content,
				catalog = {
					species = { hunter = { healthMilli = 40000, damageMilli = 10000, drops = {} } },
					weapons = {},
				},
				maximum = maximum,
				nowMillis = function()
					return 0
				end,
				alive = function()
					return true
				end,
				equipment = function()
					return {}
				end,
				damage = function() end,
			}
		end
		local raised, reason = pcall(module.new, config(33))
		assert(not raised and string.find(tostring(reason), "INVALID_NPC_BUDGET", 1, true), "cap above 32 refused")
		local api = module.new(config(32))
		for index = 1, 32 do
			assert(api.register(rig(index * 10), "npc-" .. index, "hunter"), "within budget")
		end
		local accepted, refusal = pcall(api.register, rig(400), "npc-33", "hunter")
		assert(not accepted and string.find(tostring(refusal), "NPC_BUDGET_OR_ID", 1, true), "33rd spawn refused")
		assert(api.snapshot("npc-33") == nil and api.snapshot("npc-32") ~= nil, "census unchanged by refusal")
		-- With no observer the world hibernates every NPC instead of perceiving.
		heartbeat.fire()
		assert(api.snapshot("npc-1").mode == "hibernate", "unobserved NPCs hibernate")
		assert(api.provoke("npc-1", "7") and not api.provoke("missing", "7"), "provoke reaches only real NPCs")
		api.destroy()
	end,
	-- A durable tame capture takes the rig out of the world (no access, no step) and the Heartbeat
	-- returns it home once the window ends. Republishing the same capture never re-hides it.
	["a captured wild leaves the world and respawns at home after its window"] = function()
		local heartbeat = signal()
		active.moved, active.owners = {}, {}
		active.finished, active.obstacle, active.surface = signal(), false, nil
		installMocks()
		local world = roblox.Instance.new("Workspace")
		active.world = world
		local folder = roblox.Instance.new("Folder")
		folder.Parent = world
		local npc = roblox.Instance.new("Model")
		npc.Parent = folder
		local npcRoot = roblox.Instance.new("Part")
		npcRoot.Name, npcRoot.Parent, npcRoot.Position = "HumanoidRootPart", npc, roblox.Vector3.new(0, 3, 0)
		npcRoot.AssemblyLinearVelocity = roblox.Vector3.zero
		roblox.Instance.new("Humanoid").Parent = npc
		local character = roblox.Instance.new("Model")
		character.Parent = world
		local actorRoot = roblox.Instance.new("Part")
		actorRoot.Name, actorRoot.Parent, actorRoot.Position =
			"HumanoidRootPart", character, roblox.Vector3.new(4, 3, 0)
		local actor = { UserId = 1, Character = character }
		local services = {
			Workspace = world,
			Players = {
				GetPlayerByUserId = function(_, id)
					return if id == 1 then actor else nil
				end,
				GetPlayers = function()
					return {}
				end,
			},
			RunService = {
				Heartbeat = heartbeat,
				IsStudio = function()
					return true
				end,
			},
			PathfindingService = {},
		}
		local module = luau.load(fs.readFile("genres/survival-coop/module/WildlifeWorld.luau"), {
			environment = {
				game = {
					GetService = function(_, name)
						return services[name]
					end,
				},
				require = function(name)
					return if name == "./Wildlife"
						then Wildlife
						elseif name == "./DinosaurMotion" then DinosaurMotion
						else Content
				end,
				Vector3 = roblox.Vector3,
				CFrame = roblox.CFrame,
				Enum = roblox.Enum,
				RaycastParams = {
					new = function()
						return {}
					end,
				},
				task = { spawn = function() end },
			},
		})()
		local content, errors = Content.canonicalize({
			survival_content = 1,
			rules = Content.RULES,
			limits = Content.DEFAULT_LIMITS,
			items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
			wildlife = { { id = "hunter", behavior = "hunter" } },
		})
		assert(content, table.concat(errors, "; "))
		local now = 0
		local api = module.new({
			content = content,
			catalog = { species = { hunter = { healthMilli = 40000, damageMilli = 10000, drops = {} } }, weapons = {} },
			maximum = 1,
			nowMillis = function()
				return now
			end,
			alive = function()
				return true
			end,
			equipment = function()
				return {}
			end,
			damage = function() end,
		})
		api.register(npc, "h1", "hunter")
		heartbeat.fire()
		assert(api.access("1", "h1") ~= nil, "present before capture")
		local captured = api.snapshot("h1")
		captured.version += 1
		captured.capturedUntil, captured.captureId = 5000, "1:c1"
		now = 100
		api.publish(captured)
		assert(npc.Parent == nil and api.access("1", "h1") == nil, "captured rig leaves the world")
		heartbeat.fire()
		assert(api.snapshot("h1") ~= nil, "a hidden rig keeps its registration (not disposed)")
		npcRoot.Position = roblox.Vector3.new(30, 3, 0)
		now = 200
		api.publish(captured)
		assert(npc.Parent == nil, "republishing the capture is a no-op")
		now = 5000
		heartbeat.fire()
		assert(npc.Parent == folder and api.access("1", "h1") ~= nil, "respawned into its folder")
		local home = api.snapshot("h1").home
		-- Lune keeps CFrame and Position as independent properties; the world moves the root by CFrame.
		local placed = npcRoot.CFrame.Position
		assert(placed.X == home.x and placed.Y == home.y and placed.Z == home.z, "respawned at home")
		assert(npc:GetAttribute("ForgeWildlifeState") ~= "captured", "live state published again")
		-- Off-island fall: far below home the creature is put back there instead of being lost.
		npcRoot.Position = roblox.Vector3.new(home.x + 40, home.y - 200, home.z)
		npcRoot.CFrame = roblox.CFrame.new(home.x + 40, home.y - 200, home.z)
		heartbeat.fire()
		local recovered = npcRoot.CFrame.Position
		assert(recovered.X == home.x and recovered.Y == home.y and recovered.Z == home.z, "fallen rig returns home")
		assert(npc.Parent == folder and api.snapshot("h1") ~= nil, "fallen rig stays registered")
		api.destroy()
	end,
	-- p134 v55 (SM-N981N): a dodo killed at the shore lay at Y -4.4 under the water line (rigs are
	-- seated on the seabed) and its carcass label never showed. A dead body is held on the surface
	-- above it; once the owner respawns it, it is a free creature at home again.
	["a body killed in the shallows rests on the water surface and a respawn frees it at home"] = function()
		local heartbeat = signal()
		active.moved, active.owners = {}, {}
		active.finished, active.obstacle = signal(), false
		installMocks()
		local world = roblox.Instance.new("Workspace")
		active.world = world
		active.surface = { land = -6, water = 0 }
		local folder = roblox.Instance.new("Folder")
		folder.Parent = world
		local npc = roblox.Instance.new("Model")
		npc.Parent = folder
		local npcRoot = roblox.Instance.new("Part")
		npcRoot.Name, npcRoot.Parent = "HumanoidRootPart", npc
		npcRoot.Size = roblox.Vector3.new(2, 2, 2)
		npcRoot.CFrame = roblox.CFrame.new(0, -4.4, 0)
		npcRoot.Position = npcRoot.CFrame.Position
		npcRoot.AssemblyLinearVelocity = roblox.Vector3.zero
		-- A leg hangs 2 studs under the root (rigs have HipHeight 0; their parts reach the ground).
		local leg = roblox.Instance.new("Part")
		leg.Name, leg.Parent, leg.Size = "Leg", npc, roblox.Vector3.new(1, 2, 1)
		leg.CFrame = roblox.CFrame.new(0, -6.4, 0)
		local humanoid = roblox.Instance.new("Humanoid")
		humanoid.Parent = npc
		local services = {
			Workspace = world,
			Players = {
				GetPlayerByUserId = function()
					return nil
				end,
				GetPlayers = function()
					return {}
				end,
			},
			RunService = {
				Heartbeat = heartbeat,
				IsStudio = function()
					return true
				end,
			},
			PathfindingService = {},
		}
		local module = luau.load(fs.readFile("genres/survival-coop/module/WildlifeWorld.luau"), {
			environment = {
				game = {
					GetService = function(_, name)
						return services[name]
					end,
				},
				require = function(name)
					return if name == "./Wildlife"
						then Wildlife
						elseif name == "./DinosaurMotion" then DinosaurMotion
						else Content
				end,
				Vector3 = roblox.Vector3,
				CFrame = roblox.CFrame,
				Enum = roblox.Enum,
				RaycastParams = {
					new = function()
						return {}
					end,
				},
				task = { spawn = function() end },
			},
		})()
		local content, errors = Content.canonicalize({
			survival_content = 1,
			rules = Content.RULES,
			limits = Content.DEFAULT_LIMITS,
			items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
			wildlife = { { id = "hunter", behavior = "hunter" } },
		})
		assert(content, table.concat(errors, "; "))
		local api = module.new({
			content = content,
			catalog = { species = { hunter = { healthMilli = 40000, damageMilli = 10000, drops = {} } }, weapons = {} },
			maximum = 1,
			nowMillis = function()
				return 0
			end,
			alive = function()
				return true
			end,
			equipment = function()
				return {}
			end,
			damage = function() end,
		})
		api.register(npc, "d1", "hunter")
		local dead = api.snapshot("d1")
		dead.version += 1
		dead.healthMilli, dead.killer, dead.killedAt = 0, "1", 100
		api.publish(dead)
		local body = npcRoot.CFrame.Position
		-- Lune does not move welded parts with the root: the leg sat 2 below the root, its foot 3 below.
		assert(
			body.Y - 3 >= -1e-6,
			string.format("the body's feet are at or above the water line, root Y %.2f", body.Y)
		)
		assert(npcRoot.Anchored, "the body is held there (no sinking back under)")
		heartbeat.fire()
		assert(npc:GetAttribute("ForgeWildlifeKiller") == "1", "the carcass is published")
		local alive = api.snapshot("d1")
		alive.version += 1
		alive.healthMilli, alive.killer, alive.killedAt = 40000, nil, nil
		api.publish(alive)
		assert(not npcRoot.Anchored, "a respawned creature is free again")
		local home = api.snapshot("d1").home
		local placed = npcRoot.CFrame.Position
		assert(placed.X == home.x and placed.Z == home.z, "respawned at home")
		assert(api.snapshot("d1").mode ~= "dead", "and alive")
		api.destroy()
	end,
	-- R09 tame lane: the onboarding dodos spawn as a herd trio. A follower worn to the capture
	-- threshold stood winded in Wildlife.step, but the world still walked it after its fleeing leader
	-- (a winded creature has no target, so it read as a calm follower) and out of the 6-stud reach.
	-- D2 v68 R08: a lone onboarding dodo (fleeOnHitStuds) bolted the moment a player walked up to
	-- target it. It now grazes until a confirmed hit, which alone (no herd) sends it off its striker.
	["a flee-on-hit grazer stays while a player walks up and bolts only on a confirmed hit"] = function()
		local heartbeat = signal()
		active.moved, active.owners = {}, {}
		active.finished, active.obstacle, active.surface = signal(), false, nil
		installMocks()
		local world = roblox.Instance.new("Workspace")
		active.world = world
		local function rig(position: any)
			local model = roblox.Instance.new("Model")
			model.Parent = world
			local root = roblox.Instance.new("Part")
			root.Name, root.Parent, root.Position = "HumanoidRootPart", model, position
			root.CFrame = roblox.CFrame.new(position)
			root.AssemblyLinearVelocity = roblox.Vector3.zero
			roblox.Instance.new("Humanoid").Parent = model
			return model, root
		end
		local dodo = rig(roblox.Vector3.new(0, 3, 0))
		local character = rig(roblox.Vector3.new(3, 3, 0))
		local actor = { UserId = 1, Character = character }
		local services = {
			Workspace = world,
			Players = {
				GetPlayerByUserId = function(_, id)
					return if id == 1 then actor else nil
				end,
				GetPlayers = function()
					return { actor }
				end,
			},
			RunService = {
				Heartbeat = heartbeat,
				IsStudio = function()
					return true
				end,
			},
			PathfindingService = {},
		}
		local module = luau.load(fs.readFile("genres/survival-coop/module/WildlifeWorld.luau"), {
			environment = {
				game = {
					GetService = function(_, name)
						return services[name]
					end,
				},
				require = function(name)
					return if name == "./Wildlife"
						then Wildlife
						elseif name == "./DinosaurMotion" then DinosaurMotion
						elseif name == "./Herd" then Herd
						else Content
				end,
				Vector3 = roblox.Vector3,
				CFrame = roblox.CFrame,
				Enum = roblox.Enum,
				RaycastParams = {
					new = function()
						return {}
					end,
				},
				task = { spawn = function() end },
			},
		})()
		local content, errors = Content.canonicalize({
			survival_content = 1,
			rules = Content.RULES,
			limits = Content.DEFAULT_LIMITS,
			items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
			wildlife = { { id = "grazer", behavior = "grazer" } },
		})
		assert(content, table.concat(errors, "; "))
		local requested: { any } = {}
		local now = 0
		local api = module.new({
			content = content,
			catalog = { species = { grazer = { healthMilli = 45000, damageMilli = 0, drops = {} } }, weapons = {} },
			maximum = 1,
			-- What a game pack's onboarding rule hands the world (OnboardingWildlife.fleeOnHit).
			fleeOnHit = { grazer = 8 },
			nowMillis = function()
				return now
			end,
			alive = function()
				return true
			end,
			equipment = function()
				return {}
			end,
			damage = function() end,
			observePath = function(event)
				if event.phase == "requested" then
					table.insert(requested, event)
				end
			end,
		})
		api.register(dodo, "dodo", "grazer")
		-- The player stands 3 studs off (inside the 12-stud sense radius) with it targeted.
		for _ = 1, 3 do
			now += 250
			heartbeat.fire()
		end
		assert(api.snapshot("dodo").mode == "roam", "targeted but unhit, it grazes: " .. api.snapshot("dodo").mode)
		assert(#requested == 0, "it does not walk off while the player closes in")
		-- A swing lands (the owner confirms the hit and names the striker).
		local hit = api.snapshot("dodo")
		hit.version += 1
		hit.healthMilli, hit.provoker = 40000, "1"
		api.publish(hit)
		now += 250
		heartbeat.fire()
		assert(api.snapshot("dodo").mode == "flee", "a hit makes it bolt: " .. api.snapshot("dodo").mode)
		local leg = assert(requested[1], "a flee leg is requested")
		assert(leg.goal.x < 0, "away from the striker")
		local run = math.sqrt(leg.goal.x * leg.goal.x + leg.goal.z * leg.goal.z)
		assert(run <= 8 + 1e-6, string.format("a short leg: %.1f studs", run))
		now += 2000
		heartbeat.fire()
		assert(api.snapshot("dodo").mode == "roam", "after the leg it grazes again")
		api.destroy()
	end,
	["a winded herd follower stays put while its leader flees"] = function()
		local heartbeat = signal()
		active.moved, active.owners = {}, {}
		active.finished, active.obstacle, active.surface = signal(), false, nil
		installMocks()
		local world = roblox.Instance.new("Workspace")
		active.world = world
		local function rig(position: any)
			local model = roblox.Instance.new("Model")
			model.Parent = world
			local root = roblox.Instance.new("Part")
			root.Name, root.Parent, root.Position = "HumanoidRootPart", model, position
			root.CFrame = roblox.CFrame.new(position)
			root.AssemblyLinearVelocity = roblox.Vector3.zero
			roblox.Instance.new("Humanoid").Parent = model
			return model, root
		end
		local leaderModel, leaderRoot = rig(roblox.Vector3.new(0, 3, 0))
		local followerModel = rig(roblox.Vector3.new(4, 3, 0))
		local character = rig(roblox.Vector3.new(6, 3, 0))
		local actor = { UserId = 1, Character = character }
		local services = {
			Workspace = world,
			Players = {
				GetPlayerByUserId = function(_, id)
					return if id == 1 then actor else nil
				end,
				GetPlayers = function()
					return { actor }
				end,
			},
			RunService = {
				Heartbeat = heartbeat,
				IsStudio = function()
					return true
				end,
			},
			PathfindingService = {},
		}
		local module = luau.load(fs.readFile("genres/survival-coop/module/WildlifeWorld.luau"), {
			environment = {
				game = {
					GetService = function(_, name)
						return services[name]
					end,
				},
				require = function(name)
					return if name == "./Wildlife"
						then Wildlife
						elseif name == "./DinosaurMotion" then DinosaurMotion
						elseif name == "./Herd" then Herd
						else Content
				end,
				Vector3 = roblox.Vector3,
				CFrame = roblox.CFrame,
				Enum = roblox.Enum,
				RaycastParams = {
					new = function()
						return {}
					end,
				},
				-- Path computation never runs: only the requests are observed.
				task = { spawn = function() end },
			},
		})()
		local content, errors = Content.canonicalize({
			survival_content = 1,
			rules = Content.RULES,
			limits = Content.DEFAULT_LIMITS,
			items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
			wildlife = { { id = "grazer", behavior = "grazer" } },
		})
		assert(content, table.concat(errors, "; "))
		local requested: { [string]: number } = {}
		local api = module.new({
			content = content,
			catalog = { species = { grazer = { healthMilli = 20000, damageMilli = 0, drops = {} } }, weapons = {} },
			maximum = 2,
			nowMillis = function()
				return 0
			end,
			alive = function()
				return true
			end,
			equipment = function()
				return {}
			end,
			damage = function() end,
			observePath = function(event)
				if event.phase == "requested" then
					requested[event.npcId] = (requested[event.npcId] or 0) + 1
				end
			end,
			herds = { Herd.new("trio", "lead", { "tail" }, { alarmStuds = 24, maxJoin = 4, maxChain = 2 }) },
		})
		api.register(leaderModel, "lead", "grazer")
		api.register(followerModel, "tail", "grazer")
		-- D2 R07: the HUD labels a herd once by this attribute.
		assert(
			leaderModel:GetAttribute("ForgeHerdId") == "trio" and followerModel:GetAttribute("ForgeHerdId") == "trio",
			"herd members carry their herd id"
		)
		-- The player wears the follower down to a quarter of its health (a confirmed hit alarms the herd).
		local worn = api.snapshot("tail")
		worn.version += 1
		worn.healthMilli, worn.provoker = 5000, "1"
		api.publish(worn)
		-- The leader has bolted 20 studs away: a calm follower would walk after it.
		leaderRoot.Position = roblox.Vector3.new(-20, 3, 0)
		leaderRoot.CFrame = roblox.CFrame.new(-20, 3, 0)
		heartbeat.fire()
		assert(api.snapshot("lead").mode == "flee", "the leader flees: " .. api.snapshot("lead").mode)
		assert(api.snapshot("tail").mode == "stunned", "the follower stands winded")
		assert(followerModel:GetAttribute("ForgeWildlifeState") == "stunned", "published winded")
		assert(requested.tail == nil, "the winded follower is not walked after its leader")
		api.destroy()
	end,
}
