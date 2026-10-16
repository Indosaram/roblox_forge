--!strict
-- Server-owned rigs and path events. No remotes, inventory grants, Humanoid
-- player damage, or client-authored position/damage enter this boundary.
local Wildlife = require("./Wildlife")
local DinosaurMotion = require("./DinosaurMotion")
local Content = require("../../../core/domain/survival/Content")
local M = {}
export type PathObservation = {
	npcId: string,
	serial: number,
	phase: string,
	start: Wildlife.Position,
	goal: Wildlife.Position,
	status: string,
	atMillis: number,
	mode: string,
	position: Wildlife.Position,
}
export type Config = {
	content: Content.Document,
	catalog: Wildlife.Catalog,
	maximum: number,
	nowMillis: () -> number,
	-- Trusted Session membership and durable vitals; these callbacks do not yield.
	alive: (string) -> boolean,
	equipment: (string) -> { [string]: boolean }?,
	-- Enqueue once into the existing owner command queue. Retrying delivery must
	-- retain this strike identity (prefix with a server world incarnation).
	damage: (string, string, number) -> (),
	observePath: ((PathObservation) -> ())?,
}
type Entry = {
	model: Model,
	root: BasePart,
	humanoid: Humanoid,
	state: Wildlife.State,
	definition: Content.Wildlife,
	serial: number,
	destination: Vector3?,
	failed: boolean,
	failedPath: PathObservation?,
	recoveryPath: PathObservation?,
	moving: boolean,
	computing: boolean,
	-- A rig is created above the floor and falls onto it, so its placement is not yet its resting
	-- coordinate. pending -> falling -> done; the spawn fall is what makes the resting height knowable.
	settle: string,
	connections: { RBXScriptConnection },
	motion: DinosaurMotion.Controller,
	-- Actor that damaged this rig (or alarmed its herd) since the last step.
	provokedBy: string?,
}
function M.new(config: Config)
	assert(config.maximum >= 1 and config.maximum <= 32 and config.maximum % 1 == 0, "INVALID_NPC_BUDGET")
	local world = game:GetService("Workspace")
	local players = game:GetService("Players")
	local paths = game:GetService("PathfindingService")
	local catalog = Wildlife.catalog(config.content, config.catalog)
	local entries: { [string]: Entry } = {}
	local count, stopped = 0, false
	local function point(position: Vector3): Wildlife.Position
		return { x = position.X, y = position.Y, z = position.Z }
	end
	local function root(id: string): BasePart?
		local userId = tonumber(id)
		local actor = if userId then players:GetPlayerByUserId(userId) else nil
		local part = if actor and actor.Character then actor.Character:FindFirstChild("HumanoidRootPart") else nil
		return if part and part:IsA("BasePart") and part:IsDescendantOf(world) then part else nil
	end
	local function observe(entry: Entry, request: PathObservation, phase: string, status: string)
		local callback = config.observePath
		if not callback then
			return
		end
		local event: PathObservation = {
			npcId = entry.state.id,
			serial = request.serial,
			phase = phase,
			start = table.freeze(table.clone(request.start)),
			goal = table.freeze(table.clone(request.goal)),
			status = status,
			atMillis = config.nowMillis(),
			mode = entry.state.mode,
			position = table.freeze(point(entry.root.Position)),
		}
		callback(table.freeze(event))
	end
	local function visible(from: BasePart, target: BasePart): boolean
		local delta = target.Position - from.Position
		if delta.Magnitude == 0 then
			return true
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { from.Parent :: Instance }
		params.RespectCanCollide = true
		local hit = world:Raycast(from.Position, delta, params)
		return hit == nil or hit.Instance:IsDescendantOf(target.Parent :: Instance)
	end
	local function cancel(entry: Entry)
		entry.serial += 1
		entry.moving, entry.destination = false, nil
		for _, connection in entry.connections do
			connection:Disconnect()
		end
		table.clear(entry.connections)
		entry.humanoid:MoveTo(entry.root.Position)
	end
	local function dispose(entry: Entry)
		cancel(entry)
		entry.motion.destroy()
		for _, name in
			{
				"ForgeWildlifeId",
				"ForgeWildlifeKind",
				"ForgeWildlifeState",
				"ForgeWildlifeTarget",
				"ForgeWildlifeHealthMilli",
				"ForgeWildlifeDeadline",
				"ForgeWildlifeHome",
			}
		do
			entry.model:SetAttribute(name, nil)
		end
	end
	local function move(entry: Entry, destination: Wildlife.Position)
		local goal = Vector3.new(destination.x, destination.y, destination.z)
		if entry.computing then
			return
		end
		if entry.destination and (entry.destination - goal).Magnitude < 2 then
			return
		end
		cancel(entry)
		entry.destination, entry.moving = goal, true
		entry.computing = true
		local serial = entry.serial
		local request: PathObservation = {
			npcId = entry.state.id,
			serial = serial,
			phase = "requested",
			start = point(entry.root.Position),
			goal = point(goal),
			status = "Pending",
			atMillis = config.nowMillis(),
			mode = entry.state.mode,
			position = point(entry.root.Position),
		}
		observe(entry, request, "requested", "Pending")
		local function fail(status: string)
			observe(entry, request, "result", status)
			request.status = status
			entry.failedPath = request
			cancel(entry)
			entry.failed = true
		end
		task.spawn(function()
			local path = paths:CreatePath()
			local ok = pcall(function()
				path:ComputeAsync(entry.root.Position, goal)
			end)
			entry.computing = false
			if stopped or serial ~= entry.serial then
				return
			end
			if not ok or path.Status ~= Enum.PathStatus.Success then
				fail(if ok then "NoPath" else "ComputeError")
				return
			end
			observe(entry, request, "result", "Success")
			local waypoints = path:GetWaypoints()
			local index = 2
			local function advance()
				local waypoint = waypoints[index]
				if not waypoint then
					cancel(entry)
					return
				end
				if waypoint.Action == Enum.PathWaypointAction.Jump then
					entry.humanoid.Jump = true
				end
				entry.humanoid:MoveTo(waypoint.Position)
			end
			table.insert(
				entry.connections,
				path.Blocked:Connect(function(blocked)
					if serial == entry.serial and blocked >= index then
						fail("Blocked")
					end
				end)
			)
			table.insert(
				entry.connections,
				entry.humanoid.MoveToFinished:Connect(function(reached)
					if serial ~= entry.serial then
						return
					end
					if not reached then
						fail("MoveFailed")
						return
					end
					if
						entry.recoveryPath
						and (entry.root.Position - Vector3.new(request.start.x, request.start.y, request.start.z)).Magnitude
							> 1
					then
						observe(entry, entry.recoveryPath, "recovered", "Success")
						entry.recoveryPath = nil
					end
					index += 1
					advance()
				end)
			)
			advance()
		end)
	end
	local api = {}
	function api.register(model: Model, id: string, kind: string): boolean
		assert(not stopped and count < config.maximum and not entries[id], "NPC_BUDGET_OR_ID")
		local definition: Content.Wildlife? = nil
		for _, candidate in config.content.wildlife do
			if candidate.id == kind then
				definition = candidate
				break
			end
		end
		assert(definition, "UNKNOWN_SPECIES")
		assert(model:IsDescendantOf(world), "NPC_NOT_IN_WORLD")
		for _, entry in entries do
			assert(entry.model ~= model, "DUPLICATE_RIG")
		end
		local part = model:FindFirstChild("HumanoidRootPart")
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		assert(part and part:IsA("BasePart") and humanoid and not part.Anchored, "INVALID_RIG")
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and not descendant.Anchored then
				descendant:SetNetworkOwner(nil)
			end
		end
		local state = Wildlife.new(id, kind, point(part.Position), catalog)
		entries[id] = {
			model = model,
			root = part,
			humanoid = humanoid,
			state = state,
			definition = table.clone(definition),
			serial = 0,
			failed = false,
			moving = false,
			computing = false,
			settle = "pending",
			connections = {},
			motion = DinosaurMotion.new(model, part, state, config.nowMillis()),
		}
		count += 1
		model:SetAttribute("ForgeWildlifeId", id)
		model:SetAttribute("ForgeWildlifeKind", kind)
		return true
	end
	function api.access(actorId: string, targetId: string): Wildlife.Access?
		local entry, actorRoot = entries[targetId], root(actorId)
		if not entry or not actorRoot or not entry.root:IsDescendantOf(world) then
			return nil
		end
		return {
			actorId = actorId,
			alive = config.alive(actorId),
			position = point(actorRoot.Position),
			facing = point(actorRoot.CFrame.LookVector),
			targetPosition = point(entry.root.Position),
			lineOfSight = visible(actorRoot, entry.root),
			equipped = table.clone(config.equipment(actorId) or {}),
		}
	end
	-- Maintained Studio probe of this instance's real registration gate. The
	-- non-yielding operation removes every temporary rig before Heartbeat can
	-- step it; it cannot attack, mint drops, or publish a durable NPC candidate.
	function api.probeCapacity()
		assert(game:GetService("RunService"):IsStudio(), "STUDIO_ONLY")
		assert(not stopped, "WILDLIFE_STOPPED")
		local function census()
			local ids = {}
			for id in entries do
				table.insert(ids, id)
			end
			table.sort(ids)
			return { count = count, ids = ids }
		end
		local report: any = {
			limit = config.maximum,
			before = census(),
			operations = {},
			attempts = 0,
			retryLimit = 0,
		}
		local owned: { [string]: Model } = {}
		if count == config.maximum then
			report.boundary = { kind = "existing-census", census = census() }
		end
		local ok, err = pcall(function()
			local _, template = next(entries)
			assert(template, "NPC_TEMPLATE_UNAVAILABLE")
			for index = count + 1, config.maximum + 1 do
				local id = "qa-cap-" .. tostring(index)
				assert(not entries[id], "QA_NPC_ID_COLLISION")
				local model = template.model:Clone()
				owned[id] = model
				local feedback = model:FindFirstChild("WildlifeFeedback")
				if feedback then
					feedback:Destroy()
				end
				model.Name, model.Parent = id, world
				local accepted, reason = pcall(api.register, model, id, template.state.catalogId)
				report.attempts += 1
				local operation = {
					kind = "registration",
					id = id,
					attemptedCount = index,
					accepted = accepted,
					reason = if accepted then nil else tostring(reason),
					census = census(),
				}
				table.insert(report.operations, operation)
				if index == config.maximum then
					report.boundary = operation
				end
				if index == config.maximum + 1 then
					report.refusal = operation
				else
					assert(accepted, reason)
				end
			end
		end)
		for id, model in owned do
			local entry = entries[id]
			if entry then
				dispose(entry)
				entries[id] = nil
				count -= 1
			end
			model:Destroy()
		end
		report.after = census()
		report.cleanup = { remaining = {} }
		for id, model in owned do
			if entries[id] or model.Parent then
				table.insert(report.cleanup.remaining, id)
			end
		end
		if not ok then
			report.error = tostring(err)
		end
		return report
	end
	-- Commit publication only; callers must not publish a staged/failed candidate.
	function api.publish(confirmed: Wildlife.State)
		local entry = assert(entries[confirmed.id], "UNKNOWN_NPC")
		assert(confirmed.catalogId == entry.state.catalogId and confirmed.version >= entry.state.version, "STALE_NPC")
		entry.state.healthMilli, entry.state.version, entry.state.killer =
			confirmed.healthMilli, confirmed.version, confirmed.killer
		if confirmed.healthMilli == 0 then
			entry.state.mode = "dead"
			cancel(entry)
		end
		entry.motion.update(entry.state, config.nowMillis(), entry.root.AssemblyLinearVelocity)
	end
	-- Server-side provocation (a confirmed hit, or a Herd alarm join). It is
	-- consumed by the next Heartbeat step; client input never reaches here.
	function api.provoke(id: string, actorId: string): boolean
		local entry = entries[id]
		if not entry or entry.state.healthMilli == 0 then
			return false
		end
		entry.provokedBy = actorId
		return true
	end
	function api.snapshot(id: string): Wildlife.State?
		local entry = entries[id]
		if not entry then
			return nil
		end
		local state = table.clone(entry.state)
		state.home = table.clone(entry.state.home)
		return state
	end
	local heartbeat = game:GetService("RunService").Heartbeat:Connect(function()
		local actors: { Wildlife.Actor } = {}
		for _, actor in players:GetPlayers() do
			local id = tostring(actor.UserId)
			local part = root(id)
			if part and config.alive(id) then
				table.insert(actors, { id = id, position = point(part.Position), alive = true })
			end
		end
		for id, entry in entries do
			if not entry.root:IsDescendantOf(world) then
				dispose(entry)
				entries[id] = nil
				count -= 1
				continue
			end
			-- Home is the physical resting root coordinate at the spawn location, not the spawn placement.
			-- A rig is created above the floor and falls onto it, so a home taken from the placement carries
			-- a permanent vertical error; the domain's own one-stud arrival is then spent on that error and
			-- the NPC can never report idle again. Measured: the hunter rested exactly one stud below its
			-- spawn and its return stalled at 1.32 instead of converging. The horizontal axes stay the
			-- authored spawn, so a frame of horizontal motion before the rig lands cannot move its home; only
			-- the resting height is taken from the settled root. A rig placed already resting never falls, so
			-- its placement is already the resting coordinate and home is left as it was.
			if entry.settle ~= "done" then
				local fallSpeed = entry.root.AssemblyLinearVelocity.Y
				if fallSpeed < -0.1 then
					entry.settle = "falling"
				elseif entry.settle == "falling" and math.abs(fallSpeed) < 1 then
					entry.state.home = { x = entry.state.home.x, y = entry.root.Position.Y, z = entry.state.home.z }
					entry.settle = "done"
				end
			end
			local state, intent = Wildlife.step(
				entry.state,
				entry.definition,
				catalog.species[entry.state.catalogId],
				config.nowMillis(),
				{
					position = point(entry.root.Position),
					actors = actors,
					pathFailed = entry.failed,
					lineOfSight = function(actorId)
						local target = root(actorId)
						return target ~= nil and visible(entry.root, target)
					end,
					observerStuds = Wildlife.HIBERNATE_STUDS,
					provokedBy = entry.provokedBy,
				}
			)
			entry.state, entry.failed, entry.provokedBy = state, false, nil
			if entry.failedPath then
				local failure = entry.failedPath
				observe(entry, failure, "consumed", failure.status)
				if not intent.destination and not intent.damage then
					observe(entry, failure, "refused", failure.status)
				end
				entry.recoveryPath, entry.failedPath = failure, nil
			end
			if intent.destination and Wildlife.distance(point(entry.root.Position), intent.destination) > 1 then
				move(entry, intent.destination)
			elseif entry.moving then
				cancel(entry)
			end
			entry.model:SetAttribute("ForgeWildlifeState", state.mode)
			entry.model:SetAttribute("ForgeWildlifeTarget", state.target)
			entry.model:SetAttribute("ForgeWildlifeHealthMilli", state.healthMilli)
			entry.model:SetAttribute("ForgeWildlifeDeadline", state.deadline)
			-- The home this instance's own idle/leash rules measure against. Publishing it lets a QA
			-- observer measure the same reference instead of re-authoring the coordinate, which
			-- drifts: the authored spawn y and the rig's registered home differ by a stud, and a
			-- 3D distance from the wrong one can never satisfy a one-stud bound.
			entry.model:SetAttribute("ForgeWildlifeHome", Vector3.new(state.home.x, state.home.y, state.home.z))
			entry.motion.update(state, config.nowMillis(), entry.root.AssemblyLinearVelocity)
			local hit = intent.damage
			if hit then
				config.damage(hit.actorId, hit.strikeId, hit.damageMilli)
			end
		end
	end)
	function api.destroy()
		stopped = true
		heartbeat:Disconnect()
		for _, entry in entries do
			dispose(entry)
		end
		table.clear(entries)
		count = 0
	end
	return api
end
return M
