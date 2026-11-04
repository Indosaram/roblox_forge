--!strict
-- OpeningDirector: server owner of the C1 opening on the onboarding island (opening-script.md).
-- Every step completes from server facts (tutorial state, bag, positions, the player's accepted
-- dodge window, server prompts); the client only stages what the published view says. The
-- scripted boar is presentation only: no wildlife entity, no damage path. A returning player
-- (tutorial complete, no opening record) is bypassed and never sees a beat.
--
-- Set pieces are composed multi-part models tagged `ForgeSetPiece` with a `ForgeSetPieceId`
-- attribute (town.beacon-tower, town.boat); RoleWorld adds the B3 mesh row by that id when the
-- town kit loads and hides the parts (the prompts stay on Pole, Hull and the stakes).
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local Scene = require(Forge.games["robango-island"].src.shared.OpeningScene)
local M = {}

M.SET_PIECE_TAG = "ForgeSetPiece"
-- Player attribute "<REASON>#<n>": the latest refused opening prompt (the client toasts it).
M.REFUSAL_ATTRIBUTE = "ForgeOpeningRefusal"
M.NEAR_FORD, M.NEAR_MARIT = 30, 20
-- Stake prompt reach: from one stake the next one (8-9 studs apart) is still in reach; inside the
-- server's 12-stud part reach (SurvivalWorld.nearPart).
M.STAKE_REACH = 12
-- Beacon prompt reach (flat studs from the pole): the tower legs splay 2.4 studs out.
M.BEACON_REACH = 10
-- opening.mirror row: the pane centre sits 3.9 studs over the tripod's ground pivot (L5 ROWS).
M.MIRROR_PANE = 3.9

--- L5 mesh rows for the stakes and the mirror. `dress(part, key, ground)` hangs a row visual under
--- a gameplay part and returns it (nil when the row is missing). A dressed stake keeps its peg
--- Part as the invisible prompt handle (its cap, lashing and guy line hide too); the mirror Part
--- moves to the pane centre and turns invisible, so the client glint light anchors on the pane.
function M.dressProps(api: any, dress: (BasePart, string, CFrame) -> Instance?)
	for _, stake in api.stakes do
		local ground = stake.Position - Vector3.new(0, stake.Size.Y / 2, 0)
		local visual = dress(stake, "opening.stake", CFrame.new(ground))
		if visual then
			for _, item in stake:GetDescendants() do
				if item:IsA("BasePart") and not item:IsDescendantOf(visual) then
					item.Transparency = 1
				end
			end
		end
	end
	local mirror = api.mirror
	local ground = mirror.Position - Vector3.new(0, mirror.Size.Y / 2, 0)
	if dress(mirror, "opening.mirror", CFrame.new(ground)) then
		mirror.Position = ground + Vector3.new(0, M.MIRROR_PANE, 0)
		mirror.Transparency = 1
	end
