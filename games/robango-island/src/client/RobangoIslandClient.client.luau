--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = ReplicatedStorage:WaitForChild("Forge")
local Shared = Forge.games["robango-island"].src.shared

local audio = require(script.Parent:WaitForChild("RobangoAudio")).start(
	require(Forge.core.infra.audio.SoundBank),
	require(Forge.genres["survival-coop"].module.AudioDirector),
	require(Shared.Assets),
	require(Shared.RobangoAudioCatalog),
	require(Shared.SettingsModel)
)
script.Destroying:Connect(audio.destroy)

local Client = require(Forge.core.infra.genre.Client)
local gui = Client.start({ controls = require(Shared.GenreUI) })
gui.Destroying:Connect(audio.destroy)

local player = game:GetService("Players").LocalPlayer
local characterTracks = require(script.Parent:WaitForChild("CharacterTracks")).start(player)
script.Destroying:Connect(characterTracks)
-- ui.settings language: the saved choice (published by the server as ForgeLanguage), else LocaleId.
local Settings = require(Shared.SettingsModel)
local locale = Settings.locale(player.LocaleId, { language = player:GetAttribute("ForgeLanguage") })
local korean = string.sub(locale, 1, 2) == "ko"
local PackText = require(Shared.PackText)
local packRows = PackText.fromEntries(Forge.games["robango-island"].Strings:GetEntries())
local names = PackText.names(packRows)(locale)
local authoredText = PackText.authored(packRows)
-- Client-only labels (clan/outpost, journal, island view) are the cli.* rows of the Strings table.
local clientText = PackText.lookup(packRows, "cli.")
-- Genre panel and screen copy comes from the Strings LocalizationTable, not script source.
require(Forge.genres["survival-coop"].module.PackLocale).use(PackText.lookup(packRows, ""))
require(Forge.genres["survival-coop"].module.ScreenText).use(PackText.lookup(packRows, "scr."))
local WorldText = require(Shared.WorldText)
local TamingText = require(Forge.genres["survival-coop"].module.TamingPanel)
local biomeNames: { [string]: string } = {}
local function localizeJournal(object: Instance)
	if object:IsA("TextLabel") and object.Parent and object.Parent:IsA("BillboardGui") then
		local sign = object.Parent
		local board = sign.Parent
		if board and board:IsA("BasePart") and board.Name == "SignBoard" then
			local rows = string.split(object.Text, "\n")
			biomeNames[if board.Position.X < 0 then "forest" else "marsh"] = rows[if korean then 1 else 2]
			sign:Destroy()
		end
	end
	if object:IsA("ProximityPrompt") and object:GetAttribute("ForgeActionKey") then
		WorldText.localize(object, locale)
		if object:GetAttribute("ForgeSurvey") then
			local label = object.Parent and object.Parent:FindFirstChildWhichIsA("BillboardGui")
			local text = label and label:FindFirstChildWhichIsA("TextLabel")
			if text then
				text.Text = object.ActionText
			end
		end
	elseif object:IsA("ProximityPrompt") and object:GetAttribute("ForgeWarehouse") then
		object.ActionText = WorldText.text(locale, "warehouse_open")
		object.ObjectText = WorldText.text(locale, "warehouse")
	elseif object:IsA("ProximityPrompt") and object:GetAttribute("ForgeJournal") then
		object.ActionText = WorldText.text(locale, "journal_checkpoint")
		object.ObjectText = WorldText.text(locale, "journal")
	elseif object:IsA("ProximityPrompt") and object:GetAttribute("ForgeSurvey") then
		object.ActionText = WorldText.text(locale, "survey")
		local label = object.Parent and object.Parent:FindFirstChildWhichIsA("BillboardGui")
		local text = label and label:FindFirstChildWhichIsA("TextLabel")
		if text then
			text.Text = object.ActionText
		end
	elseif object:IsA("ProximityPrompt") and object:GetAttribute("ForgeStationPanel") then
		local panel = object:GetAttribute("ForgeStationPanel")
		object.ActionText = WorldText.text(locale, "open")
		object.ObjectText =
			WorldText.text(locale, if panel == "modify" or panel == "technical-support" then panel else "island-rank")
	elseif object:IsA("ProximityPrompt") and object:GetAttribute("ForgePanel") then
		object.ActionText = WorldText.text(locale, "interact")
		object.ObjectText = WorldText.text(locale, "guide")
	end
end
workspace.DescendantAdded:Connect(localizeJournal)
for _, object in workspace:GetDescendants() do
	localizeJournal(object)
end
-- Render profile: low on SavedQualityLevel <= low.qualityLevelMax (Automatic on touch).
local RenderBudget = require(Shared.RenderBudget)
local userSettings: any = UserSettings():GetService("UserGameSettings")
local function renderProfile(): RenderBudget.Profile
	local level = tonumber(string.match(tostring(userSettings.SavedQualityLevel), "(%d+)$")) or 0
	return RenderBudget.profiles[RenderBudget.select(level, game:GetService("UserInputService").TouchEnabled)]
end
local profile = renderProfile()
local function applyRender(object: Instance)
	if object:IsA("BasePart") then
		RenderBudget.applyPart(object, profile)
	end
end
workspace.DescendantAdded:Connect(applyRender)
for _, object in workspace:GetDescendants() do
	applyRender(object)
end
userSettings:GetPropertyChangedSignal("SavedQualityLevel"):Connect(function()
	profile = renderProfile()
	for _, object in workspace:GetDescendants() do
		applyRender(object)
	end
end)
-- ui.settings reduced effects / text size (RobangoAudio mirrors the saved settings to attributes).
local function reduceAll()
	local reduced = player:GetAttribute("ForgeReducedEffects") == true
	for _, root in { workspace, game:GetService("Lighting") } do
		for _, object in root:GetDescendants() do
			Settings.reduceEffect(object, reduced)
		end
	end
end
local function scaleAll()
	local scale = player:GetAttribute("ForgeTextScale") or 1
	for _, object in player:WaitForChild("PlayerGui"):GetDescendants() do
		Settings.scaleText(object, scale)
	end
end
player:GetAttributeChangedSignal("ForgeReducedEffects"):Connect(reduceAll)
player:GetAttributeChangedSignal("ForgeTextScale"):Connect(scaleAll)
for _, root in { workspace, game:GetService("Lighting") } do
	root.DescendantAdded:Connect(function(object)
		Settings.reduceEffect(object, player:GetAttribute("ForgeReducedEffects") == true)
	end)
end
player:WaitForChild("PlayerGui").DescendantAdded:Connect(function(object)
	local scale = player:GetAttribute("ForgeTextScale")
	if scale and scale ~= 1 then
		Settings.scaleText(object, scale)
	end
end)
reduceAll()
scaleAll()
local GatheringClient = require(Forge.genres["survival-coop"].module.GatheringClient)
local gathering = GatheringClient.start({ locale = locale, names = names })
gui.Destroying:Connect(gathering.destroy)

