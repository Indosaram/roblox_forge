--!strict
-- R01 join screen (ReplicatedFirst): replaces the Roblox default loading screen with our own
-- loading screen, then the title. TitleFlow holds the rules; this script owns the Instances.
-- The loading bar follows real readiness and the screen turns into the title on the first frame
-- the world is ready (no minimum show time). Start fades it out over the already-built HUD and
-- sets LocalPlayer ForgeTitleDone, which releases the survivor picker and the opening cold open.
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local Flow = require(script.Parent:WaitForChild("TitleFlow"))
local Travel = require(script.Parent:WaitForChild("TravelScreen"))
local TeleportService = game:GetService("TeleportService")

ReplicatedFirst:RemoveDefaultLoadingScreen()
-- R20: a player arriving from an island hop keeps the travel screen it left with (SetTeleportGui);
-- read it before anything yields so the hand-over has no blank frame.
local arrivingGui = TeleportService:GetArrivingTeleportGui()

local player = Players.LocalPlayer
-- p134 v50: onboarding ran portrait on a phone despite StarterGui LandscapeSensor; pin it here.
local LANDSCAPE = Enum.ScreenOrientation.LandscapeSensor
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
playerGui.ScreenOrientation = LANDSCAPE
playerGui:GetPropertyChangedSignal("ScreenOrientation"):Connect(function()
	if playerGui.ScreenOrientation ~= LANDSCAPE then
		playerGui.ScreenOrientation = LANDSCAPE
	end
end)
-- The Roblox Backpack hotbar stays hidden under the title and under full sheets (TitleFlow).
Flow.bindBackpack(player, function(shown: boolean)
	pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, shown)
end)
local function rgb(value: number): Color3
	return Color3.fromRGB(bit32.rshift(value, 16), bit32.band(bit32.rshift(value, 8), 0xFF), bit32.band(value, 0xFF))
end
local C: { [string]: Color3 } = {}
for key, value in Flow.COLORS :: any do
	C[key] = rgb(value)
end

local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "ForgeTitle", false, Flow.DISPLAY_ORDER
gui.IgnoreGuiInset, gui.ZIndexBehavior = true, Enum.ZIndexBehavior.Sibling

local backdrop = Instance.new("Frame")
backdrop.Name, backdrop.Size, backdrop.BorderSizePixel = "Backdrop", UDim2.fromScale(1, 1), 0
backdrop.BackgroundColor3, backdrop.ClipsDescendants, backdrop.Parent = C.tealDeep, true, gui
-- Our own key art (Flow.background: an uploaded image asset, so it shows in Studio and every
-- role). Placed by Flow.art below the top bar so its wordmark is never under it.
local art = Instance.new("ImageLabel")
art.Name, art.Size, art.BackgroundTransparency = "Art", UDim2.fromScale(1, 1), 1
art.ScaleType, art.Image = Enum.ScaleType.Stretch, Flow.background()
art.Parent = backdrop
-- Left-side shade so the copy stays readable over the bright sea.
local shade = Instance.new("Frame")
shade.Name, shade.Size, shade.BorderSizePixel = "Shade", UDim2.fromScale(0.75, 1), 0
shade.BackgroundColor3, shade.Parent = C.ink, backdrop
local fade = Instance.new("UIGradient")
fade.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.25),
	NumberSequenceKeypoint.new(0.7, 0.6),
	NumberSequenceKeypoint.new(1, 1),
})
fade.Parent = shade

local function label(name: string, font: Enum.Font): TextLabel
	local item = Instance.new("TextLabel")
	item.Name, item.BackgroundTransparency, item.Font = name, 1, font
	item.TextColor3, item.TextXAlignment, item.Text = C.bone, Enum.TextXAlignment.Left, ""
	item.TextWrapped, item.Parent = true, backdrop
	return item
end
local title = label("Title", Enum.Font.BuilderSansBold)
local titleStroke = Instance.new("UIStroke")
titleStroke.Color, titleStroke.Thickness, titleStroke.Parent = C.driftDark, 2, title
local tagline = label("Tagline", Enum.Font.BuilderSansMedium)
local tip = label("Tip", Enum.Font.BuilderSans)
tip.TextYAlignment = Enum.TextYAlignment.Bottom
local status = label("Status", Enum.Font.BuilderSansMedium)
status.TextColor3 = C.boneShade
local version = label("Version", Enum.Font.BuilderSans)
version.TextColor3, version.Text = C.boneShade, Flow.version(game.PlaceVersion)

