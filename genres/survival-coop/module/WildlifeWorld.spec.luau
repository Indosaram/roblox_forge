--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local Wildlife = require("./Wildlife")
local Content = require("../../../core/domain/survival/Content")
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
local active: any = { owners = {}, moved = {}, finished = nil, obstacle = false, world = nil }
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
	roblox.implementMethod("Workspace", "Raycast", function()
		return if active.obstacle then { Instance = active.world } else nil
	end)
end

return {
	["engine binding reads physical positions fences stale paths and disposes signals"] = function()
		local heartbeat, finished, blocked = signal(), signal(), signal()
		active.moved, active.owners = {}, {}
		active.finished, active.obstacle = finished, false
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
		npc.Parent = nil
		heartbeat.fire()
		assert(
			api.snapshot("h1") == nil and not npc:FindFirstChild("WildlifeFeedback"),
			"removed rig releases controller"
		)
		assert(npc:GetAttribute("ForgeWildlifeId") == nil, "removed rig clears world attributes")
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
		active.finished, active.obstacle = signal(), false
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
		active.finished, active.obstacle = signal(), false
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
}