local SurvivalHUD = require(Forge.genres["survival-coop"].module.SurvivalHUD)
local content = require(Shared.SurvivalContent)
local worldConfig = require(Shared.SurvivalWorldConfig)
local origin = worldConfig.tribe.origin
gui.Enabled = false
-- One icon catalog for every screen: ItemIcons.new walks the whole item and recipe catalog.
local itemIcons = require(Forge.genres["survival-coop"].module.ItemIcons).new(content, require(Shared.Assets))
local hud = SurvivalHUD.start({
	icons = itemIcons,
	contextual = true,
	openPanel = function(id: string): boolean
		return id == "storage" and require(Forge.genres["survival-coop"].module.RecoveredScreens).storage.show()
			or require(Forge.genres["survival-coop"].module.CharacterSheet).open(id)
	end,
	content = content,
	ui = {
		components = require(Forge.core["ui-kit"].Components),
		grid = require(Forge.core["ui-kit"].InventoryGrid),
		theme = require(Forge.core["ui-kit"].Theme),
	},
	settlementOrigin = Vector3.new(origin.x, origin.y, origin.z),
	locale = locale,
	names = names,
})
local toastGui = Instance.new("ScreenGui")
toastGui.Name, toastGui.ResetOnSpawn = "BiomeToast", false
toastGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
toastGui.Parent = player.PlayerGui
local toast = Instance.new("TextLabel")
toast.Name, toast.BackgroundTransparency, toast.TextScaled = "Biome", 1, true
toast.TextColor3, toast.TextStrokeTransparency = Color3.fromRGB(240, 244, 240), 0.4
toast.Parent = toastGui
local terrain = require(Shared.IslandTerrain)
local hudModel = require(Forge.genres["survival-coop"].module.SurvivalHUDModel)
local biome, remaining = "", 0
local biomeConnection = game:GetService("RunService").RenderStepped:Connect(function(dt)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local current = if root and root:IsA("BasePart") then terrain.sample(root.Position.X, root.Position.Z).biome else ""
	remaining, toast.TextTransparency = hudModel.biomeToast(biome, current, remaining, dt)
	biome = current
	local rect = hudModel.contextHudBounds(toastGui.AbsoluteSize.X).biome
	toast.Position, toast.Size = UDim2.fromOffset(rect.x, rect.y), UDim2.fromOffset(rect.width, rect.height)
	toast.Text, toast.Visible = biomeNames[biome] or "", remaining > 0
end)
gui.Destroying:Connect(function()
	biomeConnection:Disconnect()
	toastGui:Destroy()
end)
local warehouseConnection = game:GetService("ProximityPromptService").PromptTriggered:Connect(function(prompt, actor)
	if actor == player and prompt:GetAttribute("ForgeWarehouse") then
		if not require(Forge.genres["survival-coop"].module.RecoveredScreens).storage.show() then
			hud.open("bag")
		end
	end
end)
gui.Destroying:Connect(function()
	warehouseConnection:Disconnect()
end)
local telegraphs: { [Model]: Highlight } = {}
local telegraphConnection = game:GetService("RunService").Heartbeat:Connect(function()
	local folder = workspace:FindFirstChild("ForgeWildlife")
	if not folder then
		return
	end
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local active = model:GetAttribute("ForgePlayerWindupUntil") ~= nil
		local marker = telegraphs[model]
		if active and not marker then
			local created = Instance.new("Highlight")
			created.Name, created.Adornee, created.Parent = "AttackWindup", model, model
			created.FillColor, created.OutlineColor = Color3.fromRGB(232, 138, 65), Color3.fromRGB(245, 241, 229)
			created.FillTransparency = 0.65
			telegraphs[model] = created
		elseif not active and marker then
			marker:Destroy()
			telegraphs[model] = nil
		end
	end
end)
gui.Destroying:Connect(function()
	telegraphConnection:Disconnect()
end)
gui.Destroying:Connect(hud.destroy)
script.Destroying:Connect(hud.destroy)

local ExtensionPanels = require(Forge.genres["survival-coop"].module.ExtensionPanels)
local panelFactories = table.clone(ExtensionPanels.factories)
for index, factory in panelFactories do
	if factory == require(Forge.genres["survival-coop"].module.MarketPanel).factory then
		panelFactories[index] = function(ctx)
			local trade: any = table.clone(ctx)
			trade.content = content
			trade.icons = table.clone(itemIcons)
			local itemIcon = trade.icons.item
			trade.icons.item = function(id, label)
				return itemIcon(id, label or names[id])
			end
			return require(Forge.genres["survival-coop"].module.CrossServerMarketPanel).factory(trade)
		end
	elseif factory == require(Forge.genres["survival-coop"].module.BrawlPanel).factory then
		-- Weather rows show the ui.icon.weather.* art published for this pack.
		panelFactories[index] = function(ctx)
			local brawl: any = table.clone(ctx)
			brawl.content = content
			brawl.icons = itemIcons
			return factory(brawl)
		end
	end
