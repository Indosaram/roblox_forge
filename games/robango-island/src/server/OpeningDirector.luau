--!strict
-- OpeningDirector: server owner of the C1 opening on the onboarding island (opening-script.md).
-- Every step completes from server facts (tutorial state, bag, positions, the player's accepted
-- dodge window, server prompts); the client only stages what the published view says. The
-- scripted boar is presentation only: no wildlife entity, no damage path. A returning player
-- (tutorial complete, no opening record) is bypassed and never sees a beat.
--
-- Set pieces are primitive placeholders tagged `ForgeSetPiece` with a `ForgeSetPieceId`
-- attribute (town.beacon-tower, town.boat) so the B3 lane can swap meshes by tag.
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local Scene = require(Forge.games["robango-island"].src.shared.OpeningScene)
local M = {}

M.SET_PIECE_TAG = "ForgeSetPiece"
M.NEAR_FORD, M.NEAR_MARIT = 30, 20

export type Ports = {
	tutorial: (actor: string) -> (number?, boolean),
	items: (actor: string) -> { [string]: number }?,
	dodgeAt: (actor: string) -> number?,
	position: (actor: string) -> Vector3?,
	near: (actor: string, part: BasePart) -> boolean,
	store: any, -- ActorDocumentStore (robango-exp-v1): document.opening
	analytics: (actor: string, step: string, index: number, beat: number) -> (),
	travel: (actor: string) -> (boolean, string?),
	spawn: ((() -> ()) -> ())?,
}