local track = Instance.new("Frame")
track.Name, track.BorderSizePixel, track.BackgroundColor3 = "ProgressTrack", 0, C.panel
track.BackgroundTransparency, track.Parent = 0.2, backdrop
local fill = Instance.new("Frame")
fill.Name, fill.BorderSizePixel, fill.BackgroundColor3 = "ProgressFill", 0, C.teal
fill.Size, fill.Parent = UDim2.fromScale(0, 1), track
for _, frame in { track, fill } do
	local corner = Instance.new("UICorner")
	corner.CornerRadius, corner.Parent = UDim.new(0.5, 0), frame
end

-- Pebble buttons (decision 9 token shape: rounded, driftwood rim).
local function pebble(name: string, primary: boolean): TextButton
	local button = Instance.new("TextButton")
	button.Name, button.AutoButtonColor, button.Visible = name, true, false
	button.BackgroundColor3 = if primary then C.teal else C.tealDeep
	button.TextColor3 = if primary then C.ink else C.bone
	button.Font, button.Text, button.Parent = Enum.Font.BuilderSansBold, "", backdrop
	local corner = Instance.new("UICorner")
	corner.CornerRadius, corner.Parent = UDim.new(0.36, 0), button
	local rim = Instance.new("UIStroke")
	rim.ApplyStrokeMode, rim.Color, rim.Thickness, rim.Parent = Enum.ApplyStrokeMode.Border, C.drift, 2, button
	return button
end
local start = pebble("Start", true)
local settings = pebble("Settings", false)

gui.Parent = playerGui

local function place()
	local size = (workspace.CurrentCamera :: Camera).ViewportSize
	local top = math.max(GuiService.TopbarInset.Max.Y, Flow.TOP_INSET)
	local rects = Flow.layout(size.X, size.Y, top)
	local frame = Flow.art(size.X, size.Y, top)
	art.Position, art.Size = UDim2.fromOffset(frame.x, frame.y), UDim2.fromOffset(frame.width, frame.height)
	for name, item in
		{
			title = title,
			tagline = tagline,
			tip = tip,
			status = status,
			version = version,
			bar = track,
			start = start,
			settings = settings,
		} :: { [string]: GuiObject }
	do
		local r = rects[name]
		item.Position, item.Size = UDim2.fromOffset(r.x, r.y), UDim2.fromOffset(r.width, r.height)
		if r.textSize and (item:IsA("TextLabel") or item:IsA("TextButton")) then
			(item :: any).TextSize = r.textSize
		end
	end
end
place()
local camera = workspace.CurrentCamera :: Camera
local resize = camera:GetPropertyChangedSignal("ViewportSize"):Connect(place)
local inset = GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(place)

-- Copy: the Strings LocalizationTable (cli.title.* and game_name rows of locale/strings.csv).
local text: { [string]: string }? = nil
local function loadText(): boolean
	if text then
		return true
	end
	local forge = game:GetService("ReplicatedStorage"):FindFirstChild("Forge")
	local games = forge and forge:FindFirstChild("games")
	local pack = games and games:FindFirstChild("robango-island")
	local strings = pack and pack:FindFirstChild("Strings")
	if not strings or not strings:IsA("LocalizationTable") then
		return false
	end
	local locale = Flow.locale(player.LocaleId, player:GetAttribute("ForgeLanguage"))
	local column = if string.sub(locale, 1, 2) == "ko" then "ko-kr" else "en-us"
	local rows: { [string]: string } = {}
	for _, entry in strings:GetEntries() do
		local key = entry.Key
		if
			key == "game_name"
			or string.sub(key, 1, 10) == "cli.title."
			or string.sub(key, 1, 11) == "cli.travel."
			or string.sub(key, 1, 15) == "cli.chart.isle."
			or string.sub(key, 1, 16) == "cli.chart.biome_"
		then
			rows[key] = entry.Values[column] or entry.Values["en-us"] or key
		end
	end
	text = rows
	title.Text, tagline.Text = rows.game_name or "", rows["cli.title.tagline"] or ""
	start.Text, settings.Text = rows["cli.title.start"] or "", rows["cli.title.settings"] or ""
	return true