end
-- Farming and crafting screens (farm plot, sprayer, crop book, processing, recipe preview, inbox).
table.insert(panelFactories, function(ctx)
	local farm: any = table.clone(ctx)
	farm.content = content
	return require(Forge.genres["survival-coop"].module.FarmCraftPanels).factory(farm)
end)
table.insert(panelFactories, function(ctx)
	local buildingPolicy = assert(content.buildingPolicy, "BUILDING_POLICY_REQUIRED")
	local homePolicy = assert(content.homePolicy, "HOME_POLICY_REQUIRED")
	local buildingGui = Instance.new("ScreenGui")
	buildingGui.Name, buildingGui.ResetOnSpawn = "ForgeBuilding", false
	buildingGui.Parent = player:WaitForChild("PlayerGui")
	local sheet = ctx.ui.components.modalSheet(ctx.ui.theme.default, {
		name = "Building",
		title = if korean then "다층 건축" else "Multistorey building",
		parent = buildingGui,
	})
	sheet.frame.Visible = false
	assert(ctx.fitSheet, "BUILDING_SHEET_REQUIRED")(sheet.frame)
	local state: any = { version = 0, parts = {} }
	local floor = 1
	local status = ctx.ui.components.label(ctx.ui.theme.default, {
		text = "",
		size = UDim2.new(1, 0, 0, 64),
		textSize = 15,
		parent = sheet.scroll,
	})
	local function render()
		status.Text = (if korean then "층 " else "Floor ") .. floor
	end
	local connections = {
		sheet.close.Activated:Connect(function()
			sheet.frame.Visible = false
		end),
	}
	local function button(label, callback)
		local control = ctx.ui.components.button(ctx.ui.theme.default, {
			text = label,
			size = UDim2.new(1, 0, 0, 48),
			parent = sheet.scroll,
		})
		table.insert(connections, control.Activated:Connect(callback))
		return control
	end
	button(if korean then "다음 층" else "Next floor", function()
		floor = floor % #homePolicy.floors + 1
		render()
	end)
	for _, kind in { "floor", "pillar", "stairs" } do
		local labels = { floor = "바닥", pillar = "기둥", stairs = "계단" }
		button(if korean then labels[kind] else kind, function()
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root or not root:IsA("BasePart") then
				return
			end
			local cell = buildingPolicy.cellStuds
			local result = ctx.send("survival-coop:building-place", {
				{
					version = state.version,
					part = {
						id = game:GetService("HttpService"):GenerateGUID(false),
						kind = kind,
						x = math.round(root.Position.X / cell),
						z = math.round(root.Position.Z / cell),
						floor = floor,
					},
				},
			})
			if not result.ok then
				status.Text = tostring(result.reason)
			end
		end)
	end
	button(if korean then "현재 칸 회수" else "Remove part at current cell", function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return
		end
		local cell = buildingPolicy.cellStuds
		for id, part in state.parts do
			if
				part.floor == floor
				and part.x == math.round(root.Position.X / cell)
				and part.z == math.round(root.Position.Z / cell)
			then
				local result = ctx.send("survival-coop:building-remove", { { version = state.version, id = id } })
				if not result.ok then
					status.Text = tostring(result.reason)
				end
				break
			end
		end
	end)
	local HudLocale, presets: any = require(Forge.genres["survival-coop"].module.SurvivalHUDLocale), {}
	for preset = 1, 3 do
		presets[preset] = button("", function()
			local result = ctx.send("survival-coop:home-preset", { presets.id, { preset = preset } })
			local ok = if result.ok then HudLocale.text(locale, "preset_applied") else nil
			status.Text = string.format(ok or HudLocale.refusal(locale, result.reason), preset)
		end)
		presets[preset].LayoutOrder = preset - 4 -- above the fold
	end
	local stop = ctx.onSnapshot(function(snapshot)
		state = snapshot.building or { version = 0, parts = {} }
		local home = snapshot.home or {}
		presets.id = home.homeId
		for preset = 1, 3 do
			local key = if preset > (home.presetSlots or 1) then "PRESET_LOCKED" else "preset"
			presets[preset].Visible, presets[preset].Text =
				home.homeId ~= nil,
				string.format(HudLocale.text(locale, key), preset) .. (if preset == (home.terrainPreset or 1)
					then " *"
					else "")
		end
	end)
	assert(ctx.dock, "BUILDING_DOCK_REQUIRED")({
		id = "building",
		label = if korean then "건축" else "Building",
		order = 9,
		setOpen = function(open)
			sheet.frame.Visible = open
		end,
		isOpen = function()
			return sheet.frame.Visible
		end,
	})
	render()
	return {
		destroy = function()
			stop()
			for _, connection in connections do
				connection:Disconnect()
			end
			buildingGui:Destroy()
		end,
	}
end)
-- The clan input sheet's prompt, shared with ui.clan-roles (a membership draft names a clan id).
local askClanText: (() -> string?)? = nil
table.insert(panelFactories, function(ctx)
	local social: any = table.clone(ctx)
	social.content, social.actorId = content, tostring(player.UserId)
	social.icons = itemIcons
	social.encode = function(value)
		return game:GetService("HttpService"):JSONEncode(value)
	end
	social.serverNow = function()
		return workspace:GetServerTimeNow()
	end
	social.text = function(key)
		return clientText(locale, "cli." .. key) or key
	end
	social.onViewport = function(callback)
		local current = workspace.CurrentCamera
		local function fit()
			local size = if current then current.ViewportSize else Vector2.new(800, 600)
			callback(size.X, size.Y)
		end
		fit()
		local connection = if current then current:GetPropertyChangedSignal("ViewportSize"):Connect(fit) else nil
		return function()
			if connection then
				connection:Disconnect()
			end
		end
	end
	local promptGui = Instance.new("ScreenGui")
	promptGui.Name, promptGui.ResetOnSpawn, promptGui.DisplayOrder = "ForgeClanInput", false, 25
	promptGui.Parent = player:WaitForChild("PlayerGui")
	local inputSheet = ctx.ui.components.modalSheet(ctx.ui.theme.default, {
		name = "ClanInput",
		title = social.text("ui.clan"),
		parent = promptGui,
	})
	assert(ctx.fitSheet, "CLAN_SHEET_REQUIRED")(inputSheet.frame)
	local input = Instance.new("TextBox")
	input.Size, input.Text, input.PlaceholderText =
		UDim2.new(1, 0, 0, 48),
		"",
		if korean then "플레이어 ID / 부족 ID / 수량" else "Player ID / clan ID / amount"
	input.Parent = inputSheet.scroll
	inputSheet.frame.Visible = false
	local submit = ctx.ui.components.button(ctx.ui.theme.default, {
		text = if korean then "확인" else "Confirm",
		size = UDim2.new(1, 0, 0, 48),
		parent = inputSheet.scroll,
	})
	local waiting: thread? = nil
	local function finish(value)
		inputSheet.frame.Visible = false
		local receiver = waiting
		waiting = nil
		if receiver then
			task.spawn(receiver, value)
		end
	end
	local submitConnection = submit.Activated:Connect(function()
		finish(input.Text)
	end)
	local cancelConnection = inputSheet.close.Activated:Connect(function()
		finish(nil)
	end)
	local function ask()
		if waiting then
			return nil
		end
		input.Text = ""
		inputSheet.frame.Visible = true
		waiting = coroutine.running()
		return coroutine.yield()
	end
	social.chooseActor, social.chooseTerritory = ask, ask
	askClanText = ask
	social.chooseAmount = function()
		return tonumber(ask())
	end
	social.confirm = function(key: string)
		input.PlaceholderText = social.text(key) .. " / OK"
		return ask() == "OK"
	end
	social.clanWallet = function(id, operation, amount)
		return ctx.send("survival-coop:clan-" .. operation, { id, { amount = amount } })
	end
	social.openMembership = function()
		inputSheet.frame.Visible = true
	end
	local openOutpost: (() -> ())? = nil
	social.openOutposts = function()
		if openOutpost then
			openOutpost()
		end
	end
	local clanPanel = require(Forge.genres["survival-coop"].module.ClanPanel).factory(social)
	social.outpostOptIn = function()
		return ctx.send("survival-coop:outpost-queue", { "rw.team-outpost", { enabled = true } })
	end
	local outpostContext = table.clone(social)
	outpostContext.outpostPolicy = content.outpostPolicy
	outpostContext.dock = function(entry)
		local handle = assert(ctx.dock, "OUTPOST_DOCK_REQUIRED")(entry)
		openOutpost = handle.open
		return handle
	end
	local outpostPanel = require(Forge.genres["survival-coop"].module.SiegeLobbyPanel).factory(outpostContext)
	local create = ctx.ui.components.button(ctx.ui.theme.default, {
		text = if korean then "부족 생성" else "Create clan",
		size = UDim2.new(1, 0, 0, 48),
		parent = inputSheet.scroll,
	})
	local createConnection = create.Activated:Connect(function()
		ctx.send("survival-coop:clan-create", { input.Text })
	end)
	local join = ctx.ui.components.button(ctx.ui.theme.default, {
		text = if korean then "초대받은 부족 가입" else "Join invited clan",
		size = UDim2.new(1, 0, 0, 48),
		parent = inputSheet.scroll,
	})
	local joinConnection = join.Activated:Connect(function()
		ctx.send("survival-coop:clan-join", { input.Text, {} })
	end)
	assert(ctx.dock, "CLAN_DOCK_REQUIRED")({
		id = "clan-membership",
		label = if korean then "부족 가입" else "Clan membership",
		order = 8,
		setOpen = function(open)
			inputSheet.frame.Visible = open
		end,
		isOpen = function()
			return inputSheet.frame.Visible
		end,
	})
	return {
		destroy = function()
			finish(nil)
			submitConnection:Disconnect()
			cancelConnection:Disconnect()
			createConnection:Disconnect()
			joinConnection:Disconnect()
			clanPanel.destroy()
			outpostPanel.destroy()
			promptGui:Destroy()
		end,
	}
end)
table.insert(panelFactories, function(ctx)
	local playerGui = player:WaitForChild("PlayerGui")
	local audioGui = Instance.new("ScreenGui")
	audioGui.Name, audioGui.ResetOnSpawn, audioGui.DisplayOrder, audioGui.Enabled =
		"ForgeAudioSettings", false, 24, false
	audioGui.Parent = playerGui
	local sheet = ctx.ui.components.modalSheet(ctx.ui.theme.default, {
		name = "AudioSettings",
		title = if korean then "설정" else "Settings",
		parent = audioGui,
	})
	assert(ctx.fitSheet, "AUDIO_SHEET_REQUIRED")(sheet.frame)
	sheet.frame.Visible = true
	-- ui.settings: volumes, mute, reduced effects, language and text size. Every row shows
	-- its current value; a tap steps it and persists it through audio-settings.
	local SheetSettings = require(Shared.SettingsModel)
	local current = SheetSettings.normalize(nil)
	local connections = {}
	local buttons: { [string]: TextButton } = {}
	local function render()
		for _, row in SheetSettings.rows(locale, current) do
			local created = buttons[row[1]]
			if created then
				-- Pack text is built once per session, so a new language applies on rejoin.
				local pending = row[1] == "language" and SheetSettings.locale(player.LocaleId, current) ~= locale
				created.Text = row[2] .. (if pending then " - " .. SheetSettings.text(locale, "lang_rejoin") else "")
			end
		end
	end
	for index, row in SheetSettings.rows(locale, current) do
		local key = row[1]
		local created = ctx.ui.components.button(ctx.ui.theme.default, {
			text = row[2],
			size = UDim2.new(1, 0, 0, 48),
			parent = sheet.scroll,
		})
		created.Name, created.LayoutOrder = "Setting-" .. key, index
		buttons[key] = created
		table.insert(
			connections,
			created.Activated:Connect(function()
				local args = SheetSettings.args(current, key, SheetSettings.next(current, key))
				local result = ctx.send("survival-coop:audio-settings", args)
				if result and result.ok then
					current = SheetSettings.fromArgs(args)
					render()
				end
			end)
		)
	end
	table.insert(
		connections,
		sheet.close.Activated:Connect(function()
			audioGui.Enabled = false
		end)
	)
	local disconnect = ctx.onSnapshot(function(snapshot)
		local value = snapshot["audio-settings"]
		if value then
			current = SheetSettings.normalize(value)
			render()
		end
	end)
	assert(ctx.dock, "AUDIO_DOCK_REQUIRED")({
		id = "audio",
		label = if korean then "설정" else "Settings",
		order = 11,
		setOpen = function(open)
			audioGui.Enabled = open
		end,
		isOpen = function()
			return audioGui.Enabled
		end,
	})
	return {
		destroy = function()
			disconnect()
			for _, connection in connections do
				connection:Disconnect()
			end
			audioGui:Destroy()
		end,
	}
end)
table.insert(panelFactories, function(ctx)
	local musicContext: any = table.clone(ctx)
	local http = game:GetService("HttpService")
	local voices: { Sound } = {}
	local scheduled: { thread } = {}
	local disposed = false
	local sampleLengths = {
		piano = 27563,
		guitar = 26019,
		bass = 25357,
		violin = 26019,
		flute = 24696,
		clarinet = 24255,
		trumpet = 23814,
	}
	local drumLengths = { 22712, 33075, 23814, 26460, 28665, 24255, 24696, 25357 }
	local assets = require(Shared.Assets)
	local music = assert(content.music, "MUSIC_POLICY_REQUIRED")
	local function stop()
		for _, pending in scheduled do
			if coroutine.status(pending) ~= "dead" then
				task.cancel(pending)
			end
		end
		for _, sound in voices do
			sound:Destroy()
		end
		scheduled, voices = {}, {}
	end
	musicContext.rules = music
	musicContext.encode = function(value)
		return http:JSONEncode(value)
	end
	musicContext.decode = function(text)
		return http:JSONDecode(text)
	end
	musicContext.requestId = function()
		return http:GenerateGUID(false)
	end
	musicContext.serverNow = function()
		return workspace:GetServerTimeNow()
	end
	musicContext.stop = stop
	musicContext.playAt = function(event: any, instrument: any)
		local id = assets[string.gsub(instrument.assetKey, "[.]", "-")]
		if type(id) ~= "string" or not string.match(id, "^rbxassetid://[1-9]%d*$") then
			return
		end
		local offset, duration, rootPitch = 0, 0, event.pitch
		if event.instrumentId == "drums" then
			for index, count in drumLengths do
				if index + 20 == event.pitch then
					duration = count / 22050
					break
				end
				offset += count / 22050
			end
		else
			local count = sampleLengths[event.instrumentId]
			if not count then
				return
			end
			rootPitch = if event.pitch < 54 then 48 elseif event.pitch < 66 then 60 else 72
			duration, offset = count / 22050, (rootPitch - 48) / 12 * count / 22050
		end
		local pitchScale = 2 ^ ((event.pitch - rootPitch) / 12)
		local lifetime = math.min(event.untilAt - event.at, duration / pitchScale)
		local thread = task.delay(math.max(0, event.at - musicContext.serverNow()), function()
			local late = math.max(0, musicContext.serverNow() - event.at)
			if disposed or late >= lifetime then
				return
			end
			if #voices >= 64 then
				local oldest = table.remove(voices, 1)
				if oldest then
					oldest:Destroy()
				end
			end
			local sound = Instance.new("Sound")
			sound.Name, sound.SoundId = "ForgeInstrument", id
			sound.PlaybackSpeed = pitchScale
			sound.Volume = instrument.gain * event.velocity / music.velocityMax
			sound.Parent = game:GetService("SoundService")
			sound.TimePosition = offset + late * pitchScale
			table.insert(voices, sound)
			sound:Play()
			game:GetService("Debris"):AddItem(sound, lifetime - late)
		end)
		table.insert(scheduled, thread)
	end
	musicContext.confirmDiscard = function()
		-- The editor retains the draft when closing; reopening does not discard it.
		return false
	end
	local editor = require(Forge.genres["survival-coop"].module.ScoreEditorPanel).factory(musicContext)
	local listener = require(Forge.genres["survival-coop"].module.ScorePanel).new({
		rules = content.music,
		serverNow = musicContext.serverNow,
		playAt = musicContext.playAt,
	})
	local disconnect = ctx.onSnapshot(function(snapshot)
		listener.snapshot(snapshot)
	end)
	local screens = require(Forge.genres["survival-coop"].module.MusicScreens).factory(musicContext)
	return {
		destroy = function()
			disposed = true
			disconnect()
			if screens then
				screens.destroy()
			end
			editor.destroy()
			stop()
		end,
	}
end)
table.insert(panelFactories, function(ctx)
	local journalContext: any = table.clone(ctx)
	local playerGui = player:WaitForChild("PlayerGui")
	journalContext.content = content
	journalContext.text = function(key)
		return clientText(locale, "cli.journal." .. key) or authoredText(locale, key) or names[key] or key
	end
	local journalGui: ScreenGui? = nil
	journalContext.createGui = function(name)
		local created = Instance.new("ScreenGui")
		created.Name, created.ResetOnSpawn, created.DisplayOrder = name, false, 24
		created.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		created.Parent = playerGui
		journalGui = created
		return created
	end
	journalContext.level = function(snapshot)
		local survival = snapshot["survival-coop"]
		return if survival and survival.progression then survival.progression.level else 1
	end
	-- p83: 44px per text line centred each chapter in a tall block and pushed the next chapter
	-- below the sheet. Rows are sized to their lines (15px text, 1.2 leading) and grow with wraps.
	journalContext.rowSize = function(lines: number)
		return UDim2.new(1, 0, 0, lines * 18 + 12)
	end
	journalContext.fitRow = function(label: TextLabel)
		label.AutomaticSize, label.TextYAlignment = Enum.AutomaticSize.Y, Enum.TextYAlignment.Top
	end
	journalContext.buttonSize = UDim2.new(1, 0, 0, 48)
	local panel = require(Forge.genres["survival-coop"].module.JournalPanel).factory(journalContext)
	local disconnect = ctx.onSnapshot(function(_, packet)
		panel.snapshot(packet.snapshots or {})
	end)
	assert(ctx.dock, "JOURNAL_DOCK_REQUIRED")({
		id = "journal",
		label = journalContext.text("journal_open"),
		order = 10,
		setOpen = function(open)
			if journalGui then
				journalGui.Enabled = open
			end
			if open then
				panel.open()
			end
		end,
		isOpen = function()
			return journalGui ~= nil and journalGui.Enabled and panel.isOpen()
		end,
	})
	if journalGui then
		journalGui.Enabled = false
	end
	return {
		destroy = function()
			disconnect()
			panel.destroy()
		end,
	}
end)
table.insert(panelFactories, require(Forge.genres["survival-coop"].module.NavigatorPanel).factory)
for _, factory in require(Forge.genres["survival-coop"].module.CharacterPanels).factories do
	table.insert(panelFactories, function(ctx)
		local scoped: any = table.clone(ctx)
		scoped.content = content
		return factory(scoped)
	end)