function M.new(layout: any, root: Instance, nowMillis: () -> number): any
	local anchors: { [string]: any } = {}
	for _, anchor in layout.anchors do
		anchors[anchor.id] = anchor.position
	end
	local folder = Instance.new("Folder")
	folder.Name = "ForgeOpening"
	folder.Parent = root
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { folder }
	params.IgnoreWater = true
	local function ground(id: string, lift: number): Vector3
		local p = assert(anchors[id], "OPENING_ANCHOR:" .. id)
		local hit = workspace:Raycast(Vector3.new(p.x, p.y + 256, p.z), Vector3.new(0, -512, 0), params)
		return Vector3.new(p.x, (if hit then hit.Position.Y else p.y) + lift, p.z)
	end
	local function block(name: string, at: Vector3, size: Vector3, color: Color3, parent: Instance): BasePart
		local value = Instance.new("Part")
		value.Name, value.Anchored, value.Size, value.Position = name, true, size, at
		value.Material, value.Color = Enum.Material.SmoothPlastic, color
		value.Parent = parent
		return value
	end
	local function prompt(target: BasePart, name: string, key: string, object: string, hold: number): ProximityPrompt
		local value = Instance.new("ProximityPrompt")
		value.Name, value.HoldDuration, value.RequiresLineOfSight = name, hold, false
		value.MaxActivationDistance = 8
		-- The client localizes from the pack strings (opening.prompt.*).
		value:SetAttribute("ForgeOpeningAction", key)
		value:SetAttribute("ForgeOpeningObject", object)
		value.ActionText, value.ObjectText = key, object
		value.Parent = target
		return value
	end
	local function setPiece(name: string, id: string): Model
		local model = Instance.new("Model")
		model.Name = name
		model:SetAttribute("ForgeSetPieceId", id)
		model.Parent = folder
		game:GetService("CollectionService"):AddTag(model, M.SET_PIECE_TAG)
		return model
	end

	local stakes: { BasePart } = {}
	for index = 1, Scene.STAKES do
		local stake = block(
			"OpeningStake" .. index,
			ground("opening.stake." .. index, 1.1),
			Vector3.new(0.6, 2.2, 0.6),
			Color3.fromRGB(122, 92, 60),
			folder
		)
		stake.Material = Enum.Material.Wood
		stake:SetAttribute("ForgeOpeningStake", index)
		stakes[index] = stake
	end
	-- Mirror beacon tower (town.beacon-tower): pole, fire basket, mirror crown.
	local beacon = setPiece("OpeningBeacon", "town.beacon-tower")
	local base = ground("opening.beacon", 0)
	local pole =
		block("Pole", base + Vector3.new(0, 4, 0), Vector3.new(1.2, 8, 1.2), Color3.fromRGB(110, 84, 58), beacon)
	pole.Material = Enum.Material.Wood
	block("Basket", base + Vector3.new(0, 8.6, 0), Vector3.new(3, 1.2, 3), Color3.fromRGB(74, 61, 49), beacon)
	local crown = block(
		"MirrorCrown",
		base + Vector3.new(0, 10.2, 0),
		Vector3.new(2.4, 1.6, 0.3),
		Color3.fromRGB(169, 211, 204),
		beacon
	)
	crown.Material = Enum.Material.Glass
	beacon.PrimaryPart = pole
	-- The supply cutter Gannet (town.boat), moored at the jetty; each client plays its fly-in.
	local boat = setPiece("OpeningGannet", "town.boat")
	local mooring = ground("opening.jetty", 0) + Vector3.new(0, 1.5, -10)
	local hull = block("Hull", mooring, Vector3.new(6, 2, 16), Color3.fromRGB(74, 61, 49), boat)
	hull.Material = Enum.Material.WoodPlanks
	block("Mast", mooring + Vector3.new(0, 6, 0), Vector3.new(0.6, 10, 0.6), Color3.fromRGB(237, 230, 214), boat)
	local sail =
		block("Sail", mooring + Vector3.new(0, 7, 1.5), Vector3.new(0.2, 7, 5), Color3.fromRGB(237, 230, 214), boat)
	sail.Material = Enum.Material.Fabric
	boat.PrimaryPart = hull
	for _, part in boat:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
		end
	end
	-- A mirror glint source on the ridge (the flash VFX is client-side).
	local mirror = block(
		"OpeningMirror",
		ground("opening.mirror-ridge", 1),
		Vector3.new(1.2, 1.2, 0.2),
		Color3.fromRGB(169, 211, 204),
		folder
	)
	mirror.Material = Enum.Material.Glass
	mirror.CanCollide = false

	local ford, marit = anchors["opening.ford"], anchors["npc.marit"]
	local states: { [string]: Scene.State } = {}
	local loading: { [string]: boolean } = {}
	local saving: { [string]: boolean } = {}
	local dirty: { [string]: boolean } = {}
	local windbreak: { [string]: boolean } = {}
	local facts: { [string]: Scene.Facts } = {}
	local ports: Ports? = nil
	local api: any = { folder = folder, stakes = stakes, beacon = beacon, boat = boat, mirror = mirror }

	local function spawn(fn: () -> ())
		local run = ports and ports.spawn
		if run then
			run(fn)
		else
			task.spawn(fn)
		end
	end
	local function flush(actor: string)
		local p = ports
		local state = states[actor]
		if not p or not state or saving[actor] or not dirty[actor] then
			return
		end
		saving[actor], dirty[actor] = true, false
		local saved = Scene.save(state)
		saved.windbreak = windbreak[actor] == true
		spawn(function()
			local ok, result = pcall(p.store.transaction, actor, function(document)
				document.opening = saved
				return { ok = true }
			end)
			saving[actor] = nil
			if not ok or type(result) ~= "table" or not result.ok then
				dirty[actor] = true -- retried on the next tick
			end
		end)
	end
	local function factsFor(actor: string, p: Ports): Scene.Facts?
		local index, complete = p.tutorial(actor)
		local items = p.items(actor)
		if index == nil or items == nil then
			return nil
		end
		local at = p.position(actor)
		local function within(anchor: any, studs: number): boolean
			return at ~= nil and anchor ~= nil and (Vector3.new(anchor.x, at.Y, anchor.z) - at).Magnitude <= studs
		end
		return {
			tutorialIndex = index,
			tutorialComplete = complete,
			items = items,
			nearFord = within(ford, M.NEAR_FORD),
			nearMarit = within(marit, M.NEAR_MARIT),
			windbreak = windbreak[actor] == true,
			dodgeAt = p.dodgeAt(actor),
		}
	end
	local function load(actor: string, p: Ports)
		if states[actor] or loading[actor] then
			return
		end
		local index, complete = p.tutorial(actor)
		if index == nil then
			return
		end
		loading[actor] = true
		spawn(function()
			local ok, document = pcall(p.store.snapshot, actor)
			loading[actor] = nil
			if not ok then
				return -- an unreadable document must not reset a player into the opening; retry
			end
			local saved = if type(document) == "table" then document.opening else nil
			local now = nowMillis()
			local state = Scene.resume(saved, index, complete, now)
			windbreak[actor] = type(saved) == "table" and saved.windbreak == true
			states[actor] = state
			dirty[actor] = saved == nil and not state.bypass
		end)
	end
	local function advance(actor: string, now: number)
		local p, state = ports, states[actor]
		local current = if p and state then factsFor(actor, p) else nil
		if not p or not state or not current then
			return
		end
		facts[actor] = current
		local changed = Scene.advance(state, current, now, function(step, index, beat)
			p.analytics(actor, step, index, beat)
		end)
		if changed then
			dirty[actor] = true
		end
		flush(actor)
	end

	--- Wires the live session ports. Before this nothing is staged.
	function api.bind(value: Ports)
		ports = value
	end
	--- One server tick: loads joined actors, then advances every loaded actor on fresh facts.
	function api.tick(actors: { string }, now: number)
		local p = ports
		if not p then
			return
		end
		for _, actor in actors do
			if not states[actor] then
				load(actor, p)
			else
				advance(actor, now)
			end
		end
	end
	function api.leave(actor: string)
		flush(actor)
		states[actor], facts[actor], windbreak[actor], dirty[actor] = nil, nil, nil, nil
	end
	function api.state(actor: string): Scene.State?
		return states[actor]
	end
	--- Client intents for presentation-only beats; each is checked against the server state.
	function api.intent(actor: string, kind: any): (boolean, string?)
		local state = states[actor]
		local now = nowMillis()
		if not state or Scene.finished(state) then
			return false, "NOT_ACTIVE"
		end
		local ok: boolean, reason: string? = false, "UNKNOWN_INTENT"
		if kind == "cold-open-done" then
			ok, reason = Scene.coldOpenDone(state), "NOT_NOW"
		elseif kind == "mirror-dismiss" then
			ok, reason = Scene.dismissMirror(state), "NOT_NOW"
		elseif kind == "board" then
			local p = ports
			ok, reason = Scene.board(state, now)
			if ok and p then
				local travelled, why = p.travel(actor)
				if not travelled then
					state.boarded = false
					return false, why or "TRAVEL_REFUSED"
				end
			end
		end
		if ok then
			advance(actor, now)
		end
		return ok, if ok then nil else reason
	end
	local function onPrompt(target: BasePart, action: (string, Scene.State, number) -> boolean)
		local value = target:FindFirstChildOfClass("ProximityPrompt") :: ProximityPrompt
		value.Triggered:Connect(function(player: Player)
			local actor = tostring(player.UserId)
			local p, state = ports, states[actor]
			if not p or not state or not p.near(actor, target) then
				return
			end
			local now = nowMillis()
			if action(actor, state, now) then
				dirty[actor] = true
				advance(actor, now)
			end
		end)
	end
	for index, stake in stakes do
		prompt(stake, "ForgeOpeningStake", "opening.prompt.pull", "opening.tumble.stake", 1.2)
		onPrompt(stake, function(_, state, now)
			return (Scene.pull(state, index, now))
		end)
	end
	prompt(pole, "ForgeOpeningBeacon", "opening.prompt.light", "opening.prompt.beacon", 2)
	onPrompt(pole, function(_, state, now)
		return Scene.lightBeacon(state, now)
	end)
	-- Tapping the boat opens the client's boarding card; the card's Board sends the intent.
	prompt(hull, "ForgeOpeningBoard", "opening.beacon.yes", "opening.prompt.boat", 0)

	--- `opening` survival extension: no commands; its snapshot is the per-player view (pushed
	--- with every state packet) and it observes the windbreak donation.
	api.extension = {
		id = "opening",
		handles = function(_action: string): boolean
			return false
		end,
		command = function(): any
			return { ok = false, reason = "NOT_HANDLED" }
		end,
		snapshot = function(actor: string): any
			local state = states[actor]
			if not state then
				return nil
			end
			return Scene.view(state, facts[actor] or { items = {} } :: any)
		end,
		observe = function(actor: string, action: string, args: { any }, result: any)
			if action == "survival-coop:camp-contribute" and result.ok and args[1] == "windbreak" then
				windbreak[actor] = true
				dirty[actor] = true
			end
		end,
	}
	function api.destroy()
		folder:Destroy()
	end
	return api
end

return M
