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
local M = {}

M.COLD_OPEN_SECONDS, M.SKIP_AFTER = 25, 1.0
M.FOLLOW_STUDS = 4

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
	tracker.TextScaled, tracker.TextWrapped = true, true
	tracker.TextXAlignment, tracker.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top

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

	local glintAt: number? = nil
	local hintUntil = 0
	local function frame()
		local now = serverNow()
		local active = view ~= nil and view.active == true
		-- Quest card: the opening tracker replaces the genre tracker line while a beat runs.
		local genre = ctx.objectiveSlot and ctx.objectiveSlot:FindFirstChild("ObjectiveTracker")
		local title, lines = Scene.tracker(view, text)
		tracker.Visible = title ~= nil
		if title then
			tracker.Text = title .. "\n" .. table.concat(lines, "\n")
		end
		if genre and genre:IsA("GuiObject") then
			genre.Visible = title == nil
		end
		if not active then
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
			showCard("coach", text(if view.hit then "opening.tumble.retry" else "opening.tumble.charge"))
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
	end
	table.insert(connections, RunService.Heartbeat:Connect(frame))
	local stop = ctx.onSnapshot(function(latest)
		view = if type(latest) == "table" then latest.opening else nil
	end)
	return {
		destroy = function()
			stop()
			endCold(false)
			for _, connection in connections do
				connection:Disconnect()
			end
			stage:Destroy()
			gui:Destroy()
			tracker:Destroy()
		end,
	}
end

return M