end
local aerial: any = nil
-- Social / home / trade sheets (ui.home-permissions, ui.home-move, ui.siege-*, ui.transaction,
-- ui.direct-trade, ui.dialogue). Each screen is its own module; this only supplies ports.
table.insert(panelFactories, function(ctx)
	local social: any = table.clone(ctx)
	social.actorId, social.content = tostring(player.UserId), content
	social.outpostPolicy = content.outpostPolicy
	social.destinations = require(Forge.core.domain.home.HomeContent).rules(content).moveDestinations
	social.serverNow = function()
		return workspace:GetServerTimeNow()
	end
	social.journalText = function(key)
		return authoredText(locale, key)
	end
	local module = Forge.genres["survival-coop"].module
	local move = require(module.HomeMovePanel).factory(social)
	social.openHomeMove = move.show
	local list = {
		move,
		require(module.HomePermissionsPanel).factory(social),
		require(module.SiegeMatchPanel).factory(social),
		require(module.SiegeResultsPanel).factory(social),
		require(module.TransactionPanel).factory(social),
		require(module.DirectTradePanel).factory(social),
		require(module.OrganizationsPanel).factory(social),
	}
	local dialogue = require(module.DialoguePanel).factory(social)
	table.insert(list, dialogue)
	ctx.dialogue = dialogue.talk
	return {
		destroy = function()
			for _, panel in list do
				panel.destroy()
			end
		end,
	}
end)
table.insert(panelFactories, audio.panel)
-- Recovered spec screens (tracker, score library, clan treasury/research, territory, build manage,
-- players, arrival); reached through the navigator.
table.insert(panelFactories, function(ctx)
	local scoped: any = table.clone(ctx)
	scoped.content, scoped.actorId = content, tostring(player.UserId)
	scoped.askText = function(): string?
		return if askClanText then askClanText() else nil
	end
	scoped.objective = function(contracts)
		return require(Forge.genres["survival-coop"].module.ContractsPanel).model(locale, contracts, names).objective
	end
	return require(Forge.genres["survival-coop"].module.RecoveredScreens).factory(scoped)
end)
table.insert(panelFactories, function(ctx)
	local scoped: any = table.clone(ctx)
	scoped.content, scoped.actorId = content, tostring(player.UserId)
	return require(Forge.genres["survival-coop"].module.RecoveredScreens).storage.factory(scoped)
end)
local panels = ExtensionPanels.start({
	factories = panelFactories,
	ui = {
		components = require(Forge.core["ui-kit"].Components),
		theme = require(Forge.core["ui-kit"].Theme),
	},
	locale = locale,
	names = names,
	-- One sheet at a time: a panel opening closes the HUD sheet, and the reverse below.
	onOpen = function()
		audio.signal("uiOpen")
		hud.close()
	end,
	contextual = true,
	content = content,
	icons = itemIcons,
	launchers = {
		{
			id = "explore",
			label = if korean then "섬 전경" else "Island view",
			open = function()
				if aerial then
					aerial.toggle()
				end
			end,
		},
		{
			id = "bag",
			label = if korean then "가방" else "Bag",
			open = function()
				hud.open("bag")
			end,
		},
		{
			id = "craft",
			label = if korean then "제작" else "Craft",
			open = function()
				hud.open("craft")
			end,
		},
		{
			id = "build",
			label = if korean then "건설" else "Build",
			open = function()
				hud.open("build")
			end,
		},
		{
			id = "skills",
			label = if korean then "스킬" else "Skills",
			open = function()
				hud.open("skills")
			end,
		},
	},
})
hud.opened:Connect(function()
	if hud.isOpen() then
		panels.closeAll()
	end
end)
gui.Destroying:Connect(panels.destroy)
script.Destroying:Connect(panels.destroy)

