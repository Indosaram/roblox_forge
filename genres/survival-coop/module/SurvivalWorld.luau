--!strict
-- Server-only engine boundary. Inventory/vitals transitions remain in the domain.
local Shared = require("../../../core/domain/genre/Contract")
local Content = require("../../../core/domain/survival/Content")
local Session = require("../../../core/infra/genre/Session")
local Options = require("../../../core/infra/genre/Options")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Gathering = require("./Gathering")
local GatheringRuntime = require("./GatheringRuntime")
local Fenced = require("../../../core/infra/data/FencedStore")
local Wildlife = require("./Wildlife")
local WildlifeWorld = require("./WildlifeWorld")
local DinosaurRig = require("./DinosaurRig")
local Settlement = require("../../../core/domain/settlement/Settlement")
local M = {}
export type GatherAuthority = (Session.Session, GatheringRuntime.Request, Inventory.State) -> boolean
export type Config = {
	content: Content.Document,
	worldRevision: string,
	spawn: SpawnLocation,
	carriedContainer: string,
	reachStuds: number,
	baseWalkSpeed: number,
	-- Retry pacing needs a monotonic seconds clock. Production omits it and gets
	-- os.clock(); specs inject a deterministic one so no test waits on wall time.
	now: (() -> number)?,
	respawnValues: { healthMilli: number, hungerMilli: number, fatigueMilli: number },
	wildlife: {
		catalog: Wildlife.Catalog,
		spawns: { { id: string, catalogId: string, position: Wildlife.Position } },
		nowMillis: () -> number,
		maximum: number,
	}?,
}

-- A failed durable command keeps its queue head and exact request identity, but the
-- Heartbeat drain must not re-attempt it every frame: an unpaced failure loop
-- re-issues the same durable command hundreds of times per second and starves the
-- shared backend for every other key. Only the cadence is bounded; retry count,
-- request identity and the existing terminal conditions are unchanged.
M.RETRY_INTERVAL_SECONDS = 1

