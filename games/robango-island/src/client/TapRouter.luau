--!strict
-- A1 world tap router: UI > creature > node > ground; a handler returning false passes on.
local M = {}

export type Kind = "ui" | "creature" | "node" | "decor" | "ground"
export type Probe = {
	overUi: boolean?,
	creature: any?,
	node: any?,
	-- ForgeKitFamily of a tapped biome-kit rock, tree, fern or shrub that is scenery, not a gather node.
	decor: string?,
	ground: any?,
}
export type Handler = (target: any, probe: Probe) -> boolean?

local PRIORITY: { Kind } = { "ui", "creature", "node", "decor", "ground" }
M.PRIORITY = table.freeze(PRIORITY)
M.TAP_SLOP, M.PICK_RADIUS = 12, 40 -- px: drag threshold, fingertip pick radius

function M.new()
	type Entry = { id: number, fn: Handler }
	local handlers: { [string]: { Entry } } = {}
	local serial = 0
	local router = {}
	function router.register(kind: Kind, fn: Handler): () -> ()
		assert(table.find(M.PRIORITY, kind), "unknown tap kind")
		serial += 1
		local id = serial
		local list: { Entry } = handlers[kind] or {}
		handlers[kind] = list
		table.insert(list, 1, { id = id, fn = fn })
		return function()
			for index, entry in list do
				if entry.id == id then
					table.remove(list, index)
					return
				end
			end
		end
	end
	function router.dispatch(probe: Probe): Kind?
		for _, kind: Kind in PRIORITY do
			local target: any = if kind == "ui" then probe.overUi else (probe :: any)[kind]
			if target then
				if kind == "ui" then
					return "ui" -- the GUI already took it
				end
				local list: { Entry } = handlers[kind] or {}
				for _, entry in table.clone(list) do
					if entry.fn(target, probe) ~= false then
						return kind
					end
				end
			end
		end
		return nil
	end
	return router
end

function M.nearest(
	x: number,
	y: number,
	candidates: { { target: any, x: number, y: number, visible: boolean } },
	radius: number
): any?
	local best, bestDistance = nil, radius * radius
	for _, candidate in candidates do
		local d = (candidate.x - x) ^ 2 + (candidate.y - y) ^ 2
		if candidate.visible and d <= bestDistance then
			best, bestDistance = candidate.target, d
		end
	end
	return best
end