local QuarterView = require(Forge.core.infra.camera.QuarterView)
local camera = QuarterView.start(
	if workspace:GetAttribute("ForgeWorldBiome") == "volcano"
		then { yaw = -90, pitch = 35, distance = 110, fieldOfView = 60 }
		else nil
)
gui.Destroying:Connect(camera.stop)
script.Destroying:Connect(camera.stop)
local aerialGui = Instance.new("ScreenGui")
aerialGui.Name, aerialGui.ResetOnSpawn = "ForgeAerial", false
aerialGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
aerialGui.DisplayOrder = 30
aerialGui.Parent = player:WaitForChild("PlayerGui")
local AerialCamera = require(script.Parent.AerialCamera)
local aerialControls = Instance.new("Frame")
aerialControls.Name, aerialControls.Visible = "PhotoControls", false
-- Bottom centre: the top-left belongs to the Roblox chat window, which sat over 돌아가기 and ate
-- its clicks in Studio (p35). On touch the panel rises above the thumbstick and jump band (p83: the
-- controls were 34x40, squeezed between them); every control is at least 44x44.
-- Height follows the visible button rows (AutomaticSize), so wrapped rows never stack (2026-10-23).
aerialControls.AnchorPoint = Vector2.new(0.5, 1)
aerialControls.AutomaticSize = Enum.AutomaticSize.Y
local aerialPadding = Instance.new("UIPadding")
aerialPadding.Parent = aerialControls
aerialControls.BackgroundColor3 = Color3.fromRGB(18, 28, 26)
aerialControls.BackgroundTransparency, aerialControls.Parent = 0.08, aerialGui
local aerialCorner = Instance.new("UICorner")
aerialCorner.CornerRadius, aerialCorner.Parent = UDim.new(0, 10), aerialControls
local aerialLayout = Instance.new("UIGridLayout")
aerialLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
aerialLayout.VerticalAlignment = Enum.VerticalAlignment.Top
aerialLayout.Parent = aerialControls
local aerialTextSize = 14
local function placeAerialControls()
	local placement = AerialCamera.controlsLayout(
		workspace.CurrentCamera.ViewportSize,
		game:GetService("UserInputService").TouchEnabled
	)
	aerialControls.Size = UDim2.fromOffset(placement.width, 0)
	aerialControls.Position = UDim2.new(0.5, 0, 1, -placement.bottom)
	aerialPadding.PaddingTop = UDim.new(0, placement.padding)
	aerialPadding.PaddingBottom = UDim.new(0, placement.padding)
	aerialLayout.CellSize = UDim2.new(1 / placement.columns, -placement.gap, 0, placement.cellHeight)
	aerialLayout.CellPadding = UDim2.fromOffset(placement.gap, 4)
	aerialTextSize = placement.textSize
