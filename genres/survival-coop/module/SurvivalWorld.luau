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
local MountVisual = require("./MountVisual")
local CosmeticVisual = require("./CosmeticVisual")
local Archetype = require("../../../core/domain/survival/Archetype")
local Settlement = require("../../../core/domain/settlement/Settlement")
local CharacterRules = require("./CharacterRules")
local M = {}
export type GatherAuthority = (Session.Session, GatheringRuntime.Request, Inventory.State) -> boolean
export type Config = {
	content: Content.Document,
	worldRevision: string,
	spawn: SpawnLocation,
	carriedContainer: string,
	reachStuds: number,
	baseWalkSpeed: number,
	-- Paid cosmetic looks (mount skins, worn sets); absent means cosmetics render nothing.
	cosmetics: CosmeticVisual.Config?,
	-- Retry pacing needs a monotonic seconds clock. Production omits it and gets
	-- os.clock(); specs inject a deterministic one so no test waits on wall time.
	now: (() -> number)?,
	respawnValues: { healthMilli: number, hungerMilli: number, fatigueMilli: number },
	-- Archipelago hazard zones: the layout whose hazards tick, and the seeded world-clock
	-- origin (seconds) its storm timeline starts from. Omitted on worlds without hazards.
	hazards: { layout: any, origin: number? }?,
	wildlife: {
		catalog: Wildlife.Catalog,
		spawns: { { id: string, catalogId: string, position: Wildlife.Position } },
		nowMillis: () -> number,
		maximum: number,
	}?,
}

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
		-- Characters are not walls: a tribemate standing in front of the warehouse or a station must
		-- not revoke another player's reach (Studio co-op QA caught exactly that refusal).
		local ignored: { Instance } = { from.Parent :: Instance }
		for _, other in players:GetPlayers() do
			if other.Character and other.Character ~= from.Parent then
				table.insert(ignored, other.Character)
			end
		end
		params.FilterDescendantsInstances = ignored
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
		local from = root(id)
		return {
			kind = kind,
			reachable = from ~= nil
				and (from.Position - part.Position).Magnitude <= 12
				and reachable(id, part.Position + Vector3.new(0, part.Size.Y / 2 + 2, 0), part, 16),
		}
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
	-- isFriend is declared so the table satisfies SurvivalBootstrap.World; hosts assign the trusted friendship source.
	local api =
		{ services = services, isFriend = nil :: ((string, string) -> boolean)?, structureKits = nil :: Folder? }
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
			-- Returns false plus a distinct refusal (p60: every failure used to read "move closer").
			verify = function(
				actor: string,
				placement: Settlement.Placement,
				state: Settlement.State
			): (boolean, string?)
				local size = state.config.cellStuds
				local entry = center(placement.entry, size)
				local ground = world:Raycast(entry + Vector3.new(0, 32, 0), Vector3.new(0, -64, 0))
				if ground and ground.Position then
					entry = Vector3.new(entry.X, ground.Position.Y, entry.Z)
				end
				if not reachable(actor, entry + Vector3.new(0, 3, 0), nil, 12) then
					return false, "PLACEMENT_UNREACHABLE"
				end
				-- Wildlife models carry ForgeWildlifeId (WildlifeWorld); the HUD ghost uses the same test.
				local function creature(instance: Instance?): boolean
					local node = instance
					while node and node ~= world do
						if node:GetAttribute("ForgeWildlifeId") ~= nil then
							return true
						end
						node = node.Parent
					end
					return false
				end
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				-- Characters never block a plot: they walk away, and a tribemate standing near the camp
				-- (Studio co-op QA: the guest by the warehouse, on the entry cell) must not refuse a build.
				local characters: { Instance } = {}
				for _, other in players:GetPlayers() do
					if other.Character then
						table.insert(characters, other.Character)
					end
				end
				local actorRoot = root(actor)
				if actorRoot and not table.find(characters, actorRoot.Parent :: Instance) then
					table.insert(characters, actorRoot.Parent :: Instance)
				end
				params.FilterDescendantsInstances = characters
				params.RespectCanCollide = true
				local cells = table.clone(placement.cells)
				table.insert(cells, placement.entry)
				for _, cell in cells do
					local position = center(cell, size)
					local support = world:Raycast(position + Vector3.new(0, 32, 0), Vector3.new(0, -64, 0), params)
					if support and creature(support.Instance) then
						return false, "PLACEMENT_BLOCKED_CREATURE"
					end
					if not support or support.Normal.Y < 0.9 then
						return false, "PLACEMENT_UNSUPPORTED"
					end
					if support.Position then
						position = Vector3.new(position.X, support.Position.Y, position.Z)
					end
					local overlap = OverlapParams.new()
					overlap.FilterType = Enum.RaycastFilterType.Exclude
					overlap.FilterDescendantsInstances = params.FilterDescendantsInstances
					overlap.RespectCanCollide = true
					local blockers = world:GetPartBoundsInBox(
						CFrame.new(position + Vector3.new(0, 2, 0)),
						Vector3.new(size - 0.1, 3.5, size - 0.1),
						overlap
					)
					for _, part in blockers do
						if creature(part) then
							return false, "PLACEMENT_BLOCKED_CREATURE"
						end
					end
					if #blockers > 0 then
						return false, "PLACEMENT_BLOCKED"
					end
				end
				return true, nil
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
					local support = world:Raycast(part.Position + Vector3.new(0, 32, 0), Vector3.new(0, -64, 0))
					if support and support.Position then
						part.Position = Vector3.new(part.Position.X, support.Position.Y + 0.5, part.Position.Z)
					end
					part.Color = Color3.fromRGB(116, 77, 45)
					part:SetAttribute("ForgeTribeId", tribe)
					part:SetAttribute("ForgeStructureId", id)
					part.Parent = world
					local kit = if api.structureKits
						then api.structureKits:FindFirstChild(placement.definition.id)
						else nil
					if kit and kit:IsA("Model") then
						local visual = kit:Clone()
						visual:PivotTo(
							CFrame.new(part.Position - Vector3.new(0, 0.5, 0))
								* CFrame.Angles(0, -placement.rotation * math.pi / 2, 0)
						)
						visual.Parent = part
						part.Transparency, part.CanCollide = 1, false
					end
					built[id] = part
					if kinds[placement.definition.id] then
						-- Ephemeral handles within the 64-byte cap; a tiered bench (<kind>-tN) uses station.<kind>.tN.
						local base, tier = CharacterRules.tieredKind(placement.definition.id, kinds)
						local anchorId = if base and tier then "station." .. base .. ".t" .. tier else nil
						local stationId = if anchorId and not stations[anchorId]
							then anchorId
							else "built:" .. game:GetService("HttpService"):GenerateGUID(false)
						stations[stationId] = part
						part:SetAttribute("ForgeStationId", stationId)
						part:SetAttribute(
							"ForgeStationKind",
							if stationId == anchorId then base else placement.definition.id
						)
						tags:AddTag(part, "ForgeSurvivalStation")
					end
				end
				builtVersion[tribe] = state.version
			end,
		}
	end
	local wildlife: any = nil
	local wildlifeFolder: Folder? = nil
	-- Visible mounts: one dressed wildlife rig per rider, welded under the character (server-made,
	-- so it replicates to every client). Driven only by the taming snapshot's ride species.
	local mounts: { [string]: { species: string, model: Model, humanoid: Humanoid, hip: number } } = {}
	local function detachMount(id: string)
		local mount = mounts[id]
		if not mount then
			return
		end
		mounts[id] = nil
		if mount.humanoid.Parent then
			mount.humanoid.HipHeight = mount.hip
		end
		mount.model:Destroy()
	end
	local function attachMount(id: string, key: string)
		local species, skin = MountVisual.parse(key)
		local actor = player(id)
		local character = if actor then actor.Character else nil
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local rider = root(id)
		if not character or not humanoid or not rider then
			return
		end
		local engine = "grazer"
		for _, entry in (config.content.wildlife or {}) :: { any } do
			if entry.id == species then
				engine = Archetype.engine(entry.behavior) or engine
			end
		end
		local envelope: Vector3?, visual: any = nil, nil
		for _, detail in (config.content.wildlifeDetails or {}) :: { any } do
			if detail.id == species then
				engine, visual = detail.id, detail.visual
				local size = detail.renderEnvelope
				if size then
					envelope = Vector3.new(size.x, size.y, size.z)
				end
				break
			end
		end
		if skin and config.cosmetics then
			visual = CosmeticVisual.mount(visual, config.cosmetics.mountSkins[skin])
		end
		local model = MountVisual.dress(
			DinosaurRig.new(engine, MountVisual.MODEL_NAME, rider.Position, character, envelope, visual)
		)
		local body = model:FindFirstChild("MountRoot") :: BasePart
		body.CFrame = rider.CFrame * CFrame.new(0, MountVisual.SEAT.offsetStuds, 0)
		local weld = Instance.new("WeldConstraint")
		weld.Part0, weld.Part1, weld.Parent = rider, body, body
		model:SetAttribute("ForgeMountSpecies", species)
		model:SetAttribute("ForgeMountSkin", skin)
		mounts[id] = { species = key, model = model, humanoid = humanoid, hip = humanoid.HipHeight }
		humanoid.HipHeight += MountVisual.SEAT.liftStuds
	end
	local function syncMounts(active: Session.Session, members: { string })
		local wanted: { [string]: string } = {}
		local attached: { [string]: string } = {}
		for id, mount in mounts do
			local actor = player(id)
			-- A respawned character (death) or a departed player drops the old body with it.
			if not actor or not mount.model:IsDescendantOf(world) or mount.model.Parent ~= actor.Character then
				detachMount(id)
			else
				attached[id] = mount.species
			end
		end
		for _, id in members do
			local state = snapshot(id)
			if busy[id] or not state or not state.vitals or state.vitals.healthMilli <= 0 then
				if busy[id] and attached[id] then
					wanted[id] = attached[id]
				end
				continue
			end
			local shared = active.snapshot(id).survivalExtensions
			local extensions = if type(shared) == "table" then shared else nil
			-- Worn paid cosmetics (cloak/banner sets) follow the monetization appearance.
			local actor = player(id)
			if config.cosmetics and actor and actor.Character then
				local shop = if extensions then extensions.monetization else nil
				CosmeticVisual.dressWear(
					actor.Character,
					CosmeticVisual.wear(config.cosmetics, if type(shop) == "table" then shop.appearance else nil)
				)
			end
			local species = MountVisual.look(if extensions then extensions.taming else nil)
			if species then
				wanted[id] = species
			end
		end
		local plan = MountVisual.plan(wanted, attached)
		for _, id in plan.detach do
			detachMount(id)
		end
		for _, entry in plan.attach do
			attachMount(entry.actor, entry.species)
		end
	end
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
	-- authorize reads the Session's admitted request under its busy gate; neither callback may yield.
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
			-- Node-version staleness is Gathering.gather's STALE_VERSION, not an UNAUTHORIZED here.
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
		-- A respawn is never re-derived from a later event, so it is retained until an epoch resolves.
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
			if wildlifeFolder then
				for _, model in wildlifeFolder:GetChildren() do
					if model:GetAttribute("ForgeWildlifeId") == state.id then
						model:SetAttribute("ForgePlayerWindupUntil", (state :: any).playerWindupUntil)
					end
				end
			end
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
	function api.unregisterStation(part: BasePart)
		local id = part:GetAttribute("ForgeStationId")
		if type(id) == "string" and stations[id] == part then
			stations[id] = nil
			tags:RemoveTag(part, "ForgeSurvivalStation")
		end
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
	-- Worn gear is shown with one light welded part per slot (CharacterRules.dressing).
	-- The folder is rebuilt only when the worn set changes; it is presentation only.
	local function projectGear()
		local active = assert(session, "world not bound")
		for _, id in active.members() do
			local actor = player(id)
			local character = if actor then actor.Character else nil
			local personal = active.personalTransfer(id)
			local profile = if personal then personal.profile() else nil
			local envelope = if profile and profile.data then profile.data.envelope else nil
			local slice = if envelope and envelope.genres then envelope.genres["survival-coop"] else nil
			local state = if slice then slice.data else nil
			if not character or not state then
				continue
			end
			local bag = if state.inventory then state.inventory[config.carriedContainer] else nil
			local plan = CharacterRules.dressing(state.gear, bag)
			local keys = {}
			for _, entry in plan do
				table.insert(keys, entry.slot .. "=" .. entry.itemId)
			end
			local signature = table.concat(keys, ",")
			local folder = character:FindFirstChild("ForgeGear")
			if (folder and folder:GetAttribute("ForgeGearSignature") == signature) or (not folder and #plan == 0) then
				continue
			end
			if folder then
				folder:Destroy()
			end
			local fresh = Instance.new("Folder")
			fresh.Name = "ForgeGear"
			fresh:SetAttribute("ForgeGearSignature", signature)
			for _, entry in plan do
				local body = character:FindFirstChild(entry.part) or character:FindFirstChild(entry.fallback)
				if not body or not body:IsA("BasePart") then
					continue
				end
				local piece = Instance.new("Part")
				piece.Name = "Gear-" .. entry.slot
				piece.Size = Vector3.new(entry.size.x, entry.size.y, entry.size.z)
				piece.Color = Color3.fromRGB(entry.color[1], entry.color[2], entry.color[3])
				piece.Material = if entry.slot == "weapon" then Enum.Material.Wood else Enum.Material.Fabric
				piece.CanCollide, piece.CanQuery, piece.CanTouch, piece.Massless = false, false, false, true
				piece.CFrame = body.CFrame * CFrame.new(entry.offset.x, entry.offset.y, entry.offset.z)
				piece:SetAttribute("ForgeGearItem", entry.catalogId)
				local weld = Instance.new("WeldConstraint")
				weld.Part0, weld.Part1, weld.Parent = body, piece, piece
				piece.Parent = fresh
			end
			fresh.Parent = character
		end
	end
	-- Live hazard-zone exposure: the world clock (config.now, seconds) drives it; positions are the
	-- server-observed root. A downed actor resets its clock, so nothing accrues while down.
	local exposureFrom: { [string]: number? } = {}
	-- Without an injected origin the storm timeline starts when the world is built.
	local hazardOrigin = now()
	local function exposeHazards(id: string, state: any)
		local hazards = config.hazards
		local part = root(id)
		if not hazards or not session or #(pending[id] or {}) > 0 then
			-- A queued command keeps the exposure clock; the interval is applied once it drains.
			return
		end
		local active = session :: Session.Session
		local personal = active.personalTransfer(id)
		local profile = if personal then personal.profile() else nil
		local slice = if profile and profile.data then profile.data.envelope.genres["survival-coop"] else nil
		local data = if slice then slice.data else nil
		local alive = state.vitals ~= nil and state.vitals.healthMilli > 0
		local args, from = CharacterRules.hazardTick(
			config.content,
			hazards.layout,
			alive,
			if part then { x = part.Position.X, y = part.Position.Y, z = part.Position.Z } else nil,
			if data then data.gear else nil,
			if data and data.inventory then data.inventory[config.carriedContainer] else nil,
			exposureFrom[id],
			now(),
			hazards.origin or hazardOrigin
		)
		exposureFrom[id] = from
		if args then
			enqueue(id, "hazard-exposure", args)
		end
	end
	local function observeHealth(id: string, humanoid: Humanoid)
		-- Sample the current property (not the signal argument), also before projecting vitals.
		local health = humanoid.Health
		local previous = observed[humanoid]
		if previous == nil then
			observed[humanoid] = health
		elseif health < previous then
			observed[humanoid] = health
			local damage = math.clamp(math.floor((previous - health) * 1000 + 0.5), 0, 100000)
			if damage > 0 then
				enqueue(id, "vitals-damage", { damage })
			end
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
					enqueue(id, "combat-damage", { damage, policy.nowMillis() }, "npc:" .. incarnation .. ":" .. strike)
				end,
			})
			local folder = Instance.new("Folder")
			folder.Name, folder.Parent = "ForgeWildlife", world
			wildlifeFolder = folder
			for _, spawn in policy.spawns do
				local p = spawn.position
				local engine = "hunter"
				for _, entry in (config.content.wildlife or {}) :: { any } do
					if entry.id == spawn.catalogId then
						engine = Archetype.engine(entry.behavior) or "hunter"
					end
				end
				local envelope: Vector3?, visual: any = nil, nil
				for _, detail in (config.content.wildlifeDetails or {}) :: { any } do
					if detail.id == spawn.catalogId then
						engine, visual = detail.id, detail.visual
						local size = detail.renderEnvelope
						if size then
							envelope = Vector3.new(size.x, size.y, size.z)
						end
						break
					end
				end
				local model = DinosaurRig.new(engine, spawn.id, Vector3.new(p.x, p.y, p.z), folder, envelope, visual)
				DinosaurRig.ground(model)
				wildlife.register(model, spawn.id, spawn.catalogId)
			end
		end
		table.insert(
			connections,
			heartbeat:Connect(function()
				projectTools()
				projectGear()
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
						exposeHazards(id, state)
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
								-- Stale window: drop the head and pace the re-enqueued death (not one per frame).
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
						-- A mounted rider moves at the server-resolved ride speed (never client input),
						-- scaled by the same load penalty measured against the ride's carry capacity.
						local shared = active.snapshot(id).survivalExtensions
						local ride = if type(shared) == "table" then shared.taming else nil
						if type(ride) == "table" and ride.walkSpeedStuds then
							humanoid.WalkSpeed = ride.walkSpeedStuds
								* (ride.loadMilli or 1000)
								* (state.vitalsMovementMilli or 1000)
								/ 1000000
						end
						if state.vitals and #(pending[id] or {}) == 0 then
							humanoid.MaxHealth = 100
							observed[humanoid] = state.vitals.healthMilli / 1000
							humanoid.Health = state.vitals.healthMilli / 1000
							observed[humanoid] = humanoid.Health
						end
					end
				end
				syncMounts(active, members)
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
		for id in mounts do
			detachMount(id)
		end
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
		table.clear(exposureFrom)
		session = nil
	end
	return api
end
return M
