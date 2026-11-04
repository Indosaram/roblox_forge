--!strict
-- OpeningClient: stages the C1 opening (opening-script.md beats 0-7) from the server's published
-- view (survivalExtensions.opening). It never completes a step: the cold-open end, the mirror
-- card and boarding are intents the server checks (OpeningDirector.intent); every other step is
-- a server fact. Returning players get no view, so nothing here ever runs for them.
-- Presentation randomness is not used: the camera shake is a fixed sine.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Scene = require("./OpeningScene")
local HudShell = require("../../../../genres/survival-coop/module/HudShell")
local HudLocale = require("../../../../genres/survival-coop/module/SurvivalHUDLocale")
local DinosaurRig = require("../../../../genres/survival-coop/module/DinosaurRig")
local CameraConfig = require("./CameraConfig")
local Waypoint = require("./Waypoint")
local CampPanel = require("../../../../genres/survival-coop/module/CampPanel")
local CharacterText = require("../../../../genres/survival-coop/module/CharacterText")
local GuideEvents = require("../../../../genres/survival-coop/module/GuideEvents")
local M = {}

M.COLD_OPEN_SECONDS, M.SKIP_AFTER = 25, 1.0
M.FOLLOW_STUDS = 4
M.WAY_OFFER_SECONDS = 5 -- the tracker tap's 'show the way' pebble stays this long
M.WAY_ARRIVE = 6 -- the walk-to stops this close to the target (inside Waypoint.HIDE_STUDS)
-- Set on the local player while a camp-project step runs: the warehouse crate prompt opens the Camp
-- panel on that project (this module) instead of the storage sheet (RobangoIslandClient).
M.PROJECT_ATTRIBUTE = "ForgeOpeningProject"

--- Whether `item` and every GuiObject above it are visible and its ScreenGui is enabled (the dock
--- hides the quest card's slot, not the card, under the menu grid).
function M.shownChain(item: any): boolean
	local at = item
	while at do
		if at.ClassName == "ScreenGui" then
			return at.Enabled ~= false
		end
		if at.Visible == false then
			return false
		end
		at = at.Parent
	end
	return false
end

--- Beat-0 camera at `t` seconds: pitch, distance, yaw drift (degrees) and shake amplitude.
function M.shot(t: number): (number, number, number, number)
	local shake = if t >= 8 and t < 8.4 then 0.6 else 0
	if t < 8 then
		return 35, 260 - t * 5, 20 + t * 1.5, shake -- high wide shot, slow dolly
	elseif t < 16 then
		return 40, 150, 32, shake -- gust shot over the reef crest
	end
	-- Settle onto the play camera's default framing, so the hand-over to QuarterView does not jump.
	local k = math.clamp((t - 16) / 1.5, 0, 1)
	local pitch, distance = CameraConfig.pitch, CameraConfig.distance
	return 40 + (pitch - 40) * k, 150 + (distance - 150) * k, 32 + (45 - 32) * k, 0
end

--- Caption key at `t` seconds of the cold open.
function M.caption(t: number): string?
	return if t < 8 then "opening.cold.1" elseif t >= 9 and t < 15 then "opening.cold.2" else nil
end

--- Charge progress 0..1 at server time `now` (ms): the slow window plays at SLOW_FACTOR.
function M.chargeProgress(charge: any, now: number): number
	local real = Scene.CHARGE_MILLIS
	local elapsed = now - charge.startAt
	if charge.slow then
		local slowed = math.min(elapsed, Scene.SLOW_MILLIS)
		elapsed = slowed * Scene.SLOW_FACTOR + math.max(0, elapsed - Scene.SLOW_MILLIS)
	end
	return math.clamp(elapsed / real, 0, 1)
end

--- Puts the cold open's Skip in the top-right corner, or beside / under an open sheet (the arrival
--- sheet opens during the cold open) so it never covers that sheet's close X.
function M.placeSkip(skip: any, gui: any, playerGui: any)
	local open = HudShell.openSheet(playerGui)
	local view, origin = gui.AbsoluteSize, gui.AbsolutePosition
	local sheet: any = nil
	if open then
		local at, size = open.AbsolutePosition, open.AbsoluteSize
		sheet = { x = at.X - origin.X, y = at.Y - origin.Y, width = size.X, height = size.Y }
	end
	local header = if open and open:FindFirstChild("Header") then open.Header.AbsoluteSize.Y else 44
	HudShell.put(skip, HudShell.cornerButton(view.X, view.Y, 96, 44, sheet, 64, header))
end