end
placeAerialControls()
workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(placeAerialControls)
local aerialButtons: any = {}
for index, name in { "Toggle", "Return", "OrbitLeft", "OrbitRight", "HideUI", "ShowUI", "Capture" } do
	local button = Instance.new("TextButton")
	button.Text, button.LayoutOrder, button.Parent =
		clientText(locale, "cli.aerial." .. name) :: string, index, aerialControls
	button.BackgroundColor3, button.TextColor3 = Color3.fromRGB(40, 76, 66), Color3.fromRGB(240, 244, 240)
	button.Font, button.TextSize = Enum.Font.GothamMedium, aerialTextSize
	button.TextWrapped = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius, corner.Parent = UDim.new(0, 8), button
	if name == "Toggle" then
		button.Visible = false
	end
	aerialButtons[name] = button
end
local aerialGuis: { ScreenGui } = {}
for _, child in player.PlayerGui:GetChildren() do
	if child:IsA("ScreenGui") and child ~= aerialGui then
		table.insert(aerialGuis, child)
	end
end
aerial = AerialCamera.new({
	aerial = require(Forge.genres["survival-coop"].module.AerialView),
	workspace = workspace,
	quarterView = camera,
	touch = game:GetService("UserInputService").TouchEnabled,
	controls = aerialControls,
	buttons = aerialButtons,
	guis = aerialGuis,
	atmosphere = function()
		return game:GetService("Lighting"):FindFirstChildOfClass("Atmosphere")
	end,
	-- Every island the player can stand on: role worlds, the Studio preview island (no
	-- ForgeRoleWorld; p83 threw on every tap there), else the ground around the character.
	bounds = function()
		local IslandTerrain = require(Shared.IslandTerrain)
		local character = player.Character
		local at = character and character:FindFirstChild("HumanoidRootPart")
		return AerialCamera.worldBounds(workspace, content.layouts or {}, {
			min = { x = -IslandTerrain.HALF_X, y = IslandTerrain.BOTTOM, z = -IslandTerrain.HALF_Z },
			max = { x = IslandTerrain.HALF_X, y = 12, z = IslandTerrain.HALF_Z },
		}, if at then { x = at.Position.X, y = at.Position.Y, z = at.Position.Z } else nil)
	end,
	scriptable = Enum.CameraType.Scriptable,
	qaCamera = function() -- Studio QA pin: AerialCamera keeps the ForgeQACamera CFrame.
		return game:GetService("RunService"):IsStudio() and workspace:GetAttribute("ForgeQACamera")
	end,
	lookAt = function(position, focus)
		return CFrame.lookAt(Vector3.new(position.x, position.y, position.z), Vector3.new(focus.x, focus.y, focus.z))
	end,
	focusAt = function(point)
		return CFrame.new(point.x, point.y, point.z)
	end,
	captureLocal = function()
		local receiver = coroutine.running()
		game:GetService("CaptureService"):CaptureScreenshot(function(contentId)
			game:GetService("CaptureService"):PromptSaveCapturesToGallery({ contentId }, function(results)
				task.spawn(receiver, { ok = results[contentId] == true })
			end)
		end)
		return coroutine.yield()
	end,
	captureResult = function(result)
		aerialButtons.Capture.Text = if result.ok
			then (if korean then "저장 완료" else "Saved")
			else (if korean then "저장 취소" else "Not saved")
	end,
})
local aerialBack = game:GetService("UserInputService").InputBegan:Connect(function(input, processed)
	if not processed and (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB) then
		aerial.close()
	end
end)
gui.Destroying:Connect(function()
	aerial.destroy()
	aerialBack:Disconnect()
	aerialGui:Destroy()
end)
if game:GetService("RunService"):IsStudio() then
	game:GetService("RunService"):BindToRenderStep("ForgeStudioCapture", Enum.RenderPriority.Last.Value, function()
		local position = workspace:GetAttribute("ForgeStudioCameraPosition")
		local target = workspace:GetAttribute("ForgeStudioCameraTarget")
		local pinned = workspace:GetAttribute("ForgeQACamera")
		if typeof(pinned) == "CFrame" then
			camera.stop()
			workspace.CurrentCamera.CFrame = pinned
		elseif typeof(position) == "Vector3" and typeof(target) == "Vector3" then
			camera.stop()
			workspace.CurrentCamera.CFrame = CFrame.lookAt(position, target)
			workspace.CurrentCamera.FieldOfView = 60
		end
	end)
	script.Destroying:Connect(function()
		game:GetService("RunService"):UnbindFromRenderStep("ForgeStudioCapture")
	end)