end

-- Movement stays off under the title; the PlayerModule arrives with StarterPlayerScripts.
local controls: any = nil
task.spawn(function()
	local scripts = player:WaitForChild("PlayerScripts")
	local module = scripts:WaitForChild("PlayerModule", 30)
	if module and module:IsA("ModuleScript") then
		local ok, found = pcall(function()
			return (require :: any)(module):GetControls()
		end)
		if ok and found and player:GetAttribute("ForgeTitleDone") ~= true then
			controls = found
			found:Disable()
		end
	end
end)

local machine = Flow.machine()
local stepper: RBXScriptConnection? = nil

-- R20 travel screen: departures announced by the server (LocalPlayer ForgeTravelTo), the
-- teleport loading GUI, the arrival hand-over and in-place island changes.
local travelFlow = Travel.flow()
local travel: Travel.Screen? = nil
local travelArt: { [string]: string } = {}
local function travelScreen(): Travel.Screen
	if not travel then
		local screen = if arrivingGui
				and arrivingGui:IsA("ScreenGui")
				and arrivingGui.Name == Travel.GUI
			then Travel.adopt(arrivingGui)
			else Travel.build()
		screen.gui.Parent = playerGui
		travel = screen
	end
	return travel :: Travel.Screen
end
local function travelText(key: string?): string?
	if not key then
		return nil
	end
	local strings = (text or {}) :: { [string]: string }
	return strings[key]
end
local function placeTravel()
	if travel then
		local size = (workspace.CurrentCamera :: Camera).ViewportSize
		travel.place(size.X, size.Y, math.max(GuiService.TopbarInset.Max.Y, Flow.TOP_INSET))
	end
end
local function onTravel()
	local info = Travel.parse(player:GetAttribute(Travel.ATTRIBUTE))
	if not info then
		-- Cleared: the route was refused after all; the departure screen goes away.
		if travelFlow.phase == "departing" then
			travelFlow.cancel()
		end
		return
	end
	local shared = (game:GetService("ReplicatedStorage"):WaitForChild("Forge") :: any).games["robango-island"].src.shared
	local Content = require(shared.SurvivalContent) :: any
	travelArt = require(shared.Assets) :: any
	local view = Travel.describe(Content, info.island, info.mode)
	local screen = travelScreen()
	screen.fill({
		heading = travelText(view.heading),
		name = travelText(view.name),
		biome = travelText(view.biome),
		art = travelArt[view.art],
		backdrop = Flow.background(),
	})
	placeTravel()
	screen.gui.Enabled = true
	travelFlow.depart(os.clock(), workspace:FindFirstChild("ForgeRoleWorld"))
	-- Roblox shows this GUI while the teleport loads and hands it to the destination's boot.
	pcall(TeleportService.SetTeleportGui, TeleportService, screen.gui)
end
player:GetAttributeChangedSignal(Travel.ATTRIBUTE):Connect(onTravel)
-- A teleport that fails after the server accepted it lands the player back here: drop the screen.
player.OnTeleport:Connect(function(state: Enum.TeleportState)
	if state == Enum.TeleportState.Failed and travelFlow.phase == "departing" then
		travelFlow.cancel()
	end
end)
camera:GetPropertyChangedSignal("ViewportSize"):Connect(placeTravel)
if arrivingGui then
	-- Arrived through a hop: the travel screen stays up over this place's load, then the world
	-- shows directly (the title already ran on the first island of this session).
	local screen = travelScreen()
	screen.gui.Enabled = true
	placeTravel()
	travelFlow.arrive(os.clock())