end

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
	local function prompt(
		target: BasePart,
		name: string,
		key: string,
		object: string,
		hold: number,
		reach: number?
	): ProximityPrompt
		local value = Instance.new("ProximityPrompt")
		value.Name, value.HoldDuration, value.RequiresLineOfSight = name, hold, false
		value.MaxActivationDistance = reach or 8
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
		-- D2 (R04): a split peg with a rope lashing and a guy line, not one block.
		local top = stake.Position + Vector3.new(0, 1.1, 0)
		local cap =
			block("Cap", top + Vector3.new(0, 0.2, 0), Vector3.new(0.8, 0.4, 0.8), Color3.fromRGB(98, 72, 46), stake)
		cap.Material = Enum.Material.Wood
		local lash = block(
			"Lashing",
			top - Vector3.new(0, 0.5, 0),
			Vector3.new(0.75, 0.3, 0.75),
			Color3.fromRGB(196, 170, 120),
			stake
		)
		lash.Material = Enum.Material.Fabric
		local line = block("GuyLine", top, Vector3.new(0.12, 0.12, 4), Color3.fromRGB(196, 170, 120), stake)
		line.Material = Enum.Material.Fabric
		line.CFrame = CFrame.new(top + Vector3.new(0, 0.6, -1.8)) * CFrame.Angles(math.rad(-20), 0, 0)
		for _, piece in { cap, lash, line } do
			piece.CanCollide, piece.CanQuery, piece.CanTouch = false, false, false
		end
		stakes[index] = stake
	end
	-- Mirror beacon tower (town.beacon-tower): four tapered legs with braces, a plank deck, the
	-- iron fire basket and the mirror crown. RoleWorld swaps in the B3 mesh row when it loads.
	local beacon = setPiece("OpeningBeacon", "town.beacon-tower")
	local base = ground("opening.beacon", 0)
	local timber = Color3.fromRGB(110, 84, 58)
	local pole = block("Pole", base + Vector3.new(0, 4, 0), Vector3.new(1.2, 8, 1.2), timber, beacon)
	pole.Material = Enum.Material.Wood
	for _, corner in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local foot = base + Vector3.new(corner[1] * 2.4, 0, corner[2] * 2.4)
		local head = base + Vector3.new(corner[1] * 1.1, 8, corner[2] * 1.1)
		local leg = block("Leg", (foot + head) / 2, Vector3.new(0.5, (head - foot).Magnitude, 0.5), timber, beacon)
		leg.Material = Enum.Material.Wood
		leg.CFrame = CFrame.lookAt((foot + head) / 2, head) * CFrame.Angles(math.rad(90), 0, 0)
	end
	for _, level in { 2.5, 5.5 } do
		local reach = 2.4 - level / 8 * 1.3
		for _, side in { -1, 1 } do
			block(
				"BraceX",
				base + Vector3.new(0, level, side * reach),
				Vector3.new(reach * 2, 0.3, 0.3),
				timber,
				beacon
			).Material =
				Enum.Material.Wood
			block(
				"BraceZ",
				base + Vector3.new(side * reach, level, 0),
				Vector3.new(0.3, 0.3, reach * 2),
				timber,
				beacon
			).Material =
				Enum.Material.Wood
		end
	end
	block("Deck", base + Vector3.new(0, 8.1, 0), Vector3.new(3.6, 0.3, 3.6), Color3.fromRGB(150, 112, 72), beacon).Material =
		Enum.Material.WoodPlanks
	block("Basket", base + Vector3.new(0, 8.6, 0), Vector3.new(3, 1.2, 3), Color3.fromRGB(74, 61, 49), beacon)
	block("Coals", base + Vector3.new(0, 9.2, 0), Vector3.new(2.4, 0.3, 2.4), Color3.fromRGB(58, 44, 36), beacon).Material =
		Enum.Material.Slate
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
	-- Composed hull (keel, tapered bow and stern, gunwales, thwarts), mast, boom and sail.
	local boat = setPiece("OpeningGannet", "town.boat")
	local mooring = ground("opening.jetty", 0) + Vector3.new(0, 1.5, -10)
	local planks = Color3.fromRGB(74, 61, 49)
	local canvas = Color3.fromRGB(237, 230, 214)
	local hull = block("Hull", mooring, Vector3.new(6, 2, 16), planks, boat)
	hull.Material = Enum.Material.WoodPlanks
	block("Keel", mooring - Vector3.new(0, 1.2, 0), Vector3.new(1, 0.6, 18), Color3.fromRGB(58, 46, 36), boat).Material =
		Enum.Material.Wood
	for _, side in { -1, 1 } do
		local tip = block("Bow", mooring + Vector3.new(0, 0.2, side * 9.2), Vector3.new(4.2, 2.2, 2.4), planks, boat)
		tip.Material = Enum.Material.WoodPlanks
		tip.CFrame = CFrame.new(tip.Position) * CFrame.Angles(0, math.rad(45), 0)
		block(
			"Gunwale",
			mooring + Vector3.new(side * 3.1, 1.15, 0),
			Vector3.new(0.4, 0.3, 16.4),
			Color3.fromRGB(122, 92, 60),
			boat
		).Material =
			Enum.Material.Wood
		block(
			"Thwart",
			mooring + Vector3.new(0, 0.9, side * 4),
			Vector3.new(5.6, 0.3, 1),
			Color3.fromRGB(122, 92, 60),
			boat
		).Material =
			Enum.Material.Wood
	end
	block("Mast", mooring + Vector3.new(0, 6, 0), Vector3.new(0.6, 10, 0.6), canvas, boat)
	block("Boom", mooring + Vector3.new(0, 2.6, 3), Vector3.new(0.4, 0.4, 6), Color3.fromRGB(122, 92, 60), boat).Material =
		Enum.Material.Wood
	local sail = block("Sail", mooring + Vector3.new(0, 7, 1.5), Vector3.new(0.2, 7, 5), canvas, boat)
	sail.Material = Enum.Material.Fabric
	boat.PrimaryPart = hull
	for _, part in boat:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
		end
	end
	-- A mirror glint source on the ridge (the flash VFX is client-side). RoleWorld hangs the
	-- opening.mirror row under it and lifts it to the pane centre (MIRROR_PANE) once the row loads.
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
	local refusals: { [string]: string } = {}
	local refusalCount = 0
	local syncStakes: () -> () = function() end
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
		syncStakes()
	end
	function api.leave(actor: string)
		flush(actor)
		states[actor], facts[actor], windbreak[actor], dirty[actor] = nil, nil, nil, nil
		refusals[actor] = nil
		syncStakes()
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
	local function onPrompt(
		target: BasePart,
		action: (string, Scene.State, number) -> (boolean, string?),
		flat: number?
	)
		local value = target:FindFirstChildOfClass("ProximityPrompt") :: ProximityPrompt
		value.Triggered:Connect(function(player: Player)
			local actor = tostring(player.UserId)
			local p, state = ports, states[actor]
			if not p or not state or Scene.finished(state) then
				return
			end
			local now = nowMillis()
			local ok: boolean, reason: string? = false, "TOO_FAR"
			-- `flat`: reach by flat distance alone. nearPart's ray to the pole top crossed the tower's own
			-- deck and basket (p134 v74 #5: the beacon refused a player standing at its foot).
			local at = if flat then p.position(actor) else nil
			local close = at ~= nil
				and flat ~= nil
				and (Vector3.new(target.Position.X, at.Y, target.Position.Z) - at).Magnitude <= flat
			if close or p.near(actor, target) then
				ok, reason = action(actor, state, now)
			end
			if ok then
				dirty[actor] = true
				advance(actor, now)
				syncStakes()
				return
			end
			-- p134 C1 dead end 1: a refused pull used to do nothing on screen. The client toasts it
			-- (opening.refusal.*, KO and EN) from this attribute; the counter makes repeats fire.
			refusalCount += 1
			local why = if reason and table.find(Scene.REFUSALS, reason) then reason else "NOT_NOW"
			refusals[actor] = why
			pcall(function()
				player:SetAttribute(M.REFUSAL_ATTRIBUTE, why .. "#" .. refusalCount)
			end)
		end)
	end
	--- Latest prompt refusal reason surfaced to `actor` (nil when none).
	function api.refusal(actor: string): string?
		return refusals[actor]
	end
	-- p134 v74 #2 (phone): a 1.2 s hold prompt ignored taps on the interact token (only a ~2.5 s press
	-- pulled, ~5 min lost), and at 8 studs the next stake (8-9 studs on) was out of reach after a pull, so
	-- the token greyed out until the player moved. A tap pulls now, and the next stake stays in reach.
	local stakePrompts: { ProximityPrompt } = {}
	for index, stake in stakes do
		stakePrompts[index] =
			prompt(stake, "ForgeOpeningStake", "opening.prompt.pull", "opening.tumble.stake", 0, M.STAKE_REACH)
		onPrompt(stake, function(_, state, now)
			return Scene.pull(state, index, now)
		end)
	end
	-- A stake's server prompt is on only while some staged player can pull it now (a solo server: that
	-- player). A pulled stake no longer wins the action button over the next one; each client also
	-- applies its own Scene.stakeMarks locally (fallen visual, glow, its own prompt state).
	syncStakes = function()
		for index, value in stakePrompts do
			local pullable = false
			for actor, state in states do
				local marks = Scene.stakeMarks(Scene.view(state, facts[actor] or { items = {} } :: any))
				pullable = pullable or (marks[index] ~= nil and marks[index].prompt)
			end
			value.Enabled = pullable
		end
	end
	syncStakes()
	-- p134 v74 #5: a 2 s hold the interact token never fires on a tap; a tap lights it now.
	prompt(pole, "ForgeOpeningBeacon", "opening.prompt.light", "opening.prompt.beacon", 0, M.BEACON_REACH)
	onPrompt(pole, function(_, state, now)
		return Scene.lightBeacon(state, now), "NOT_NOW"
	end, M.BEACON_REACH)
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