end

local DinosaurRig = require(Forge.genres["survival-coop"].module.DinosaurRig)
local CreaturePose = require(script.Parent.CreaturePose)
local function startCreatureAnimation(rigPose: (Model, string, number, number) -> ()): { destroy: () -> () }
	local RunService = game:GetService("RunService")
	local registry: { [Model]: { state: string, elapsed: number, offset: number?, plated: boolean } } = {}
	local NAMEPLATE_STUDS = 40
	local connections: { RBXScriptConnection } = {}
	local destroyed = false
	-- Overhead species name (client-side, per-client locale), shown only up close so a herd
	-- does not become a wall of labels.
	local function nameplate(model: Model)
		local head = model:FindFirstChild("Head") or model.PrimaryPart
		if not head or not head:IsA("BasePart") or head:FindFirstChild("ForgeNameplate") then
			return
		end
		local plate = Instance.new("BillboardGui")
		plate.Name, plate.Size, plate.StudsOffset = "ForgeNameplate", UDim2.fromOffset(160, 26), Vector3.new(0, 2.2, 0)
		plate.MaxDistance, plate.AlwaysOnTop, plate.LightInfluence = NAMEPLATE_STUDS, false, 0
		local text = Instance.new("TextLabel")
		text.Size, text.BackgroundTransparency, text.TextScaled = UDim2.fromScale(1, 1), 1, true
		text.Font, text.TextColor3 = Enum.Font.GothamBold, Color3.fromRGB(255, 248, 230)
		text.TextStrokeTransparency, text.TextStrokeColor3 = 0.3, Color3.fromRGB(30, 24, 18)
		text.Text = TamingText.species(locale, tostring(model:GetAttribute("Species")))
		text.Parent = plate
		plate.Parent = head
	end
	local function discover(instance: Instance)
		local model = if instance:IsA("Model") then instance else instance:FindFirstAncestorOfClass("Model")
		if
			model
			and model:IsA("Model")
			and model:GetAttribute("Species") ~= nil
			and model:FindFirstChild("Torso")
			and model:FindFirstChild("HumanoidRootPart")
		then
			if registry[model] == nil then
				-- Decorative role-world fauna idles on its server-seeded graze phase and wears no
				-- nameplate: it is scenery, not a creature the player can interact with.
				local phase, period = model:GetAttribute("ForgeGrazePhase"), model:GetAttribute("ForgeGrazePeriod")
				-- The nameplate is built lazily on the first frame the creature is within its
				-- MaxDistance, so a herd streaming in at startup costs no BillboardGuis.
				local decor = model:GetAttribute("ForgeDecorFauna") == true
				registry[model] = {
					plated = decor,
					state = "idle",
					elapsed = 0,
					offset = if decor
							and type(phase) == "number"
							and type(period) == "number"
						then phase * period
						elseif decor then 0
						else nil,
				}
			end
		end
	end
	local function bind(folder: Instance)
		for _, child in folder:GetDescendants() do
			discover(child)
		end
		table.insert(connections, folder.DescendantAdded:Connect(discover))
		table.insert(
			connections,
			folder.DescendantRemoving:Connect(function(child)
				if child:IsA("Model") then
					registry[child] = nil
				end
			end)
		)
	end
	local function animated(name: string): boolean
		return name == "Wildlife"
			or name == "OwnedCreatures"
			or name == "ForgeWildlife"
			or name == "ForgeRoleWorld"
			or name == "ForgeSpeciesGallery" -- Studio-only gallery (StudioSetup.gallery)
	end
	for _, child in workspace:GetChildren() do
		if animated(child.Name) then
			bind(child)
		end
	end
	table.insert(
		connections,
		workspace.ChildAdded:Connect(function(child)
			if animated(child.Name) then
				bind(child)
			end
		end)
	)
	table.insert(connections, workspace.DescendantAdded:Connect(discover))
	table.insert(
		connections,
		RunService.RenderStepped:Connect(function(dt)
			local viewCamera = workspace.CurrentCamera
			local entries = {}
			for model in registry do
				local root = model.PrimaryPart
				if root and viewCamera and not (registry[model].offset and not profile.decorFaunaPose) then
					local state = model:GetAttribute("ForgeWildlifeState")
					local distance = (viewCamera.CFrame.Position - root.Position).Magnitude
					if not registry[model].plated and distance <= NAMEPLATE_STUDS then
						registry[model].plated = true
						nameplate(model)
					end
					table.insert(entries, {
						key = model,
						distance = distance,
						urgent = state == "warning" or state == "windup" or state == "attack" or state == "stun",
					})
				end
			end
			local posed = RenderBudget.poses(entries, profile)
			for model, animation in registry do
				local root = model.PrimaryPart
				if not model:IsDescendantOf(workspace) then
					registry[model] = nil
					continue
				end
				if not root then
					continue
				end
				-- Scenery idles cost a pose per frame for nothing the player can act on: the low
				-- profile holds decorative fauna in its rest pose.
				if animation.offset and not profile.decorFaunaPose then
					continue
				end
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local speed = root.AssemblyLinearVelocity.Magnitude
				-- The anchored Studio gallery rig publishes walk without velocity; stride at walking pace.
				if model:GetAttribute("ForgeWildlifeState") == "walk" then
					speed = math.max(speed, 12)
				end
				local serverState = model:GetAttribute("ForgeWildlifeState")
				if humanoid and humanoid.Health <= 0 then
					serverState = "dead"
				end
				local state, elapsed
				if animation.offset then
					animation.elapsed += dt
					state, elapsed = "graze", animation.elapsed + animation.offset
				else
					state, elapsed = CreaturePose.sample(
						animation,
						if type(serverState) == "string" then serverState else nil,
						speed,
						model:GetAttribute("Rider") ~= nil or model:GetAttribute("ForgeMountSpecies") ~= nil,
						dt
					)
				end
				-- Beyond the profile's pose range or cap hold the articulated silhouette.
				-- Telegraphs and death remain active.
				if
					posed[model]
					or not viewCamera
					or state == "warning"
					or state == "windup"
					or state == "attack"
					or state == "dead"
					or state == "stun"
				then
					rigPose(model, state, elapsed, speed)
				end
			end
		end)
	)
	return {
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			for _, connection in connections do
				connection:Disconnect()
			end
			table.clear(connections)
			table.clear(registry)
		end,
	}