end
RunService.RenderStepped:Connect(function()
	if travelFlow.phase == "idle" then
		if travel and travel.gui.Enabled then
			travel.gui.Enabled = false
		end
		return
	end
	local world = workspace:FindFirstChild("ForgeRoleWorld")
	local character = player.Character
	local signals: Flow.Signals = {
		loaded = game:IsLoaded(),
		text = text ~= nil,
		queue = ContentProvider.RequestQueueSize,
		ground = world ~= nil and world:GetAttribute("ForgeSpawnReady") == true,
		character = character ~= nil and character:FindFirstChild("HumanoidRootPart") ~= nil,
		hud = player:GetAttribute("ForgeHudReady") == true,
	}
	-- In place the HUD is already built; the new world's ground and the character decide.
	local ready = signals.ground and signals.character and (travelFlow.phase ~= "arriving" or Flow.ready(signals))
	local shows = travelFlow.step(os.clock(), world, ready, Flow.progress(signals, 1))
	local screen = travelScreen()
	screen.setProgress(travelFlow.progress)
	screen.setTip(travelText(Travel.TIP_KEYS[travelFlow.tip]) or "")
	screen.setStatus(travelText("cli.travel.loading") or "")
	screen.gui.Enabled = shows
end)
local function close()
	if not machine.start() then
		return
	end
	if stepper then
		stepper:Disconnect()
	end
	resize:Disconnect()
	inset:Disconnect()
	start.Active, settings.Active = false, false
	if controls then
		controls:Enable()
	end
	player:SetAttribute("ForgeTitleDone", true)
	-- The HUD under it is already built (ForgeHudReady), so the fade reveals a finished frame.
	local began = os.clock()
	-- Every layer fades from its own transparency to clear together (text, fills, rims, art).
	local layers: { { item: Instance, property: string, from: number } } = {}
	for _, item in gui:GetDescendants() do
		local properties: { string } = if item:IsA("TextLabel") or item:IsA("TextButton")
			then { "TextTransparency", "BackgroundTransparency" }
			elseif item:IsA("ImageLabel") then { "ImageTransparency", "BackgroundTransparency" }
			elseif item:IsA("Frame") then { "BackgroundTransparency" }
			elseif item:IsA("UIStroke") then { "Transparency" }
			else {}
		for _, property in properties do
			table.insert(layers, { item = item, property = property, from = (item :: any)[property] })
		end
	end
	local fading: RBXScriptConnection
	fading = RunService.RenderStepped:Connect(function()
		local k = math.clamp((os.clock() - began) / Flow.FADE_SECONDS, 0, 1)
		for _, layer in layers do
			(layer.item :: any)[layer.property] = layer.from + (1 - layer.from) * k
		end
		if k >= 1 then
			fading:Disconnect()
			gui:Destroy()
		end
	end)
end
start.Activated:Connect(close)
-- The settings sheet opens above the title (RobangoIslandClient listens to this counter).
settings.Activated:Connect(function()
	player:SetAttribute("ForgeTitleSettings", (tonumber(player:GetAttribute("ForgeTitleSettings")) or 0) + 1)
end)

stepper = RunService.RenderStepped:Connect(function()
	local world = workspace:FindFirstChild("ForgeRoleWorld")
	local character = player.Character
	local signals: Flow.Signals = {
		loaded = game:IsLoaded(),
		text = loadText(),
		queue = ContentProvider.RequestQueueSize,
		ground = world ~= nil and world:GetAttribute("ForgeSpawnReady") == true,
		character = character ~= nil and character:FindFirstChild("HumanoidRootPart") ~= nil,
		hud = player:GetAttribute("ForgeHudReady") == true,
	}
	local phase = machine.step(signals, os.clock())
	fill.Size = UDim2.fromScale(machine.progress, 1)
	local rows = text or {}
	if phase == "loading" then
		tip.Text = rows[Flow.TIP_KEYS[machine.tip]] or ""
		status.Text = rows["cli.title.loading"] or ""
		return
	end
	-- Title: the loading block gives way to Start.
	tip.Visible, status.Visible, track.Visible = false, false, false
	start.Visible, settings.Visible = true, true
	if arrivingGui or (RunService:IsStudio() and workspace:GetAttribute("ForgeQASkipTitle") == true) then
		-- A hop arrival goes straight into the world (the title ran on the first island);
		-- Studio QA scenarios that start in-world skip the tap too.
		close()
	end
end)