function M.new(config: Config)
	assert(#config.worldRevision > 0 and #config.worldRevision <= 128, "invalid world revision")
	assert(config.reachStuds > 0 and config.reachStuds <= 12, "invalid reach")
	assert(config.baseWalkSpeed > 0 and config.baseWalkSpeed <= 100, "invalid walk speed")
	for _, value in
		{ config.respawnValues.healthMilli, config.respawnValues.hungerMilli, config.respawnValues.fatigueMilli }
	do
		assert(value == value and value % 1 == 0 and value >= 0 and value <= 100000, "invalid respawn values")
	end
	assert(config.respawnValues.healthMilli > 0, "respawn health required")
	local players = game:GetService("Players")
	local world = game:GetService("Workspace")
	local tags = game:GetService("CollectionService")
	local heartbeat = game:GetService("RunService").Heartbeat
	local now = config.now or function()
		return os.clock()
	end
	assert(config.spawn:IsDescendantOf(world), "spawn must be in world")
	local session: Session.Session? = nil
	local connections: { RBXScriptConnection } = {}
	local tools: { [Tool]: { owner: string, itemId: string } } = {}
	local projected: { [Tool]: Model } = {}
	local toolDefinitions: { [string]: Content.Item } = {}
	local itemDefinitions: { Content.Item } = config.content.items or {}
	for _, definition in itemDefinitions do
		if table.find(definition.tags, "tool") and (definition.maxDurabilityMilli or 0) > 0 then
			toolDefinitions[definition.id] = definition
		end
	end
	local stations: { [string]: BasePart } = {}
	local nodes: { [string]: { part: BasePart, kind: string, version: number } } = {}
	local nodeParts: { [BasePart]: boolean } = {}
	local pending: { [string]: { any } } = {}
	local observed: { [Humanoid]: number } = {}
	local positions: { [string]: Vector3 } = {}
	local busy: { [string]: boolean } = {}
	local retryAfter: { [string]: number } = {}
	local kinds: { [string]: boolean } = {}
	for _, definition in config.content.structures do
		if definition.station then
			kinds[definition.id] = true
		end
	end
	local function player(id: string): Player?
		local number = tonumber(id)
		return if number then players:GetPlayerByUserId(number) else nil
	end
	local function root(id: string): BasePart?
		local actor = player(id)
		local character = if actor then actor.Character else nil
		local part = if character then character:FindFirstChild("HumanoidRootPart") else nil
		return if part and part:IsA("BasePart") and part:IsDescendantOf(world) then part else nil
	end
	local function snapshot(id: string): any
		local active = session
		if not active or not table.find(active.members(), id) then
			return nil
		end
		return active.snapshot(id)["survival-coop"]
	end
	local function bagFor(id: string): Inventory.State?
		local active = session
		local personal = if active then active.personalTransfer(id) else nil
		local state = if personal then personal.profile().data.envelope.genres["survival-coop"].data else nil
		return if state and state.inventory then state.inventory[config.carriedContainer] else nil
	end
	local function usable(bag: Inventory.State, itemId: string): boolean
		local item = bag.items[itemId]
		return item ~= nil
			and toolDefinitions[item.catalogId] ~= nil
			and item.durabilityMilli > 0
			and Inventory.available(bag, itemId) > 0
	end
	local function owned(id: string, itemId: string): boolean
		local bag = bagFor(id)
		return bag ~= nil and usable(bag, itemId)
	end
	local function reachable(id: string, target: Vector3, instance: Instance?, maximum: number?): boolean
		local from = root(id)
		if not from then
			return false
		end
		local delta = target - from.Position
		if delta.Magnitude > (maximum or config.reachStuds) then
			return false
		end
		if delta.Magnitude == 0 then
			return true
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { from.Parent :: Instance }
		params.RespectCanCollide = true
		local hit = world:Raycast(from.Position, delta, params)
		return hit == nil or (instance ~= nil and (hit.Instance == instance or hit.Instance:IsDescendantOf(instance)))
	end
	local function station(id: string, key: string): { kind: string, reachable: boolean }?
		local part = stations[key]
		if not part or not part:IsDescendantOf(world) or not tags:HasTag(part, "ForgeSurvivalStation") then
			return nil
		end
		local kind = part:GetAttribute("ForgeStationKind")
		if type(kind) ~= "string" or not kinds[kind] or part:GetAttribute("ForgeStationId") ~= key then
			return nil
		end
		return { kind = kind, reachable = reachable(id, part.Position, part) }
	end
	local services: Options.Services = {
		survivalSpatial = {
			station = station,
			campfire = function(id: string, key: string): { reachable: boolean }?
				local found = station(id, key)
				return if found and found.kind == "campfire" then { reachable = found.reachable } else nil
			end,
		},
		survivalDeath = {
			worldRevision = config.worldRevision,
			position = function(id: string): Shared.SurvivalPosition?
				local part = root(id)
				return if part then { x = part.Position.X, y = part.Position.Y, z = part.Position.Z } else nil
			end,
			reachable = function(id: string, position: Shared.SurvivalPosition): boolean
				for _, value in { position.x, position.y, position.z } do
					if value ~= value or math.abs(value) > 1000000 then
						return false
					end
				end
				return reachable(id, Vector3.new(position.x, position.y, position.z), nil)
			end,
			equipment = function(id: string): { [string]: boolean }?
				local actor = player(id)
				if not actor or not actor.Character then
					return nil
				end
				local result = {}
				for tool, entry in tools do
					if entry.owner == id and tool.Parent == actor.Character and owned(id, entry.itemId) then
						result[entry.itemId] = true
					end
				end
				return result
			end,
		},
	}
	local api = { services = services }
	local built: { [string]: BasePart } = {}
	local builtVersion: { [string]: number } = {}
	-- The host supplies a trusted plot origin and warehouse position. These ports
	-- are called by the durable owner, never by a client-supplied proof.
	function api.settlementPorts(origin: Vector3, warehouse: Vector3)
		local function center(cell: Settlement.Cell, size: number): Vector3
			return origin + Vector3.new((cell.x + 0.5) * size, 0, (cell.z + 0.5) * size)
		end
		return {
			warehouse = function(actor: string): boolean
				return reachable(actor, warehouse, nil)
			end,
			verify = function(actor: string, placement: Settlement.Placement, state: Settlement.State): boolean
				local size = state.config.cellStuds
				local entry = center(placement.entry, size)
				if not reachable(actor, entry + Vector3.new(0, 2, 0), nil) then
					return false
				end
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				local actorRoot = root(actor)
				params.FilterDescendantsInstances = if actorRoot then { actorRoot.Parent :: Instance } else {}
				params.RespectCanCollide = true
				local cells = table.clone(placement.cells)
				table.insert(cells, placement.entry)
				for _, cell in cells do
					local position = center(cell, size)
					local support = world:Raycast(position + Vector3.new(0, 0.25, 0), Vector3.new(0, -1, 0), params)
					if not support or support.Normal.Y < 0.9 then
						return false
					end
					local overlap = OverlapParams.new()
					overlap.FilterType = Enum.RaycastFilterType.Exclude
					overlap.FilterDescendantsInstances = params.FilterDescendantsInstances
					overlap.RespectCanCollide = true
					if
						#world:GetPartBoundsInBox(
							CFrame.new(position + Vector3.new(0, 2, 0)),
							Vector3.new(size - 0.1, 3.5, size - 0.1),
							overlap
						) > 0
					then
						return false
					end
				end
				return true
			end,
			publish = function(state: Settlement.State)
				local tribe = state.config.tribeId
				if state.version < (builtVersion[tribe] or -1) then
					return
				end
				for id, part in built do
					if part:GetAttribute("ForgeTribeId") == tribe and not state.structures[id] then
						local stationId = part:GetAttribute("ForgeStationId")
						if type(stationId) == "string" then
							stations[stationId] = nil
						end
						part:Destroy()
						built[id] = nil
					end
				end
				for id, placement in state.structures do
					if built[id] then
						continue
					end
					local lowX, lowZ, highX, highZ = math.huge, math.huge, -math.huge, -math.huge
					for _, cell in placement.cells do
						lowX, lowZ = math.min(lowX, cell.x), math.min(lowZ, cell.z)
						highX, highZ = math.max(highX, cell.x), math.max(highZ, cell.z)
					end
					local size = state.config.cellStuds
					local part = Instance.new("Part")
					part.Name, part.Anchored = placement.definition.id, true
					part.Size = Vector3.new((highX - lowX + 1) * size - 0.2, 1, (highZ - lowZ + 1) * size - 0.2)
					part.Position = origin
						+ Vector3.new((lowX + highX + 1) * size / 2, 0.5, (lowZ + highZ + 1) * size / 2)
					part.Color = Color3.fromRGB(116, 77, 45)
					part:SetAttribute("ForgeTribeId", tribe)
					part:SetAttribute("ForgeStructureId", id)
					part.Parent = world
					built[id] = part
					if kinds[placement.definition.id] then
						-- Station handles are ephemeral world identity, not inventory or
						-- job identity. Keep them within the rest command's 64-byte cap.
						local stationId = "built:" .. game:GetService("HttpService"):GenerateGUID(false)
						stations[stationId] = part
						part:SetAttribute("ForgeStationId", stationId)
						part:SetAttribute("ForgeStationKind", placement.definition.id)
						tags:AddTag(part, "ForgeSurvivalStation")
					end
				end
				builtVersion[tribe] = state.version
			end,
		}
	end
	local wildlife: any = nil
	local wildlifeFolder: Folder? = nil
	local pathObserved: BindableEvent? = nil
	local capacityQA: Folder? = nil
	function api.publishCapacityLimits(limits: any)
		if not game:GetService("RunService"):IsStudio() then
			return
		end
		assert(not capacityQA, "CAPACITY_ALREADY_BOUND")
		local folder = Instance.new("Folder")
		folder.Name = "ForgeCapacity"
		local loaded = table.clone(limits)
		loaded.npcs = if config.wildlife then config.wildlife.maximum else nil
		local readout = Instance.new("BindableFunction")
		readout.Name, readout.Parent = "limits", folder
		readout.OnInvoke = function()
			return table.clone(loaded)
		end
		local probe = Instance.new("BindableFunction")
		probe.Name, probe.Parent = "npcs", folder
		probe.OnInvoke = function()
			assert(wildlife, "WILDLIFE_NOT_BOUND")
			return wildlife.probeCapacity()
		end
		folder.Parent = game:GetService("ServerStorage")
		capacityQA = folder
	end
	local function nodePart(id: string, kind: string): BasePart?
		local entry = nodes[id]
		if not entry or entry.kind ~= kind then
			return nil
		end
		local part = entry.part
		if
			not part:IsDescendantOf(world)
			or not part.Anchored
			or not tags:HasTag(part, "ForgeSurvivalNode")
			or part:GetAttribute("ForgeNodeId") ~= id
			or part:GetAttribute("ForgeNodeKind") ~= kind
			or part:GetAttribute("ForgeNodeWorldRevision") ~= config.worldRevision
		then
			return nil
		end
		return part
	end
	-- The factory installs this port on its shared source runtime. authorize must
	-- inspect the bound Session's current admitted request while its busy gate is
	-- held; commandEpoch is deliberately unsuitable there. Neither callback may yield.
	function api.gatheringAccess(authorize: GatherAuthority)
		return function(
			request: GatheringRuntime.Request,
			currentBag: Inventory.State,
			currentSource: Fenced.Data
		): Gathering.Access?
			local active = session
			if
				not active
				or not table.find(active.members(), request.actorId)
				or currentBag.id ~= config.carriedContainer
				or not authorize(active, request, currentBag)
			then
				return nil
			end
			local source: Gathering.State = currentSource.nodes
			-- World revision gates membership here; node-version staleness is
			-- Gathering.gather's contract, which refuses with STALE_VERSION.
			-- Refusing here first turned every concurrent gather race into an
			-- opaque UNAUTHORIZED that workload retries treated as terminal.
			if source.worldRevision ~= config.worldRevision then
				return nil
			end
			local node = source.nodes[request.nodeId]
			local part = if node then nodePart(request.nodeId, node.catalogId) else nil
			if not node or not part or node.id ~= request.nodeId then
				return nil
			end
			local target = Vector3.new(node.position.x, node.position.y, node.position.z)
			if part.Position ~= target then
				return nil
			end
			-- Detached projection: no mutable source node or bag escapes this call.
			local actorId = request.actorId
			local actor = player(actorId)
			local equipped: { [string]: boolean } = {}
			if actor and actor.Character then
				for tool, entry in tools do
					local item = currentBag.items[entry.itemId]
					if entry.owner == actorId and tool.Parent == actor.Character and item and item.quantity > 0 then
						equipped[entry.itemId] = true
					end
				end
			end
			local inReach = reachable(actorId, target, part, math.min(8, config.reachStuds))
			return {
				actorId = actorId,
				carriedContainer = currentBag.id,
				worldRevision = config.worldRevision,
				equipment = function(id: string): { [string]: boolean }?
					return if id == actorId then table.clone(equipped) else nil
				end,
				reachable = function(id: string, position: Gathering.Position): boolean
					return id == actorId
						and position.x == target.X
						and position.y == target.Y
						and position.z == target.Z
						and inReach
				end,
			}
		end
	end
	function api.registerNode(part: BasePart, id: string, kind: string, version: number, worldRevision: string)
		assert(#id > 0 and #id <= 64 and not nodes[id] and not nodeParts[part], "invalid node identity")
		assert(worldRevision == config.worldRevision, "wrong node world")
		assert(version >= 0 and version <= 2 ^ 53 - 2 and version % 1 == 0, "invalid node version")
		local known = false
		for _, definition in config.content.nodes do
			if definition.id == kind then
				known = true
			end
		end
		assert(known, "unknown node kind")
		assert(part:IsDescendantOf(world) and part.Anchored, "node must be anchored in world")
		assert(not tags:HasTag(part, "ForgeSurvivalNode"), "node already registered")
		nodes[id] = { part = part, kind = kind, version = version }
		nodeParts[part] = true
		part:SetAttribute("ForgeNodeId", id)
		part:SetAttribute("ForgeNodeKind", kind)
		part:SetAttribute("ForgeNodeWorldRevision", worldRevision)
		tags:AddTag(part, "ForgeSurvivalNode")
	end
	-- Caller supplies only a confirmed runtime snapshot. Attributes are display
	-- output, never read back for source charge/version authorization.
	function api.publishNodes(confirmed: Gathering.State)
		assert(confirmed.worldRevision == config.worldRevision, "wrong node world")
		for id, entry in nodes do
			local node = confirmed.nodes[id]
			local part = if node then nodePart(id, node.catalogId) else nil
			if part and node and confirmed.version >= entry.version then
				entry.version = confirmed.version
				part:SetAttribute("ForgeNodeVersion", confirmed.version)
				part:SetAttribute("ForgeNodeCount", node.charges)
				part:SetAttribute("ForgeNodeDepleted", node.charges == 0)
			end
		end
	end
	local function enqueue(id: string, action: string, args: { any }, stableId: string?, retain: boolean?)
		local active = assert(session, "world not bound")
		local epoch = active.commandEpoch(id, "survival-coop:" .. action)
		-- A dropped observation is safe when the same state re-queues it later. An
		-- engine-driven reconciliation (respawn) is not re-derived from a later event,
		-- so it must be retained until the drain resolves a command epoch instead of
		-- discarding the death silently.
		if epoch == nil and not stableId and not retain then
			return
		end
		local queue: { any } = pending[id] or {}
		pending[id] = queue
		for _, request in queue do
			if stableId and request.requestId == stableId then
				return
			end
		end
		table.insert(queue, {
			requestId = stableId or "engine:" .. game:GetService("HttpService"):GenerateGUID(false),
			sessionEpoch = epoch,
			action = "survival-coop:" .. action,
			args = args,
		})
	end
	function api.wildlifeAccess(actor: string, target: string): Wildlife.Access?
		return if wildlife then wildlife.access(actor, target) else nil
	end
	function api.publishWildlife(states: { [string]: Wildlife.State })
		assert(wildlife, "WILDLIFE_NOT_BOUND")
		for _, state in states do
			wildlife.publish(state)
		end
	end
	function api.registerStation(part: BasePart, id: string, kind: string)
		assert(#id > 0 and #id <= 64 and kinds[kind] and not stations[id], "invalid station identity")
		assert(part:IsDescendantOf(world) and part.Anchored, "station must be anchored in world")
		stations[id] = part
		part:SetAttribute("ForgeStationId", id)
		part:SetAttribute("ForgeStationKind", kind)
		tags:AddTag(part, "ForgeSurvivalStation")
	end
	function api.registerTool(tool: Tool, id: string, itemId: string)
		assert(#itemId > 0 and #itemId <= 128 and owned(id, itemId), "tool item must be owned")
		local actor = assert(player(id), "missing player")
		assert(
			tool.Parent == actor.Character or tool.Parent == actor:FindFirstChildOfClass("Backpack"),
			"tool must belong to actor"
		)
		assert(tools[tool] == nil, "tool already registered")
		tools[tool] = { owner = id, itemId = itemId }
	end
	local function projectTools()
		local active = assert(session, "world not bound")
		local members = active.members()
		for tool, entry in tools do
			local actor = player(entry.owner)
			local character = if actor then actor.Character else nil
			local bag = if table.find(members, entry.owner) then bagFor(entry.owner) else nil
			local backpack = if actor then actor:FindFirstChildOfClass("Backpack") else nil
			if
				not table.find(members, entry.owner)
				or not character
				or (projected[tool] and projected[tool] ~= character)
				or (tool.Parent ~= character and tool.Parent ~= backpack)
				or (bag and not usable(bag, entry.itemId))
			then
				tools[tool] = nil
				if projected[tool] then
					projected[tool] = nil
					tool:Destroy()
				end
			end
		end
		for _, id in members do
			local actor = player(id)
			local character = if actor then actor.Character else nil
			local backpack = if actor then actor:FindFirstChildOfClass("Backpack") else nil
			local bag = bagFor(id)
			if not character or not backpack or not bag then
				continue
			end
			for itemId, item in bag.items do
				if not usable(bag, itemId) then
					continue
				end
				local exists = false
				for _, entry in tools do
					if entry.owner == id and entry.itemId == itemId then
						exists = true
						break
					end
				end
				if exists then
					continue
				end
				local tool = Instance.new("Tool")
				tool.Name, tool.CanBeDropped, tool.RequiresHandle = toolDefinitions[item.catalogId].name, false, true
				tool.ToolTip = toolDefinitions[item.catalogId].name
				local handle = Instance.new("Part")
				handle.Name, handle.Size =
					"Handle", Vector3.new(0.22, if item.catalogId == "spear" then 5 else 2.5, 0.22)
				handle.Color, handle.Material = Color3.fromRGB(113, 77, 43), Enum.Material.Wood
				handle.CanCollide, handle.Massless, handle.Parent = false, true, tool
				local head = Instance.new("WedgePart")
				head.Name, head.Size =
					"StoneHead",
					if item.catalogId == "spear" then Vector3.new(0.65, 1.3, 0.25) else Vector3.new(1.5, 0.8, 0.4)
				head.Color, head.Material = Color3.fromRGB(105, 116, 125), Enum.Material.Slate
				head.CFrame = handle.CFrame * CFrame.new(0, handle.Size.Y / 2 + head.Size.Y / 2, 0)
				head.CanCollide, head.Massless, head.Parent = false, true, tool
				local weld = Instance.new("WeldConstraint")
				weld.Part0, weld.Part1, weld.Parent = handle, head, handle
				tool.Parent = backpack
				api.registerTool(tool, id, itemId)
				projected[tool] = character
			end
		end
	end
	local function observeHealth(id: string, humanoid: Humanoid)
		-- Signals may resume after Heartbeat or a later authored write. Sample the
		-- current property, not the historical signal argument, and also sample
		-- before projecting vitals so undelivered damage cannot be overwritten.
		local health = humanoid.Health
		local previous = observed[humanoid]
		observed[humanoid] = health
		if previous and health < previous then
			enqueue(id, "vitals-damage", { math.clamp(math.floor((previous - health) * 1000 + 0.5), 0, 100000) })
		end
	end
	local function loadCharacter(actor: Player): boolean
		actor.RespawnLocation = config.spawn
		actor:LoadCharacterAsync()
		if actor.Character then
			actor.Character:PivotTo(config.spawn.CFrame + Vector3.new(0, 4, 0))
		end
		return true
	end
	function api.bind(active: Session.Session)
		assert(session == nil, "world already bound")
		session = active
		if config.wildlife then
			local policy = config.wildlife
			local event = Instance.new("BindableEvent")
			event.Name, event.Parent = "ForgeWildlifePathObserved", game:GetService("ServerStorage")
			pathObserved = event
			local incarnation = game:GetService("HttpService"):GenerateGUID(false)
			wildlife = WildlifeWorld.new({
				content = config.content,
				catalog = policy.catalog,
				maximum = policy.maximum,
				observePath = function(observation)
					event:Fire(observation)
				end,
				nowMillis = policy.nowMillis,
				alive = function(id)
					local state = snapshot(id)
					return state ~= nil and state.vitals ~= nil and state.vitals.healthMilli > 0
				end,
				equipment = function(id)
					return services.survivalDeath.equipment(id)
				end,
				damage = function(id, strike, damage)
					enqueue(id, "vitals-damage", { damage }, "npc:" .. incarnation .. ":" .. strike)
				end,
			})
			local folder = Instance.new("Folder")
			folder.Name, folder.Parent = "ForgeWildlife", world
			wildlifeFolder = folder
			for _, spawn in policy.spawns do
				local p = spawn.position
				local model = DinosaurRig.new(spawn.catalogId, spawn.id, Vector3.new(p.x, p.y, p.z), folder)
				wildlife.register(model, spawn.id, spawn.catalogId)
			end
		end
		table.insert(
			connections,
			heartbeat:Connect(function()
				projectTools()
				local members = active.members()
				for id in retryAfter do
					if not table.find(members, id) then
						retryAfter[id] = nil
					end
				end
				for _, id in members do
					if busy[id] then
						continue
					end
					local actor = player(id)
					local humanoid = if actor and actor.Character
						then actor.Character:FindFirstChildOfClass("Humanoid")
						else nil
					local state = snapshot(id)
					if humanoid and state then
						if observed[humanoid] == nil then
							observed[humanoid] = humanoid.Health
							table.insert(
								connections,
								humanoid.HealthChanged:Connect(function()
									if actor and humanoid.Parent == actor.Character then
										observeHealth(id, humanoid)
									end
								end)
							)
						end
						observeHealth(id, humanoid)
						if state.vitals and state.vitals.healthMilli == 0 and #(pending[id] or {}) == 0 then
							-- Retained under an unavailable epoch: a silent drop here leaves durable
							-- health at zero with nothing queued to reconcile it.
							enqueue(id, "respawn", {
								config.respawnValues.healthMilli,
								config.respawnValues.hungerMilli,
								config.respawnValues.fatigueMilli,
							}, nil, true)
						end
						local part = root(id)
						if part then
							local previous = positions[id]
							if
								state.vitals
								and state.vitals.resting
								and previous
								and (part.Position - previous).Magnitude > 0.05
								and #(pending[id] or {}) == 0
							then
								enqueue(id, "rest-stop", {})
							end
							positions[id] = part.Position
						end
						local queue = pending[id]
						if queue and queue[1] and now() >= (retryAfter[id] or 0) then
							local request = queue[1]
							if request.sessionEpoch == nil then
								request.sessionEpoch = active.commandEpoch(id, request.action)
								if request.sessionEpoch == nil then
									-- Unavailable epoch: keep the head and its identity, but do not
									-- re-resolve it every frame.
									retryAfter[id] = now() + M.RETRY_INTERVAL_SECONDS
									continue
								end
							end
							busy[id] = true
							local ok, result = pcall(function(): Shared.Result
								local outcome = active.commandServer(id, request)
								return outcome
							end)
							busy[id] = nil
							if not ok then
								retryAfter[id] = now() + M.RETRY_INTERVAL_SECONDS
								warn(result)
								continue
							end
							if result.stateVersion ~= nil then
								table.remove(queue, 1)
								retryAfter[id] = nil
							elseif result.reason == "REQUEST_EXPIRED" then
								-- A stale window drops the head, and the death re-enqueues with a
								-- fresh identity on the next frame. Pace that re-enqueued attempt:
								-- clearing the window here lets a stale epoch drive one attempt
								-- and one epoch resolution per frame.
								table.remove(queue, 1)
								retryAfter[id] = now() + M.RETRY_INTERVAL_SECONDS
							else
								retryAfter[id] = now() + M.RETRY_INTERVAL_SECONDS
							end
							if result.ok and request.action == "survival-coop:respawn" and actor then
								busy[id] = true
								local loaded, err = pcall(loadCharacter, actor)
								busy[id] = nil
								if not loaded then
									warn(err)
								end
								continue
							end
							state = snapshot(id)
						end
						humanoid.WalkSpeed = config.baseWalkSpeed
							* (state.speedMultiplierMilli or 1000)
							* (state.vitalsMovementMilli or 1000)
							/ 1000000
						if state.vitals and #(pending[id] or {}) == 0 then
							humanoid.MaxHealth = 100
							observed[humanoid] = state.vitals.healthMilli / 1000
							humanoid.Health = state.vitals.healthMilli / 1000
							observed[humanoid] = humanoid.Health
						end
					end
				end
			end)
		)
	end
	function api.respawn(id: string, requestId: string): Shared.Result
		assert(#requestId > 0 and #requestId <= 128, "invalid respawn request")
		local active = assert(session, "world not bound")
		local actor = player(id)
		if not actor then
			return { ok = false, reason = "PLAYER_UNAVAILABLE" }
		end
		local epoch = active.commandEpoch(id, "survival-coop:respawn")
		if epoch == nil then
			return { ok = false, reason = "EPOCH_UNAVAILABLE" }
		end
		local result = active.commandServer(id, {
			requestId = requestId,
			sessionEpoch = epoch,
			action = "survival-coop:respawn",
			args = {
				config.respawnValues.healthMilli,
				config.respawnValues.hungerMilli,
				config.respawnValues.fatigueMilli,
			},
		})
		if result.ok then
			loadCharacter(actor)
		end
		return result
	end
	function api.destroy()
		if capacityQA then
			capacityQA:Destroy()
			capacityQA = nil
		end
		for _, part in built do
			local stationId = part:GetAttribute("ForgeStationId")
			if type(stationId) == "string" then
				stations[stationId] = nil
			end
			part:Destroy()
		end
		table.clear(built)
		table.clear(builtVersion)
		for tool in projected do
			tool:Destroy()
		end
		table.clear(projected)
		if wildlife then
			wildlife.destroy()
			wildlife = nil
		end
		if wildlifeFolder then
			wildlifeFolder:Destroy()
			wildlifeFolder = nil
		end
		if pathObserved then
			pathObserved:Destroy()
			pathObserved = nil
		end
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		table.clear(tools)
		for _, part in stations do
			tags:RemoveTag(part, "ForgeSurvivalStation")
			part:SetAttribute("ForgeStationId", nil)
			part:SetAttribute("ForgeStationKind", nil)
		end
		for _, entry in nodes do
			local part = entry.part
			tags:RemoveTag(part, "ForgeSurvivalNode")
			for _, attribute in
				{
					"ForgeNodeId",
					"ForgeNodeKind",
					"ForgeNodeWorldRevision",
					"ForgeNodeVersion",
					"ForgeNodeCount",
					"ForgeNodeDepleted",
				}
			do
				part:SetAttribute(attribute, nil)
			end
		end
		table.clear(nodes)
		table.clear(nodeParts)
		table.clear(stations)
		table.clear(pending)
		table.clear(observed)
		table.clear(busy)
		table.clear(retryAfter)
		table.clear(positions)
		session = nil
	end
	return api
end
return M