end
local creatureAnimation = startCreatureAnimation(DinosaurRig.pose)
gui.Destroying:Connect(creatureAnimation.destroy)
script.Destroying:Connect(creatureAnimation.destroy)

local ProcAssets = require(Forge.core.infra.render.ProcAssets)
local ProcAssetsSpecs = require(Shared.ProcAssets)
local ProcProps = require(Shared.ProcProps)
-- Generated props are decor only: never collide, answer queries or fire touches.
-- With `ground` the prop is then lifted or lowered so its bounding-box bottom sits on it.
local function decorProp(key: string, name: string, cf: CFrame, scale: number, parts: boolean?, ground: number?): Model?
	local built = ProcAssets.build(ProcAssetsSpecs, key, name, { forceParts = parts })
	if not (built and built.PrimaryPart) then
		return nil
	end
	for _, d in built:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	if scale ~= 1 then
		built:ScaleTo(scale)
	end
	built:PivotTo(cf)
	if ground then
		local pieces = {}
		for _, d in built:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(pieces, d)
			end
		end
		built:PivotTo(built:GetPivot() + Vector3.new(0, ProcProps.seat(ground, ProcProps.bottom(pieces)), 0))
	end
	return built
end
-- Every role world (harbor, archipelago stages, home) gets the deterministic ProcProps plan,
-- re-derived from the layout id and seed the server stamps on ForgeRoleWorld.
local function dressRoleWorld(root: Instance)
	local layoutId, seed = root:GetAttribute("ForgeLayoutId"), root:GetAttribute("ForgeWorldSeed")
	if type(layoutId) ~= "string" or type(seed) ~= "number" then
		return
	end
	local layout: any = nil
	for _, candidate in content.layouts :: any do
		if candidate.id == layoutId then
			layout = candidate
		end
	end
	if not layout then
		return
	end
	local Terrain = require(Forge.core.domain.island.ArchipelagoTerrain)
	local columns = if layoutId == "rw.home"
		then {}
		else Terrain.columns(layout, seed, if layoutId == "rw.onboarding" then 16 else 32)
	local placements = ProcProps.limit(ProcProps.plan(layout, columns, seed, content.homePolicy), profile)
	local folder = Instance.new("Folder")
	folder.Name = "ForgeProcProps"
	local ray = RaycastParams.new()
	ray.FilterType = Enum.RaycastFilterType.Include
	ray.FilterDescendantsInstances = { workspace.Terrain }
	ray.IgnoreWater = true
	-- Only the first meshBuildsMax distinct keys may take the EditableMesh path.
	local meshKeys: { string } = {}
	for _, item in placements do
		if root.Parent == nil then
			return
		end
		local p = item.position
		local hit = workspace:Raycast(Vector3.new(p.x, p.y + 60, p.z), Vector3.new(0, -160, 0), ray)
		local y = if hit then hit.Position.Y else p.y
		if not table.find(meshKeys, item.key) and #meshKeys < profile.meshBuildsMax then
			table.insert(meshKeys, item.key)
		end
		local built = decorProp(
			item.key,
			item.name,
			CFrame.new(p.x, y, p.z) * CFrame.Angles(0, math.rad(item.yaw), 0),
			item.scale,
			not table.find(meshKeys, item.key),
			y
		)
		if built then
			built.Parent = folder
		end
	end
	folder.Parent = root
end
-- Decor gate: procedural props are scenery, so on the low profile they wait until the
-- first prompt is shown (or decorDeferSeconds pass) instead of competing with the world,
-- HUD and first gather prompt for the opening frames. High (decorDeferSeconds 0) opens at once.
local decorGate = RenderBudget.gate()
local function watchRoleWorld(child: Instance)
	if child.Name == "ForgeRoleWorld" and not child:FindFirstChild("ForgeProcProps") then
		decorGate.after(function()
			if child.Parent ~= nil and not child:FindFirstChild("ForgeProcProps") then
				task.spawn(dressRoleWorld, child)
			end
		end)
	end
end
local function startDecorGate(): () -> ()
	if profile.decorDeferSeconds <= 0 then
		decorGate.open()
		return function() end
	end
	local shown = game:GetService("ProximityPromptService").PromptShown:Connect(function()
		decorGate.open()
	end)
	task.delay(profile.decorDeferSeconds, decorGate.open)
	return function()
		shown:Disconnect()
	end
end
local stopDecorGate = startDecorGate()
script.Destroying:Connect(stopDecorGate)
userSettings:GetPropertyChangedSignal("SavedQualityLevel"):Connect(function()
	if renderProfile().decorDeferSeconds <= 0 then
		decorGate.open()
	end
end)
workspace.ChildAdded:Connect(watchRoleWorld)
for _, child in workspace:GetChildren() do
	watchRoleWorld(child)
end
decorGate.after(function()
	task.spawn(function()
		local island = workspace:WaitForChild("DevelopmentIsland", 15)
		if island then
			local propPlacements = {
				{ key = "robango-flint-crystal", name = "FlintCrystalMesh", cf = CFrame.new(-10.2, 2.2, 13.2) },
				{ key = "survival-coop-starter-prop", name = "FlintRockMesh", cf = CFrame.new(-11.8, 1.4, 14.6) },
				{ key = "robango-forest-tree", name = "CampTreeMeshNW", cf = CFrame.new(-26, 3.2, 8) },
				{ key = "robango-forest-tree", name = "CampTreeMeshNE", cf = CFrame.new(22, 3.2, 8) },
				{ key = "robango-forest-tree", name = "CampTreeMeshSW", cf = CFrame.new(-24, 3.2, 22) },
			}
			for _, item in RenderBudget.meshes(propPlacements, profile) do
				local built = decorProp(item.key, item.name, item.cf, 1)
				if built then
					built.Parent = island
				end
			end
		end
	end)
end)