function M.factory(ctx: any): any
	local player = Players.LocalPlayer
	local theme, components = ctx.ui.theme.default, ctx.ui.components
	local text: (string) -> string = ctx.text
	local touch = game:GetService("UserInputService").TouchEnabled
	local function rgb(c: any): Color3
		return Color3.fromRGB(c.r, c.g, c.b)
	end
	local P: { [string]: Color3 } = {}
	for key, value in HudShell.PALETTE :: any do
		P[key] = rgb(value)
	end
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "ForgeOpening", false, 40
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.Parent = player:WaitForChild("PlayerGui")
	local bars: { Frame } = {}
	for index, anchor in { 0, 1 } do
		local bar = Instance.new("Frame")
		bar.Name, bar.BorderSizePixel, bar.BackgroundColor3 = "Letterbox" .. index, 0, Color3.new(0, 0, 0)
		bar.AnchorPoint, bar.Position, bar.Size =
			Vector2.new(0, anchor), UDim2.fromScale(0, anchor), UDim2.fromScale(1, 0.08)
		bar.Visible, bar.Parent = false, gui
		bars[index] = bar
	end
	local caption = components.label(theme, {
		text = "",
		size = UDim2.fromScale(0.7, 0.07),
		position = UDim2.fromScale(0.15, 0.82),
		parent = gui,
	})
	caption.Name, caption.Visible, caption.TextWrapped = "OpeningCaption", false, true
	-- Bottom-centre card (coach lines, mirror signal, herd hint, boarding), 46% wide.
	local card = Instance.new("TextButton")
	card.Name, card.AutoButtonColor, card.Visible = "OpeningCard", false, false
	card.AnchorPoint, card.Position, card.Size =
		Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -16), UDim2.fromScale(0.46, 0.16)
	card.BackgroundColor3, card.TextColor3, card.TextWrapped = P.panel, P.bone, true
	card.Font, card.TextScaled, card.Text = Enum.Font.BuilderSans, true, ""
	local edge = Instance.new("UIStroke")
	edge.Color, edge.Thickness, edge.ApplyStrokeMode, edge.Parent = P.teal, 2, Enum.ApplyStrokeMode.Border, card
	local corner = Instance.new("UICorner")
	corner.CornerRadius, corner.Parent = UDim.new(0, 10), card
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight, pad.PaddingTop, pad.PaddingBottom =
		UDim.new(0, 12), UDim.new(0, 12), UDim.new(0, 6), UDim.new(0, 6)
	pad.Parent = card
	card.Parent = gui
	local cardKind: string? = nil
	local function showCard(kind: string?, body: string?)
		cardKind = kind
		card.Visible, card.Text = kind ~= nil, body or ""
	end
	local skip: TextButton
	local board: TextButton, notYet: TextButton
	-- The Dodge pebble sits on the HUD shell's dodge slot (I1) while the scripted boar charges.
	local dodge = components.button(theme, {
		text = HudLocale.text(ctx.locale, "dodge"),
		size = UDim2.fromOffset(56, 56),
		parent = gui,
		onClick = function()
			ctx.send("survival-coop:dodge", {})
		end,
	})
	dodge.Name, dodge.Visible = "OpeningDodge", false
	local ring = Instance.new("UIStroke")
	ring.Name, ring.Color, ring.Thickness, ring.Parent = "CoachRing", P.coral, 4, dodge
	local tracker = components.label(theme, {
		text = "",
		size = UDim2.fromScale(1, 1),
		parent = ctx.objectiveSlot or gui,
		chip = true,
	})
	tracker.Name, tracker.LayoutOrder, tracker.Visible = "OpeningTracker", 0, false
	tracker.TextWrapped = true
	tracker.TextXAlignment, tracker.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
	-- Compact quest tracker (HUD polish): TextScaled filled the whole slot with 20+ px lines on the
	-- phone (p134 v54 wc0); capped at a label size on a lighter, translucent card.
	tracker.BackgroundTransparency = 0.4
	HudShell.fitQuestText(tracker, nil, touch)

	local view: any = nil
	local function serverNow(): number
		return workspace:GetServerTimeNow() * 1000
	end
	local function intent(kind: string): (boolean, string?)
		local remote = game:GetService("ReplicatedStorage"):FindFirstChild("ForgeOpeningIntent")
		if not remote or not remote:IsA("RemoteFunction") then
			return false, "UNAVAILABLE"
		end
		local ok, accepted, reason = pcall(function()
			return remote:InvokeServer(kind)
		end)
		return ok and accepted == true, if ok then reason else "TRANSPORT_FAILED"
	end
	local function rootPart(): BasePart?
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return if root and root:IsA("BasePart") then root else nil
	end
	local function anchor(id: string): Vector3?
		local layoutId = workspace:FindFirstChild("ForgeRoleWorld")
			and (workspace :: any).ForgeRoleWorld:GetAttribute("ForgeLayoutId")
		for _, layout in (ctx.content and ctx.content.layouts or {}) :: { any } do
			if layout.id == layoutId then
				for _, entry in layout.anchors do
					if entry.id == id then
						return Vector3.new(entry.position.x, entry.position.y, entry.position.z)
					end
				end
			end
		end
		return nil
	end
	local function opening(name: string): Instance?
		local world = workspace:FindFirstChild("ForgeRoleWorld")
		local folder = world and world:FindFirstChild("ForgeOpening")
		return folder and folder:FindFirstChild(name)
	end
	--- World position of the current step's waypoint target (OpeningScene.target), or nil. The
	--- campfire step follows the server's camp grid origin when it publishes one.
	local function wayTarget(): Vector3?
		local id = Scene.target(view)
		if not id then
			return nil
		end
		local world = workspace:FindFirstChild("ForgeRoleWorld")
		if id == "station.campfire.t1" and world then
			local origin = world:GetAttribute("ForgeCampOrigin")
			if typeof(origin) == "Vector3" then
				return origin
			end
		end
		local layoutId = world and world:GetAttribute("ForgeLayoutId")
		return Waypoint.resolve(Waypoint.layout(ctx.content, layoutId), id)
	end

	-- Beat 0: cold open.
	local cold: { start: number, connection: RBXScriptConnection?, cameraType: any }? = nil
	local coldPlayed = false
	local function endCold(skipped: boolean)
		local running = cold
		if not running then
			return
		end
		cold = nil
		if running.connection then
			running.connection:Disconnect()
		end
		for _, bar in bars do
			bar.Visible = false
		end
		caption.Visible, skip.Visible = false, false
		local camera = workspace.CurrentCamera
		camera.CameraType = running.cameraType
		local quarter = ctx.quarterView and ctx.quarterView()
		if quarter then
			quarter.suspend(false)
		end
		task.spawn(function()
			if skipped then
				ctx.send("survival-coop:tutorial-skip-arrival", {})
			end
			intent("cold-open-done")
		end)
	end
	skip = components.button(theme, {
		text = text("opening.skip"),
		size = UDim2.fromOffset(96, 44),
		position = UDim2.new(1, -108, 0.1, 0),
		parent = gui,
		onClick = function()
			endCold(true)
		end,
	})
	skip.Name, skip.Visible = "OpeningSkip", false
	HudShell.pebble(skip, false, true)
	local function startCold()
		if coldPlayed then
			return
		end
		coldPlayed = true
		local camera = workspace.CurrentCamera
		local quarter = ctx.quarterView and ctx.quarterView()
		if quarter then
			quarter.suspend(true)
		end
		local running = { start = os.clock(), connection = nil :: RBXScriptConnection?, cameraType = camera.CameraType }
		cold = running
		camera.CameraType = Enum.CameraType.Scriptable
		for _, bar in bars do
			bar.Visible = true
		end
		running.connection = RunService.RenderStepped:Connect(function()
			local t = os.clock() - running.start
			if t >= M.COLD_OPEN_SECONDS then
				endCold(false)
				return
			end
			skip.Visible = t >= M.SKIP_AFTER
			if skip.Visible then
				M.placeSkip(skip, gui, player:FindFirstChild("PlayerGui"))
			end
			local key = M.caption(t)
			caption.Visible, caption.Text = key ~= nil, if key then text(key) else ""
			local root = rootPart()
			local focus = if root then root.Position else (anchor("entry") or Vector3.zero)
			local pitch, distance, yaw, shake = M.shot(t)
			local p, y = math.rad(pitch), math.rad(yaw)
			local offset = Vector3.new(math.sin(y) * math.cos(p), math.sin(p), math.cos(y) * math.cos(p)) * distance
			local jitter = Vector3.new(math.sin(t * 90), math.sin(t * 70 + 1), 0) * shake
			camera.CFrame = CFrame.lookAt(focus + offset + jitter, focus)
		end)
	end

	-- Beat 1: scripted boar (client-only rig, never a wildlife entity) and Tumble.
	local stage = Instance.new("Folder")
	stage.Name, stage.Parent = "ForgeOpeningLocal", workspace
	local boar: Model? = nil
	local tumble: Model? = nil
	local mark: Highlight? = nil
	local snortUntil = 0
	local function rig(kind: string, at: Vector3): Model
		local model = DinosaurRig.new(kind, "Opening-" .. kind, at, stage)
		for _, piece in model:GetDescendants() do
			if piece:IsA("BasePart") then
				piece.Anchored, piece.CanCollide, piece.CanQuery, piece.CanTouch = true, false, false, false
			end
		end
		return model
	end
	local groundParams = RaycastParams.new()
	groundParams.FilterType, groundParams.IgnoreWater = Enum.RaycastFilterType.Exclude, true
	local function groundY(at: Vector3): number?
		groundParams.FilterDescendantsInstances = { stage, player.Character :: any }
		local hit = workspace:Raycast(Vector3.new(at.X, at.Y + 64, at.Z), Vector3.new(0, -160, 0), groundParams)
		return if hit then hit.Position.Y else nil
	end
	local function placeBoar(model: Model, start: Vector3, target: Vector3, k: number)
		local half = if model.PrimaryPart then model.PrimaryPart.Size.Y / 2 else 1.5
		local x, z = Scene.chargeAt(start.X, start.Z, target.X, target.Z, k)
		local floor = groundY(Vector3.new(x, target.Y, z)) or (target.Y - 3)
		local at = Vector3.new(x, floor + half, z)
		model:PivotTo(CFrame.lookAt(at, Vector3.new(target.X, at.Y, target.Z)))
	end
	local function bubble(model: Model, key: string)
		local head = model.PrimaryPart
		if not head or head:FindFirstChild("OpeningBubble") then
			return
		end
		local board_ = Instance.new("BillboardGui")
		board_.Name, board_.Size, board_.StudsOffset = "OpeningBubble", UDim2.fromOffset(140, 30), Vector3.new(0, 3, 0)
		local label = Instance.new("TextLabel")
		label.Size, label.BackgroundColor3, label.TextColor3 = UDim2.fromScale(1, 1), P.bone, P.ink
		label.TextScaled, label.Text, label.Parent = true, text(key), board_
		board_.Parent = head
	end

	-- Beat 7: the Gannet's fly-in plays locally from the server's boatAt.
	local boatHome: CFrame? = nil
	local function placeBoat(now: number)
		local boat = opening("OpeningGannet")
		if not boat or not boat:IsA("Model") then
			return
		end
		boatHome = boatHome or boat:GetPivot()
		local home = boatHome :: CFrame
		local offshore = home * CFrame.new(0, 0, -160)
		local arrive = if view then view.boatAt else nil
		if arrive == nil then
			boat:PivotTo(offshore)
		else
			local k = math.clamp(1 - (arrive - now) / Scene.BOAT_MILLIS, 0, 1)
			boat:PivotTo(offshore:Lerp(home, k * k * (3 - 2 * k)))
		end
	end

	board = components.button(theme, {
		text = text("opening.beacon.yes"),
		size = UDim2.fromOffset(110, 44),
		position = UDim2.new(0.5, -116, 1, -150),
		parent = gui,
		onClick = function()
			showCard(nil)
			board.Visible, notYet.Visible = false, false
			task.spawn(function()
				local ok, reason = intent("board")
				if not ok then
					showCard("notice", tostring(reason))
					task.delay(4, function()
						if cardKind == "notice" then
							showCard(nil)
						end
					end)
				end
			end)
		end,
	})
	notYet = components.button(theme, {
		text = text("opening.beacon.no"),
		size = UDim2.fromOffset(110, 44),
		position = UDim2.new(0.5, 6, 1, -150),
		parent = gui,
		onClick = function()
			showCard(nil)
			board.Visible, notYet.Visible = false, false
		end,
	})
	for _, button in { board, notYet } do
		button.Visible = false
		HudShell.pebble(button, button == board, true)
	end
	card.Activated:Connect(function()
		if cardKind == "mirror" then
			showCard(nil)
			task.spawn(intent, "mirror-dismiss")
		end
	end)
	local connections: { RBXScriptConnection } = {}
	table.insert(
		connections,
		game:GetService("ProximityPromptService").PromptTriggered:Connect(function(prompt, actor)
			if actor == player and prompt.Name == "ForgeOpeningBoard" and view and view.step == "board" then
				showCard("board", text("opening.beacon.confirm"))
				board.Visible, notYet.Visible = true, true
			end
		end)
	)
	local function localize(object: Instance)
		if object:IsA("ProximityPrompt") and object:GetAttribute("ForgeOpeningAction") then
			object.ActionText = text(tostring(object:GetAttribute("ForgeOpeningAction")))
			object.ObjectText = text(tostring(object:GetAttribute("ForgeOpeningObject")))
		end
	end
	table.insert(connections, workspace.DescendantAdded:Connect(localize))
	for _, object in workspace:GetDescendants() do
		localize(object)
	end

	-- Objective waypoint (p134 c1 dead end 2): arrow + distance, minimap pin and a beam at the
	-- current step's target; one set of instances reused for every step.
	local playerGui = player:WaitForChild("PlayerGui")
	local minimapCache: Instance? = nil
	local way = Waypoint.start({
		playerGui = playerGui,
		stage = stage,
		camera = function()
			return workspace.CurrentCamera
		end,
		minimap = function(): any
			if not minimapCache or not minimapCache:IsDescendantOf(playerGui) then
				minimapCache = playerGui:FindFirstChild("Minimap", true)
			end
			return minimapCache
		end,
		label = function(meters: number): string
			return string.format(text("opening.way.meters"), meters)
		end,
		ground = groundY,
	})
	-- 'Show the way': the tap-walk (TapRouter.moveTo) to the current target.
	-- The walk goes to the target the marker shows this frame: the opening step's, else (after the
	-- opening) the HUD guide step's (p134 v73: the harbor's 'gather Fiber' had no direction at all).
	local currentTarget: Vector3? = nil
	local function showWay()
		local target = currentTarget
		if target and ctx.walkTo then
			ctx.walkTo(target, M.WAY_ARRIVE)
		end
	end
	way.arrow.Activated:Connect(showWay)
	-- Tapping the quest card offers the walk (it no longer only reads as a collapse target). Both live
	-- in the waypoint gui, below every sheet, the menu grid and the sea chart (p134 v68: on the
	-- opening gui, DisplayOrder 40, the button took the taps meant for a sheet's X).
	local trackerTap = Instance.new("TextButton")
	trackerTap.Name, trackerTap.Text, trackerTap.BackgroundTransparency = "OpeningTrackerTap", "", 1
	trackerTap.AutoButtonColor, trackerTap.Visible, trackerTap.Parent = false, false, way.gui
	local wayButton = components.button(theme, {
		text = text("opening.way.show"),
		size = UDim2.fromOffset(120, 44),
		parent = way.gui,
		onClick = function()
			showWay()
		end,
	})
	wayButton.Name, wayButton.Visible = "OpeningShowWay", false
	HudShell.pebble(wayButton, true, true)
	-- p134 v69: a camp-project step (the windbreak) is fed through the Camp panel, which nothing on
	-- screen led to. The quest card carries a direct Open camp button for it (Scene.cardAction).
	local function openCamp(): boolean
		local action = Scene.cardAction(view)
		return action ~= nil and CampPanel.show(action.project)
	end
	local campButton = components.button(theme, {
		text = text("opening.camp.open"),
		size = UDim2.fromOffset(120, 44),
		parent = way.gui,
		onClick = function()
			openCamp()
		end,
	})
	campButton.Name, campButton.Visible = "OpeningOpenCamp", false
	HudShell.pebble(campButton, true, true)
	local wayOfferUntil = 0
	trackerTap.Activated:Connect(function()
		wayOfferUntil = os.clock() + M.WAY_OFFER_SECONDS
	end)
	wayButton.Activated:Connect(function()
		wayOfferUntil = 0
	end)

	local glintAt: number? = nil
	local litShown = false
	local hintUntil = 0
	-- Dead end 1 (p134 C1): stake staging from Scene.stakeMarks on the local copies of the stake parts.
	type StakeLook = { fallen: boolean, glow: Highlight?, light: PointLight? }
	local stakeLook: { [number]: StakeLook } = {}
	local function stageStakes()
		for index, stakeMark in Scene.stakeMarks(view) do
			local stake = opening("OpeningStake" .. index)
			if not stake or not stake:IsA("BasePart") then
				continue
			end
			local look: StakeLook = stakeLook[index] or { fallen = false, glow = nil, light = nil }
			stakeLook[index] = look
			local prompt = stake:FindFirstChild("ForgeOpeningStake")
			if prompt and prompt:IsA("ProximityPrompt") then
				prompt.Enabled = stakeMark.prompt
			end
			if stakeMark.fallen and not look.fallen then
				-- Pulled: the peg lies on the sand and its guy line is cut.
				look.fallen = true
				local ground = stake.Position - Vector3.new(0, stake.Size.Y / 2, 0)
				local down = CFrame.new(ground + Vector3.new(0, 0.35, 0)) * CFrame.Angles(0, 0, math.rad(84))
				local visual = stake:FindFirstChild("ForgeMeshVisual")
				if visual and visual:IsA("Model") then
					visual:PivotTo(down * CFrame.new(-stake.Size.Y / 2, 0, 0))
				end
				for _, piece in stake:GetChildren() do
					if piece:IsA("BasePart") and (piece.Name == "GuyLine" or piece.Name == "Cap") then
						piece.Transparency = 1
					elseif piece:IsA("BasePart") and piece.Name == "Lashing" then
						piece.CFrame = down
					end
				end
				stake.CFrame = down
			end
			if stakeMark.glow and not look.glow then
				-- Still to pull: a warm outline over terrain and a small light, so it reads as the
				-- stake to pull and not a tent guy-line post, day or night.
				local glow = Instance.new("Highlight")
				glow.Name, glow.FillColor, glow.OutlineColor = "OpeningStakeGlow", P.ochre, P.ochre
				glow.FillTransparency, glow.OutlineTransparency = 0.55, 0
				glow.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				glow.Adornee = stake:FindFirstChild("ForgeMeshVisual") or stake
				glow.Parent = stake
				local light = Instance.new("PointLight")
				light.Name, light.Color, light.Range, light.Brightness = "OpeningStakeLight", P.ochre, 10, 1.5
				light.Parent = stake
				look.glow, look.light = glow, light
			elseif not stakeMark.glow and look.glow then
				(look.glow :: Highlight):Destroy()
				if look.light then
					look.light:Destroy()
				end
				look.glow, look.light = nil, nil
			end
			local lit = look.glow
			if lit then
				lit.FillTransparency = 0.45 + 0.25 * math.sin(os.clock() * 4)
			end
		end
	end
	-- The node the tracker points at (crash-site bone pile, fiber, flint) carries a soft outline.
	local guide: Highlight? = nil
	local function stageGuide()
		local id = Scene.guideNode(view)
		local target: Instance? = nil
		if id then
			for _, part in game:GetService("CollectionService"):GetTagged("ForgeSurvivalNode") do
				target = if part:GetAttribute("ForgeNodeId") == id then part else target
			end
		end
		if guide and (target == nil or guide.Parent ~= target) then
			guide:Destroy()
			guide = nil
		end
		if target and not guide then
			local created = Instance.new("Highlight")
			created.Name, created.FillColor, created.OutlineColor = "OpeningGuide", P.teal, P.ochre
			created.FillTransparency, created.DepthMode = 0.7, Enum.HighlightDepthMode.AlwaysOnTop
			created.Parent = target
			guide = created
		end
	end
	-- Beat 1 telegraph: a red ground ring under the player from TELEGRAPH_LEAD_MILLIS before each
	-- charge to the end of its dodge grace, filling toward the strike (p134 C1: never seen on screen).
	local ringPart: BasePart? = nil
	local function stageRing(now: number, root: BasePart?)
		local charge = if view and view.step == "dodge" then view.charge else nil
		local shown, fill = Scene.telegraph(charge, now)
		if not shown or not root then
			if ringPart then
				ringPart:Destroy()
				ringPart = nil
			end
			return
		end
		local ringNow = ringPart
		if not ringNow then
			local created = Instance.new("Part")
			created.Name, created.Shape, created.Anchored = "OpeningTelegraph", Enum.PartType.Cylinder, true
			created.CanCollide, created.CanQuery, created.CanTouch, created.CastShadow = false, false, false, false
			created.Material, created.Color = Enum.Material.Neon, P.coral
			created.Parent = stage
			ringNow = created
			ringPart = created
		end
		local disc = ringNow :: BasePart
		local floor = groundY(root.Position) or (root.Position.Y - 3)
		local across = 9 - 3 * fill
		disc.Size = Vector3.new(0.2, across, across)
		disc.Transparency = 0.5 - 0.35 * fill
		disc.CFrame = CFrame.new(root.Position.X, floor + 0.15, root.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
	end
	-- Refused prompts (OpeningDirector REFUSAL_ATTRIBUTE) toast on the coach card, KO or EN.
	local function refusalToast()
		local raw = player:GetAttribute("ForgeOpeningRefusal")
		local reason = if type(raw) == "string" then string.match(raw, "^([%u_]+)#") else nil
		if not reason then
			return
		end
		showCard("notice", text(Scene.refusalKey(reason)))
		task.delay(3, function()
			if cardKind == "notice" and card.Text == text(Scene.refusalKey(reason)) then
				showCard(nil)
			end
		end)
	end
	table.insert(connections, player:GetAttributeChangedSignal("ForgeOpeningRefusal"):Connect(refusalToast))
	table.insert(
		connections,
		game:GetService("ProximityPromptService").PromptTriggered:Connect(function(prompt, actor)
			if actor == player and prompt:GetAttribute("ForgeWarehouse") then
				openCamp()
			end
		end)
	)
	-- Waypoint toward `target` with `quest` as the quest card (the opening tracker, or the HUD's
	-- ObjectiveTracker after the opening); nil target or card hides the marker and the walk offer.
	local function placeWay(quest: any, target: Vector3?, root: BasePart?, campAction: any)
		currentTarget = target
		-- Toward the current step's target; the tracker tap offers the walk there. Another
		-- guide's marker (the sea chart's 'show the dock') takes the one marker while it is set.
		local yielded = typeof(player:GetAttribute(Waypoint.OVERRIDE_ATTRIBUTE)) == "Vector3"
		way.step(if root then root.Position else nil, if yielded then nil else target)
		-- Under any sheet, the menu grid or the sea chart the arrow, the tracker tap and the walk button
		-- hide (the beam and the pin stay), and the quest card itself may be hidden by its dock.
		local modal = Waypoint.covered(playerGui, function(name: string): any
			return player:GetAttribute(name)
		end)
		way.gui.Enabled = not modal
		if modal then
			wayOfferUntil = 0
		end
		local guiAt = way.gui.AbsolutePosition
		local trackerSeen = not modal
			and not yielded
			and M.shownChain(quest)
			and quest.AbsoluteSize.X > 0
			and target ~= nil
		trackerTap.Visible = trackerSeen
		local cardShown = not modal and M.shownChain(quest) and quest.AbsoluteSize.X > 0
		campButton.Visible = cardShown and campAction ~= nil
		if cardShown then
			local at, size = quest.AbsolutePosition, quest.AbsoluteSize
			campButton.Position = UDim2.fromOffset(at.X - guiAt.X, at.Y - guiAt.Y + size.Y + 6)
		end
		if trackerSeen then
			local at, size = quest.AbsolutePosition, quest.AbsoluteSize
			trackerTap.Position = UDim2.fromOffset(at.X - guiAt.X, at.Y - guiAt.Y)
			trackerTap.Size = UDim2.fromOffset(size.X, size.Y)
			-- Under the Open camp button when both would not fit side by side.
			local below = if campButton.Visible and size.X < 246 then 50 else 0
			wayButton.Position = UDim2.fromOffset(at.X - guiAt.X + size.X - 120, at.Y - guiAt.Y + size.Y + 6 + below)
		end
		wayButton.Visible = trackerSeen
			and os.clock() < wayOfferUntil
			and Waypoint.shown(if root then root.Position else nil, target)
	end
	-- The HUD guide step's quest card (the genre ObjectiveTracker) while it shows that step's line.
	local guideLine: string?, guideObjective: any = nil, nil
	local function guideCard(): any
		local genre = ctx.objectiveSlot and ctx.objectiveSlot:FindFirstChild("ObjectiveTracker")
		if genre and guideLine and string.find(genre.Text, guideLine, 1, true) then
			return genre
		end
		return nil
	end
	--- World point of the HUD guide step in the current world: the nearest node of a gather step, or
	--- the anchor an acknowledgement step is performed at when it stands in this world.
	local function guideTarget(): Vector3?
		if not guideObjective then
			return nil
		end
		local world = workspace:FindFirstChild("ForgeRoleWorld")
		local layoutId = world and world:GetAttribute("ForgeLayoutId")
		local layout = Waypoint.layout(ctx.content, layoutId)
		local at, anchorId = GuideEvents.where(ctx.content, guideObjective.action, guideObjective.target, layoutId)
		if at ~= nil and at == layoutId and anchorId then
			return Waypoint.resolve(layout, anchorId)
		end
		local root = rootPart()
		return Waypoint.guideTarget(layout, guideObjective, if root then root.Position else nil)
	end
	local function frame()
		local now = serverNow()
		local active = view ~= nil and view.active == true
		local campAction = Scene.cardAction(view)
		player:SetAttribute(M.PROJECT_ATTRIBUTE, if campAction then campAction.project else nil)
		-- Quest card: the opening tracker replaces the genre tracker line while a beat runs.
		local genre = ctx.objectiveSlot and ctx.objectiveSlot:FindFirstChild("ObjectiveTracker")
		local title, lines = Scene.tracker(view, text)
		tracker.Visible = title ~= nil
		if title then
			tracker.Text = title .. "\n" .. table.concat(lines, "\n")
			local slot = ctx.objectiveSlot
			HudShell.fitQuestText(tracker, if slot then slot.AbsoluteSize.Y else nil, touch)
		end
		if genre and genre:IsA("GuiObject") then
			genre.Visible = title == nil
		end
		stageStakes()
		stageGuide()
		stageRing(now, rootPart())
		if not active then
			placeWay(guideCard(), guideTarget(), rootPart(), nil)
			dodge.Visible = false
			if boar then
				boar:Destroy()
				boar = nil
			end
			-- Tumble leaves with the opening (p134 v50).
			if tumble then
				tumble:Destroy()
				tumble = nil
			end
			return
		end
		-- R01: the cold open waits for the title's Start and the survivor picker (`held`).
		if view.coldOpen and not (ctx.held and ctx.held()) then
			startCold()
		end
		local root = rootPart()
		-- Beat 1: the boar is out from the 2nd stake until the dodge beat passes.
		local lane = anchor("opening.boar-lane")
		if view.step == "dodge" and Scene.stakes(view.pulled) >= 2 and lane then
			boar = boar or rig("boar", lane)
			local charge = view.charge
			local charging = charge ~= nil and now >= charge.startAt and now <= charge.strikeAt + Scene.GRACE_MILLIS
			-- Between charges the boar paws at the start of its next run, in frame and on the ground.
			local start = lane
			if root then
				local x, z = Scene.chargeFrom(lane.X, lane.Z, root.Position.X, root.Position.Z)
				start = Vector3.new(x, root.Position.Y, z)
			end
			local target = if root then root.Position else lane
			if charging and root and boar then
				placeBoar(boar, start, target, M.chargeProgress(charge, now))
				if not mark then
					-- Telegraph: a coral outline drawn over terrain and props for the whole run.
					local created = Instance.new("Highlight")
					created.FillColor, created.OutlineColor = P.coral, P.coral
					created.FillTransparency, created.DepthMode = 0.45, Enum.HighlightDepthMode.AlwaysOnTop
					created.Parent = boar
					mark = created
				end
			elseif boar then
				placeBoar(boar, start, target, 0)
				if mark then
					mark:Destroy()
					mark = nil
				end
			end
			dodge.Visible = charging
			if charging then
				local regions = HudShell.regions(gui.AbsoluteSize.X, gui.AbsoluteSize.Y, HudShell.guiClear(gui), touch)
				local slot = regions.tokens.I1
				if slot then
					HudShell.put(dodge, slot)
				end
				HudShell.pebble(dodge, true, true)
				ring.Thickness = 3 + math.abs(math.sin(os.clock() * 6)) * 3
			end
			if cardKind ~= "notice" then
				showCard("coach", text(if view.hit then "opening.tumble.retry" else "opening.tumble.charge"))
			end
		else
			dodge.Visible = false
			if boar then
				boar:Destroy()
				boar, mark = nil, nil
			end
			if cardKind == "coach" then
				showCard(nil)
			end
		end
		-- Tumble: pinned at its anchor, then a follower 4 studs behind once freed.
		local pinned = anchor("opening.tumble")
		if pinned and (view.beat or 0) <= 7 then
			tumble = tumble or rig("protoceratops", pinned)
			local plateKey = Scene.tumbleLabel(view)
			if tumble and tumble.PrimaryPart and plateKey then
				local plate = tumble.PrimaryPart:FindFirstChild("OpeningName")
				if not plate then
					local created = Instance.new("BillboardGui")
					created.Name, created.Size = "OpeningName", UDim2.fromOffset(160, 24)
					created.StudsOffset, created.AlwaysOnTop = Vector3.new(0, 4.5, 0), true
					-- The HUD's contextual banner steers clear of this plate (p134 v57: the hunger
					-- line covered half of "텀블 (동료)").
					created:AddTag("ForgeNameTag")
					local label = Instance.new("TextLabel")
					label.Name, label.Size, label.BackgroundTransparency = "Text", UDim2.fromScale(1, 1), 1
					label.TextColor3, label.TextStrokeTransparency, label.TextScaled = P.bone, 0.4, true
					label.Font, label.Parent = Enum.Font.BuilderSansBold, created
					created.Parent = tumble.PrimaryPart
					plate = created
				end
				local label = (plate :: any):FindFirstChild("Text")
				if label then
					label.Text = text(plateKey)
				end
			end
			if view.freed and root and tumble then
				if snortUntil == 0 then
					snortUntil = os.clock() + 3
					bubble(tumble, "opening.tumble.snort")
				end
				local behind = root.Position - root.CFrame.LookVector * M.FOLLOW_STUDS
				local current = tumble:GetPivot().Position
				local target = current:Lerp(Vector3.new(behind.X, root.Position.Y - 1, behind.Z), 0.08)
				tumble:PivotTo(CFrame.lookAt(target, Vector3.new(root.Position.X, target.Y, root.Position.Z)))
			end
			if snortUntil > 0 and os.clock() > snortUntil and tumble and tumble.PrimaryPart then
				local old = tumble.PrimaryPart:FindFirstChild("OpeningBubble")
				if old then
					old:Destroy()
				end
			end
		end
		-- Beat 2: three glint bursts at the ridge, then the decoded signal card.
		if view.step == "mirror" then
			glintAt = glintAt or os.clock()
			local mirror = opening("OpeningMirror")
			if mirror and mirror:IsA("BasePart") then
				local found = mirror:FindFirstChild("Glint")
				local light: PointLight
				if found and found:IsA("PointLight") then
					light = found
				else
					light = Instance.new("PointLight")
					light.Name, light.Range = "Glint", 40
					light.Color, light.Parent = Color3.fromRGB(255, 252, 230), mirror
				end
				local t = os.clock() - (glintAt :: number)
				local burst = t < 1.5 and (t % 0.5) < 0.2
				light.Brightness = if burst then 8 else 0
				mirror.Material = if burst then Enum.Material.Neon else Enum.Material.Glass
			end
			if cardKind ~= "mirror" and os.clock() - (glintAt :: number) >= 1.5 then
				showCard("mirror", text("opening.mirror.signal"))
			end
		elseif cardKind == "mirror" then
			showCard(nil)
		end
		-- Beat 5: the herd hint while following the stream.
		if view.step == "stream" and hintUntil == 0 then
			hintUntil = os.clock() + 6
			showCard("hint", text("opening.ridge.herd"))
			if tumble then
				bubble(tumble, "opening.ridge.call")
			end
		elseif cardKind == "hint" and os.clock() > hintUntil then
			showCard(nil)
		end
		placeBoat(now)
		-- p134 v74 #5: at the beacon step Marit's talk prompt (8 studs from the pole) won the interact
		-- token over the beacon's Light and opened her dialog; it rests until the beacon is lit.
		local world = workspace:FindFirstChild("ForgeRoleWorld")
		local marit = world and world:FindFirstChild("npc.marit")
		local talk = marit and marit:FindFirstChildOfClass("ProximityPrompt")
		if talk then
			talk.Enabled = view.step ~= "beacon"
		end
		-- The lit beacon answers on the card (Marit's farewell) while the Gannet comes in.
		if view.beaconAt and not litShown then
			litShown = true
			showCard("notice", text("opening.beacon.farewell"))
			task.delay(4, function()
				if cardKind == "notice" and card.Text == text("opening.beacon.farewell") then
					showCard(nil)
				end
			end)
		end
		placeWay(tracker, wayTarget(), root, campAction)
	end
	table.insert(connections, RunService.Heartbeat:Connect(frame))
	local stop = ctx.onSnapshot(function(latest)
		view = if type(latest) == "table" then latest.opening else nil
		local ch = if type(latest) == "table" then latest.character else nil
		guideLine, guideObjective = nil, nil
		if ctx.content and type(ch) == "table" then
			-- The same line ContractsPanel puts on the HUD tracker (without its touch wording, which
			-- only changes the hint, so the step itself is matched on the guide title and target).
			local line, objective =
				CharacterText.guideObjective(ctx.locale, ctx.content, ch, ctx.names or {}, ctx.solo == true)
			guideObjective = objective
			guideLine = if line then string.match(line, "^[^:]+") else nil
		end
	end)
	return {
		destroy = function()
			stop()
			endCold(false)
			for _, connection in connections do
				connection:Disconnect()
			end
			way.destroy()
			stage:Destroy()
			gui:Destroy()
			tracker:Destroy()
		end,
	}
end

return M