function M.route(
	status: string,
	waypoints: { { position: any, jump: boolean } },
	goal: any
): { { position: any, jump: boolean } }
	if status == "Success" and #waypoints > 1 then
		return table.move(waypoints, 2, #waypoints, 1, {})
	end
	return { { position = goal, jump = false } }
end

-- Shore stop: walk the straight line from `from` toward `goal` in `step`-stud samples and return
-- the last land point before the line first leaves land (the goal itself when it stays on land).
-- Water before any land is crossed, so a wading player can still walk back ashore. Returns nil
-- (refuse the tap) when no land is reached or the walk would be shorter than SHORE_MIN.
-- `isLand(x, z)` is the terrain query; positions are Vector3s or { X, Y, Z } tables.
M.SHORE_STEP, M.SHORE_MIN = 2, 3 -- studs: sample spacing, shortest walk worth taking
function M.shore(from: any, goal: any, isLand: (number, number) -> boolean, step: number?): (number?, number?)
	local spacing = step or M.SHORE_STEP
	local dx, dz = goal.X - from.X, goal.Z - from.Z
	local length = math.sqrt(dx * dx + dz * dz)
	local count = math.max(math.ceil(length / spacing), 1)
	local lastX, lastZ, lastT = nil, nil, 0
	for index = 1, count do
		local t = index / count
		local x, z = from.X + dx * t, from.Z + dz * t
		if isLand(x, z) then
			lastX, lastZ, lastT = x, z, t
		elseif lastX ~= nil then
			break
		end
	end
	if lastX == nil or (lastT < 1 and lastT * length < M.SHORE_MIN) then
		return nil, nil
	end
	return if lastT == 1 then goal.X else lastX, if lastT == 1 then goal.Z else lastZ
end

function M.steer(
	dx: number,
	dy: number,
	right: { x: number, z: number },
	forward: { x: number, z: number }
): (number?, number?)
	if dx * dx + dy * dy <= M.TAP_SLOP * M.TAP_SLOP then
		return nil, nil
	end
	local x = right.x * dx - forward.x * dy
	local z = right.z * dx - forward.z * dy
	local length = math.sqrt(x * x + z * z)
	if length < 1e-6 then
		return nil, nil
	end
	return x / length, z / length
end

-- The node id a decorative kit piece belongs to. RoleWorld dresses each gather node with a kit named
-- `<nodeId>.kit` (mesh model) or `<nodeId>.kit.<piece>` (parts) a few studs beside the small tagged
-- node part; the kit is what the player sees as the bush or rock, but it is CanQuery=false.
function M.kitOwner(name: string): string?
	local id = string.match(name, "^(.-)%.kit%.") or string.match(name, "^(.-)%.kit$")
	return if id and id ~= "" then id else nil
end

-- Staging v40: the boulders and trees a player sees are mostly BiomeKits scenery (queryable rock and
-- tree meshes in ForgeBiomeKits), not the few authored gather nodes, so a tap on them walked only.
-- A scenery tap gathers from a node standing within DECOR_RADIUS studs of the tapped point; with
-- none there, the decor handler says where stone and wood come from.
M.DECOR_RADIUS = 16
-- Scenery families that look gatherable (BiomeKits.QUERYABLE): p134 v50, a fern tap only walked. Each
-- has a cli.gather.decor_<family> line.
M.DECOR_FAMILIES = table.freeze({ rock = true, tree = true, fern = true, shrub = true })
function M.decorNode(at: any, nodes: { any }, radius: number): any?
	local best, bestDistance = nil, radius * radius
	for _, node in nodes do
		local p = node.Position
		local d = (p.X - at.X) ^ 2 + (p.Z - at.Z) ^ 2
		if d <= bestDistance then
			best, bestDistance = node, d
		end
	end
	return best
end

-- p134 v51: three 5-17 min spells where every tap and swipe did nothing. The old gesture counted
-- fingers with a bare counter; one touch whose InputEnded never arrived (the dev console, chat or a
-- CoreGui overlay took it) left the count at 1, so every later touch was a "second finger" (pinch)
-- that never tapped or steered until a respawn cancelled it. Touches are now tracked by id, and a
-- touch the engine already ended (`live(id)` false) is dropped before a new one begins.
-- p134 v54/v55: after a tap on the Roblox Backpack hotbar (the knife, then the bola, got selected)
-- ground taps did nothing for ~1 min. A CoreGui hotbar touch never reaches PlayerGui, its end can
-- be swallowed, and its InputObject can stay frozen in Begin (an engine bug), so the liveness probe
-- kept it and every later tap was a pinch's second finger. A finger that sent no begin/move for
-- STALE_TOUCH seconds no longer counts as down once a new touch begins (`clock` given): a real
-- pinch moves, and a resting thumb plus a tap now walks instead of freezing input.
M.STALE_TOUCH = 1.5
function M.gesture(live: ((any) -> boolean)?, clock: (() -> number)?)
	local active: { [any]: number } = {}
	local session: { id: any, x: number, y: number, ui: boolean, dragging: boolean, multi: boolean }? = nil
	local g = {}
	local function now(): number
		return if clock then clock() else 0
	end
	local function prune()
		local at = now()
		for id, seen in active do
			if (live and not live(id)) or (clock and at - seen > M.STALE_TOUCH) then
				active[id] = nil
				if session and session.id == id then
					session = nil
				end
			end
		end
	end
	function g.began(id: any, x: number, y: number, overUi: boolean)
		prune()
		active[id] = now()
		local first = next(active)
		if next(active, first) == nil then
			session = { id = id, x = x, y = y, ui = overUi, dragging = false, multi = false }
		elseif session then
			session.multi = true
		end
	end
	function g.moved(id: any, x: number, y: number): string?
		if active[id] then
			active[id] = now()
		end
		local s = session
		if not s or s.id ~= id or s.ui or s.multi then
			return nil
		end
		if not s.dragging and (x - s.x) ^ 2 + (y - s.y) ^ 2 > M.TAP_SLOP * M.TAP_SLOP then
			s.dragging = true
		end
		return if s.dragging then "steer" else nil
	end
	function g.ended(id: any, x: number, y: number): string?
		active[id] = nil
		local s = session
		if not s or s.id ~= id then
			return nil
		end
		session = nil
		if s.dragging then
			return "release"
		end
		if s.ui or s.multi or (x - s.x) ^ 2 + (y - s.y) ^ 2 > M.TAP_SLOP * M.TAP_SLOP then
			return nil
		end
		return "tap"
	end
	function g.steering(): boolean
		local s = session
		return s ~= nil and s.dragging and not s.multi
	end
	function g.origin(): (number?, number?)
		local s = session
		return if s then s.x else nil, if s then s.y else nil
	end
	function g.cancel()
		table.clear(active)
		session = nil
	end
	return g
end

-- True when screen point (x, y) is over interactive or opaque UI; the camera's pinch uses it too, so
-- a finger that lands on a button never zooms and a finger on the world never presses a button.
function M.overUi(player: Player, x: number, y: number): boolean
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if not gui then
		return false
	end
	for _, object in gui:GetGuiObjectsAtPosition(x, y) do
		local screen = object:FindFirstAncestorWhichIsA("LayerCollector")
		-- Decoration that opts out (the combat vignette corners) never swallows a world tap: an
		-- engaged player could not tap a second creature under a corner (D2b R08 retarget).
		if
			object.Visible
			and object:GetAttribute("ForgeTapThrough") ~= true
			and (not screen or not screen:IsA("ScreenGui") or screen.Enabled)
			and (object:IsA("GuiButton") or object.Active or object.BackgroundTransparency < 1)
		then
			return true
		end
	end
	return false
end

function M.start(options: { player: Player, blocked: () -> boolean, eligible: ((Model) -> boolean)? })
	local moveKeys = { W = 1, A = 1, S = 1, D = 1, Up = 1, Down = 1, Left = 1, Right = 1 }
	local UserInputService = game:GetService("UserInputService")
	local RunService = game:GetService("RunService")
	local PathfindingService = game:GetService("PathfindingService")
	local CollectionService = game:GetService("CollectionService")
	local world = game:GetService("Workspace")
	local player = options.player
	local router = M.new()
	-- A touch InputObject the engine ended or cancelled is no longer a finger on the glass.
	local gesture = M.gesture(function(id: any): boolean
		if typeof(id) ~= "Instance" then
			return true
		end
		local state = (id :: InputObject).UserInputState
		return state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change
	end, os.clock)
	local connections: { RBXScriptConnection } = {}
	local function on(signal: RBXScriptSignal, fn: (...any) -> ())
		table.insert(connections, signal:Connect(fn))
	end
	local serial = 0
	local steer: Vector3? = nil
	local marker = Instance.new("Part")
	marker.Name, marker.Shape = "ForgeTapMarker", Enum.PartType.Cylinder
	marker.Size, marker.Color, marker.Material =
		Vector3.new(0.2, 3, 3), Color3.fromRGB(110, 196, 178), Enum.Material.Neon
	marker.Anchored, marker.CanCollide, marker.CanQuery, marker.CanTouch = true, false, false, false
	marker.CastShadow, marker.Transparency = false, 0.25

	local function body(): (Humanoid?, BasePart?)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
			return humanoid, root
		end
		return nil, nil
	end
	local function flatDistance(a: Vector3, b: Vector3): number
		return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
	end
	local function stop()
		serial += 1
		marker.Parent = nil
		local humanoid, root = body()
		if humanoid and root then
			humanoid:MoveTo(root.Position)
		end
	end
	-- A tap the shore stop refuses flashes the marker red where the finger landed.
	local function flash(at: Vector3)
		serial += 1
		local mine = serial
		marker.Color = Color3.fromRGB(214, 84, 70)
		marker.CFrame = CFrame.new(at + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
		marker.Parent = world
		task.delay(0.35, function()
			if mine == serial then
				marker.Parent = nil
			end
		end)
	end
	local landParams = RaycastParams.new()
	landParams.FilterType = Enum.RaycastFilterType.Exclude
	landParams.IgnoreWater = false
	local function isLand(x: number, z: number): boolean
		landParams.FilterDescendantsInstances = if player.Character then { player.Character } else {}
		local hit = world:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), landParams)
		return hit ~= nil and not (hit.Instance == world.Terrain and hit.Material == Enum.Material.Water)
	end
	local function moveTo(goal: Vector3, arrive: number?, onArrive: (() -> ())?)
		serial += 1
		marker.Color = Color3.fromRGB(110, 196, 178)
		local mine = serial
		marker.CFrame = CFrame.new(goal + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
		marker.Parent = world
		task.spawn(function()
			local humanoid, root = body()
			if not humanoid or not root then
				return
			end
			local path = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 5,
				AgentCanJump = true,
				Costs = { Water = math.huge },
			})
			local ok = pcall(function()
				path:ComputeAsync(root.Position, goal)
			end)
			local points = {}
			if ok and path.Status == Enum.PathStatus.Success then
				for _, waypoint in path:GetWaypoints() do
					table.insert(points, {
						position = waypoint.Position,
						jump = waypoint.Action == Enum.PathWaypointAction.Jump,
					})
				end
			end
			local route = M.route(if ok then path.Status.Name else "Error", points, goal)
			local within = arrive or 1
			for _, step in route do
				if mine ~= serial or flatDistance(root.Position, goal) <= within then
					break
				end
				if step.jump then
					humanoid.Jump = true
				end
				humanoid:MoveTo(step.position)
				local finished: boolean? = nil
				local done = humanoid.MoveToFinished:Once(function(reached)
					finished = reached
				end)
				while finished == nil and mine == serial and flatDistance(root.Position, goal) > within do
					RunService.Heartbeat:Wait()
				end
				done:Disconnect()
				if finished == false then
					break
				end
			end
			if mine ~= serial then
				return
			end
			marker.Parent = nil
			if flatDistance(root.Position, goal) <= within then
				humanoid:MoveTo(root.Position)
			end
			if onArrive then
				onArrive()
			end
		end)
	end

	local function overUi(x: number, y: number): boolean
		return M.overUi(player, x, y)
	end
	local function pick(camera: Camera, x: number, y: number, items: { Instance }, anchor: (Instance) -> BasePart?)
		local list = {}
		for _, item in items do
			local part = anchor(item)
			if part then
				local point, visible = camera:WorldToScreenPoint(part.Position)
				table.insert(list, { target = item, x = point.X, y = point.Y, visible = visible and point.Z > 0 })
			end
		end
		return M.nearest(x, y, list, M.PICK_RADIUS)
	end
	local function alive(model: Instance): boolean
		local hp = model:GetAttribute("ForgeWildlifeHealthMilli")
		return model:IsA("Model")
			and type(model:GetAttribute("ForgeWildlifeId")) == "string"
			and (type(hp) ~= "number" or hp > 0)
	end
	-- p134 v53: a body the local player killed stays tappable (walk there, open the harvest picker);
	-- before, a dead creature fell through to a ground tap and the carcass could not be reopened.
	local function carcass(model: Instance): boolean
		return model:IsA("Model")
			and type(model:GetAttribute("ForgeWildlifeId")) == "string"
			and model:GetAttribute("ForgeWildlifeHealthMilli") == 0
			and model:GetAttribute("ForgeWildlifeKiller") == tostring(player.UserId)
	end
	-- C4: the player's own deployed pet is a creature target too (the pet ring opens on it).
	local function ownPet(model: Instance): boolean
		return model:IsA("Model") and model:GetAttribute("ForgePetOwner") == tostring(player.UserId)
	end
	local function probe(x: number, y: number): Probe?
		local camera = world.CurrentCamera
		local _, root = body()
		if not camera or not root then
			return nil
		end
		local ray = camera:ScreenPointToRay(x, y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = if player.Character then { player.Character } else {}
		local hit = world:Raycast(ray.Origin, ray.Direction * 2000, params)
		local creature: any, node: any = nil, nil
		local ancestor: Instance? = hit and hit.Instance
		while ancestor and ancestor ~= world do
			if not creature and (alive(ancestor) or carcass(ancestor) or ownPet(ancestor)) then
				creature = ancestor
			end
			if not node and ancestor:IsA("BasePart") and CollectionService:HasTag(ancestor, "ForgeSurvivalNode") then
				node = ancestor
			end
			ancestor = ancestor.Parent
		end
		local folder = world:FindFirstChild("ForgeWildlife")
		local candidates = if folder then folder:GetChildren() else {}
		local petFolder = world:FindFirstChild("ForgePets")
		for _, model in if petFolder then petFolder:GetChildren() else {} do
			table.insert(candidates, model)
		end
		-- The fingertip pick is automatic: a live wild creature far above the player is never picked
		-- for a tap beside it (p134 v55: taps by a dodo engaged the Lv 20 parasaurolophus). A ray
		-- that hits the creature itself (above) is the player's choice and always wins.
		local eligible = options.eligible
		creature = creature
			or pick(camera, x, y, candidates, function(model)
				local anchor = model:FindFirstChild("HumanoidRootPart")
				local wanted = carcass(model)
					or ownPet(model)
					or (alive(model) and (not eligible or eligible(model :: Model)))
				return if wanted and anchor and anchor:IsA("BasePart") then anchor else nil
			end)
		if not node then
			-- Fingertip pick on the node part and on its kit pieces (the visible bush or rock).
			local byId: { [string]: BasePart } = {}
			local parents: { [Instance]: boolean } = {}
			local list = {}
			for _, part in CollectionService:GetTagged("ForgeSurvivalNode") do
				local id = part:GetAttribute("ForgeNodeId")
				if part:IsA("BasePart") and part:IsDescendantOf(world) and type(id) == "string" then
					byId[id] = part
					table.insert(list, { owner = part, at = part.Position })
					if part.Parent then
						parents[part.Parent] = true
					end
				end
			end
			for parent in parents do
				for _, child in parent:GetChildren() do
					local id = M.kitOwner(child.Name)
					local owner = id and byId[id]
					if owner then
						local at = if child:IsA("BasePart")
							then child.Position
							elseif child:IsA("Model") then child:GetPivot().Position
							else nil
						if at then
							table.insert(list, { owner = owner, at = at })
						end
					end
				end
			end
			local screen = {}
			for _, entry in list do
				local point, visible = camera:WorldToScreenPoint(entry.at)
				table.insert(
					screen,
					{ target = entry.owner, x = point.X, y = point.Y, visible = visible and point.Z > 0 }
				)
			end
			node = M.nearest(x, y, screen, M.PICK_RADIUS)
		end
		local decor: string? = nil
		local family = if hit and not node then hit.Instance:GetAttribute("ForgeKitFamily") else nil
		if hit and type(family) == "string" and M.DECOR_FAMILIES[family] then
			local nodes = {}
			for _, part in CollectionService:GetTagged("ForgeSurvivalNode") do
				if part:IsA("BasePart") and part:IsDescendantOf(world) then
					table.insert(nodes, part)
				end
			end
			node = M.decorNode(hit.Position, nodes, M.DECOR_RADIUS)
			decor = if node then nil else family
		end
		local ground: Vector3? = hit and hit.Position
		if not ground and math.abs(ray.Direction.Y) > 1e-3 then
			local t = (root.Position.Y - 3 - ray.Origin.Y) / ray.Direction.Y
			ground = if t > 0 then ray.Origin + ray.Direction * t else nil
		end
		return { overUi = false, creature = creature, node = node, decor = decor, ground = ground }
	end
	local function tap(x: number, y: number, ui: boolean)
		if options.blocked() then
			return
		end
		if ui then
			router.dispatch({ overUi = true })
			return
		end
		local found = probe(x, y)
		if found then
			router.dispatch(found)
		end
	end
	router.register("ground", function(position: Vector3)
		local _, root = body()
		if not root then
			return true
		end
		-- Ground taps stop at the shore: never walk into the sea.
		local x, z = M.shore(root.Position, position, isLand)
		if x and z then
			moveTo(if x == position.X and z == position.Z then position else Vector3.new(x, position.Y, z))
		else
			flash(position)
		end
		return true
	end)

	local function release()
		steer = nil
		local humanoid = body()
		if humanoid then
			humanoid:Move(Vector3.zero, false)
		end
	end
	on(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if input.UserInputType == Enum.UserInputType.Touch then
			gesture.began(input, input.Position.X, input.Position.Y, overUi(input.Position.X, input.Position.Y))
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			gesture.began(
				"mouse",
				input.Position.X,
				input.Position.Y,
				processed or overUi(input.Position.X, input.Position.Y)
			)
		elseif not processed and moveKeys[input.KeyCode.Name] and not UserInputService:GetFocusedTextBox() then
			stop()
		end
	end)
	on(UserInputService.InputChanged, function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local wasSteering = gesture.steering()
		if gesture.moved(input, input.Position.X, input.Position.Y) ~= "steer" then
			if wasSteering then
				release()
			end
			return
		end
		if options.blocked() then
			release()
			return
		end
		local camera = world.CurrentCamera
		if not camera then
			return
		end
		if not wasSteering then
			stop()
		end
		local right, look = camera.CFrame.RightVector, camera.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		flatLook = if flatLook.Magnitude > 1e-3 then flatLook.Unit else Vector3.new(0, 0, -1)
		local ox, oy = gesture.origin()
		local dx, dz = M.steer(
			input.Position.X - (ox or input.Position.X),
			input.Position.Y - (oy or input.Position.Y),
			{ x = right.X, z = right.Z },
			{ x = flatLook.X, z = flatLook.Z }
		)
		steer = if dx and dz then Vector3.new(dx, 0, dz) else nil
	end)
	on(UserInputService.InputEnded, function(input: InputObject)
		local id: any = if input.UserInputType == Enum.UserInputType.Touch
			then input
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 then "mouse"
			else nil
		if id == nil then
			return
		end
		local ui = id ~= "mouse" and overUi(input.Position.X, input.Position.Y)
		local result = gesture.ended(id, input.Position.X, input.Position.Y)
		if result == "tap" then
			tap(input.Position.X, input.Position.Y, ui)
		elseif result == "release" then
			release()
		end
	end)
	on(RunService.RenderStepped, function()
		local direction = steer
		if direction and gesture.steering() then
			local humanoid = body()
			if humanoid then
				humanoid:Move(direction, false)
			end
		end
	end)
	-- The app or a text box (chat, the dev console) took the input: any touch in flight may never
	-- report its end to us, so start clean.
	local function lost()
		gesture.cancel()
		release()
	end
	on(UserInputService.WindowFocusReleased, lost)
	on(UserInputService.TextBoxFocused, lost)
	on(UserInputService.TextBoxFocusReleased, lost)
	-- The Roblox menu swallows every input while open, the end of a finger already down included.
	on(game:GetService("GuiService").MenuOpened, lost)
	on(player.CharacterAdded, function()
		serial += 1
		marker.Parent = nil
		steer = nil
		gesture.cancel()
	end)
	-- A walk toward a world point that stops at the shore (the combat loop's approach). p134 v58/v59
	-- and Studio D2: the loop followed a fleeing dodo into the sea (x -423, -172/-378, -760). Returns
	-- false when no land lies toward the goal (nothing to walk to).
	local function moveAshore(goal: Vector3, arrive: number?, onArrive: (() -> ())?): boolean
		local _, root = body()
		if not root then
			return false
		end
		local x, z = M.shore(root.Position, goal, isLand)
		if not x or not z then
			return false
		end
		moveTo(if x == goal.X and z == goal.Z then goal else Vector3.new(x, goal.Y, z), arrive, onArrive)
		return true
	end
	return {
		register = router.register,
		moveTo = moveTo,
		moveAshore = moveAshore,
		stop = stop,
		destroy = function()
			for _, connection in connections do
				connection:Disconnect()
			end
			table.clear(connections)
			serial += 1
			marker:Destroy()
		end,
	}
end

M.REACH = 6
--- Node and creature tap actions. With `combat` (CombatHud.start's api) a creature tap engages the
--- semi-automatic attack loop and a ground tap pauses it; without it a creature tap walks up and
--- sends one attack. With `gather` (the C2 picker's open) a node tap opens the gather radial;
--- without it (or when it declines) the node's ForgeGather prompt is triggered. With `notice`, a tap
--- on scenery rock or tree with no gather node beside it shows that line (the walk still runs).
--- Returns the remover and `send(action, args)`, the durable command sender the combat loop and
--- the carcass picker use.
function M.installActions(
	tap: any,
	transport: any,
	combat: any?,
	gather: ((BasePart) -> boolean)?,
	notice: ((string) -> ())?
): (() -> (), (string, { any }) -> any)
	local CommandTransport = transport
	local storage = game:GetService("ReplicatedStorage")
	local http = game:GetService("HttpService")
	local action = storage:WaitForChild("ForgeAction") :: RemoteFunction
	local state = storage:WaitForChild("ForgeState") :: RemoteEvent
	local durable: any = nil
	local pending: any = nil
	local sending = false
	local connection = state.OnClientEvent:Connect(function(packet)
		if type(packet) == "table" and packet.durable then
			durable = packet.durable
		end
	end)
	-- One durable request in flight; an unsettled request is retried with the same id before any other.
	local function invoke(): any
		sending = true
		local ok, result = pcall(function()
			return action:InvokeServer("command", pending)
		end)
		sending = false
		local data = ok and type(result) == "table" and result.data
		local busy = not ok
			or type(result) ~= "table"
			or result.reason == "COMMAND_PENDING"
			or type(data) == "table" and data.status == "recovering"
		pending = if busy then CommandTransport.settle(pending, result) else nil
		return if ok then result else { ok = false, reason = "TRANSPORT" }
	end
	local function send(verb: string, args: { any }): any
		if sending then
			return { ok = false, reason = "COMMAND_PENDING" }
		end
		local epoch = if durable and durable.epochs then durable.epochs[verb] else durable and durable.sessionEpoch
		if not CommandTransport.durable(durable, verb) or type(epoch) ~= "number" then
			return { ok = false, reason = "COMMAND_UNAVAILABLE" }
		end
		if pending and (pending.action ~= verb or table.concat(pending.args, "\0") ~= table.concat(args, "\0")) then
			-- D2b R08: an attack the server answered COMMAND_PENDING (an earlier swing still settling)
			-- is kept, and once the player retargeted nothing re-sent it, so every swing at the next
			-- creature (and every carcass take) was refused locally forever. Re-send the unsettled
			-- request with its own id first; only once it settles does the new one go out.
			invoke()
			if pending then
				return { ok = false, reason = "COMMAND_PENDING" }
			end
		end
		pending = CommandTransport.request(pending, verb, args, epoch, function()
			return http:GenerateGUID(false)
		end)
		return invoke()
	end
	local removeNode = tap.register("node", function(part: BasePart)
		local prompt = part:FindFirstChild("ForgeGather")
		local function fallback()
			if prompt and prompt:IsA("ProximityPrompt") and prompt.Parent and prompt.Enabled then
				prompt:InputHoldBegin()
				prompt:InputHoldEnd()
			end
		end
		if gather then
			-- C2: the gather radial opens client-side (no prompt, no server round trip); in reach it
			-- opens at once, else after the walk. The picker sends the gather once an output is picked.
			local function open()
				if part.Parent and not gather(part) then
					fallback()
				end
			end
			local character = game:GetService("Players").LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local gap = if root and root:IsA("BasePart")
				then Vector3.new(root.Position.X - part.Position.X, 0, root.Position.Z - part.Position.Z).Magnitude
				else math.huge
			if gap <= M.REACH then
				open()
			else
				tap.moveTo(part.Position, M.REACH, open)
			end
			return true
		end
		if not prompt or not prompt:IsA("ProximityPrompt") then
			return false
		end
		tap.moveTo(part.Position, M.REACH, fallback)
		return true
	end)
	local removeCreature = tap.register("creature", function(model: Model)
		local anchor = model:FindFirstChild("HumanoidRootPart")
		local id = model:GetAttribute("ForgeWildlifeId")
		if not anchor or not anchor:IsA("BasePart") or type(id) ~= "string" then
			return false
		end
		-- The local player's carcass (marked in the world): walk there from any distance, then the
		-- harvest picker opens on arrival (CombatHud.harvest). Never an attack on a dead body.
		if model:GetAttribute("ForgeWildlifeHealthMilli") == 0 then
			return combat ~= nil and combat.harvest ~= nil and combat.harvest(model)
		end
		if combat then
			return combat.engage(model)
		end
		tap.moveTo(anchor.Position, M.REACH, function()
			if model.Parent then
				task.spawn(send, "survival-coop:attack", { id })
			end
		end)
		return true
	end)
	local removeDecor = tap.register("decor", function(family: string)
		if notice then
			notice(family)
		end
		return false
	end)
	-- A ground tap walks away on purpose: pause the auto loop, then let the move handler run.
	local removeGround = tap.register("ground", function()
		if combat then
			combat.pause()
		end
		return false
	end)
	return function()
		removeNode()
		removeDecor()
		removeCreature()
		removeGround()
		connection:Disconnect()
	end,
		send
end

return M
