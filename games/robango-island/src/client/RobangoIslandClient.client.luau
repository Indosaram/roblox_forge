--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = ReplicatedStorage:WaitForChild("Forge")
local Shared = Forge.games["robango-island"].src.shared

local audio = require(script.Parent:WaitForChild("RobangoAudio")).start(
	require(Forge.core.infra.audio.SoundBank),
	require(Forge.genres["survival-coop"].module.AudioDirector),
	require(Shared.Assets),
	require(Shared.RobangoAudioCatalog)
)
script.Destroying:Connect(audio.destroy)

local Client = require(Forge.core.infra.genre.Client)
local gui = Client.start({ controls = require(Shared.GenreUI) })
gui.Destroying:Connect(audio.destroy)

-- The pack ships en-us and ko-kr; every survival-coop view picks Korean from a "ko" prefix.
local locale = game:GetService("Players").LocalPlayer.LocaleId
local names = require(Shared.EntityNames)(locale)
local function localizeJournal(object: Instance)
	if object:IsA("ProximityPrompt") and object:GetAttribute("ForgeJournal") then
		object.ActionText = if string.sub(locale, 1, 2) == "ko" then "일지 확인" else "Journal checkpoint"
		object.ObjectText = if string.sub(locale, 1, 2) == "ko" then "일지" else "Journal"
	elseif object:IsA("ProximityPrompt") and object:GetAttribute("ForgePanel") then
		object.ActionText = if string.sub(locale, 1, 2) == "ko" then "대화 / 이용" else "Talk / use"
		object.ObjectText = if string.sub(locale, 1, 2) == "ko" then "항구 안내" else "Harbor guide"
	end
end
workspace.DescendantAdded:Connect(localizeJournal)
for _, object in workspace:GetDescendants() do
	localizeJournal(object)
end

local GatheringClient = require(Forge.genres["survival-coop"].module.GatheringClient)
local gathering = GatheringClient.start({ locale = locale, names = names })
gui.Destroying:Connect(gathering.destroy)

local SurvivalHUD = require(Forge.genres["survival-coop"].module.SurvivalHUD)
local content = require(Shared.SurvivalContent)
local worldConfig = require(Shared.SurvivalWorldConfig)
local origin = worldConfig.tribe.origin
gui.Enabled = false
local hud = SurvivalHUD.start({
	icons = require(Forge.genres["survival-coop"].module.ItemIcons).new(content, require(Shared.Assets)),
	contextual = true,
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
-- Server-published attack intent only: no client prediction can confirm a hit.
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
			trade.icons = require(Forge.genres["survival-coop"].module.ItemIcons).new(content, require(Shared.Assets))
			return require(Forge.genres["survival-coop"].module.CrossServerMarketPanel).factory(trade)
		end
	end
end
table.insert(panelFactories, function(ctx)
	local buildingPolicy = assert(content.buildingPolicy, "BUILDING_POLICY_REQUIRED")
	local homePolicy = assert(content.homePolicy, "HOME_POLICY_REQUIRED")
	local player = game:GetService("Players").LocalPlayer
	local buildingGui = Instance.new("ScreenGui")
	buildingGui.Name, buildingGui.ResetOnSpawn = "ForgeBuilding", false
	buildingGui.Parent = player:WaitForChild("PlayerGui")
	local sheet = ctx.ui.components.modalSheet(ctx.ui.theme.default, {
		name = "Building",
		title = if string.sub(locale, 1, 2) == "ko" then "다층 건축" else "Multistorey building",
		parent = buildingGui,
	})
	sheet.frame.Visible = false
	assert(ctx.fitSheet, "BUILDING_SHEET_REQUIRED")(sheet.frame)
	local state: any = { version = 0, parts = {} }
	local floor = 1
	local status = Instance.new("TextLabel")
	status.Size, status.TextWrapped, status.Parent = UDim2.new(1, 0, 0, 64), true, sheet.scroll
	local function render()
		status.Text = (if string.sub(locale, 1, 2) == "ko" then "층 " else "Floor ") .. floor
	end
	local connections = {}
	local function button(label, callback)
		local control = ctx.ui.components.button(ctx.ui.theme.default, {
			text = label,
			size = UDim2.new(1, 0, 0, 48),
			parent = sheet.scroll,
		})
		table.insert(connections, control.Activated:Connect(callback))
	end
	button(if string.sub(locale, 1, 2) == "ko" then "다음 층" else "Next floor", function()
		floor = floor % #homePolicy.floors + 1
		render()
	end)
	for _, kind in { "floor", "pillar", "stairs" } do
		local labels = { floor = "바닥", pillar = "기둥", stairs = "계단" }
		button(if string.sub(locale, 1, 2) == "ko" then labels[kind] else kind, function()
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
	button(if string.sub(locale, 1, 2) == "ko" then "현재 칸 회수" else "Remove part at current cell", function()
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
	local stop = ctx.onSnapshot(function(snapshot)
		state = snapshot.building or { version = 0, parts = {} }
	end)
	assert(ctx.dock, "BUILDING_DOCK_REQUIRED")({
		id = "building",
		label = if string.sub(locale, 1, 2) == "ko" then "건축" else "Building",
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
table.insert(panelFactories, function(ctx)
	local social: any = table.clone(ctx)
	local korean = string.sub(locale, 1, 2) == "ko"
	local player = game:GetService("Players").LocalPlayer
	social.content, social.actorId = content, tostring(player.UserId)
	social.icons = require(Forge.genres["survival-coop"].module.ItemIcons).new(content, require(Shared.Assets))
	social.encode = function(value)
		return game:GetService("HttpService"):JSONEncode(value)
	end
	social.serverNow = function()
		return workspace:GetServerTimeNow()
	end
	social.text = function(key)
		local labels = {
			["ui.clan"] = { "Clan", "부족" },
			["clan.invite"] = { "Invite", "초대" },
			["clan.deposit"] = { "Deposit", "입금" },
			["clan.withdraw"] = { "Withdraw", "출금" },
			["clan.level"] = { "Level", "레벨" },
			["clan.territory"] = { "Territory", "영토" },
			["ui.outpost"] = { "Team outpost", "팀 거점" },
			["outpost.owner"] = { "Owner", "소유 부족" },
			["outpost.remaining"] = { "Seconds remaining", "남은 시간" },
			["outpost.active"] = { "Capture in progress", "점령 진행 중" },
			["outpost.settled"] = { "Match finished", "경기 종료" },
			["outpost.winner"] = { "Winner", "승리 부족" },
			["outpost.opt-in"] = { "Join team queue", "팀 대기열 참가" },
		}
		local row = labels[key]
		return if row then row[if korean then 2 else 1] else key
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
	social.chooseAmount = function()
		return tonumber(ask())
	end
	social.confirm = function(key: string)
		input.PlaceholderText = key .. " / OK"
		return ask() == "OK"
	end
	social.clanWallet = function(id, operation, amount)
		return ctx.send("survival-coop:clan-" .. operation, { id, { amount = amount } })
	end
	local clanPanel = require(Forge.genres["survival-coop"].module.ClanPanel).factory(social)
	social.outpostOptIn = function()
		return ctx.send("survival-coop:outpost-queue", { "rw.team-outpost", { enabled = true } })
	end
	local outpostPanel = require(Forge.genres["survival-coop"].module.OutpostPanel).factory(social)
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
	local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local audioGui = Instance.new("ScreenGui")
	audioGui.Name, audioGui.ResetOnSpawn, audioGui.DisplayOrder, audioGui.Enabled =
		"ForgeAudioSettings", false, 24, false
	audioGui.Parent = playerGui
	local korean = string.sub(locale, 1, 2) == "ko"
	local sheet = ctx.ui.components.modalSheet(ctx.ui.theme.default, {
		name = "AudioSettings",
		title = if korean then "소리" else "Audio",
		parent = audioGui,
	})
	assert(ctx.fitSheet, "AUDIO_SHEET_REQUIRED")(sheet.frame)
	local muted, volume = false, 1
	local connections = {}
	local function button(label, callback)
		local created = ctx.ui.components.button(ctx.ui.theme.default, {
			text = label,
			size = UDim2.new(1, 0, 0, 48),
			parent = sheet.scroll,
		})
		table.insert(connections, created.Activated:Connect(callback))
		return created
	end
	local muteButton: TextButton
	muteButton = button(if korean then "음소거" else "Mute", function()
		ctx.send("survival-coop:audio-settings", { not muted, volume })
	end)
	for _, gain in { 0.25, 0.5, 0.75, 1 } do
		button(tostring(gain * 100) .. "%", function()
			ctx.send("survival-coop:audio-settings", { muted, gain })
		end)
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
			muted, volume = value.muted, value.volume
			muteButton.Text = if muted
				then (if korean then "음소거 해제" else "Unmute")
				else (if korean then "음소거" else "Mute")
		end
	end)
	assert(ctx.dock, "AUDIO_DOCK_REQUIRED")({
		id = "audio",
		label = if korean then "소리" else "Audio",
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
	return {
		destroy = function()
			disposed = true
			disconnect()
			editor.destroy()
			stop()
		end,
	}
end)
table.insert(panelFactories, function(ctx)
	local journalContext: any = table.clone(ctx)
	local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local korean = string.sub(locale, 1, 2) == "ko"
	local labels = {
		journal_open = { "Open journal", "일지 열기" },
		journal_claim = { "Complete chapter", "챕터 완료" },
		LEVEL_GATE = { "Requires level 20", "레벨 20 필요" },
		CHAPTER_ORDER = { "Complete the previous chapter first", "이전 챕터를 먼저 완료하세요" },
		ALREADY_COMPLETED = { "Completed", "완료" },
		CHAPTER_ACTIVE = { "Finish the active chapter first", "진행 중인 챕터를 먼저 완료하세요" },
		OBJECTIVES_INCOMPLETE = { "Complete every objective first", "모든 목표를 먼저 완료하세요" },
	}
	journalContext.content = content
	journalContext.text = function(key)
		local row = labels[key]
		return if row then row[if korean then 2 else 1] else names[key] or key
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
	journalContext.rowSize = function(lines: number)
		return UDim2.new(1, 0, 0, lines * 44)
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
local panels = ExtensionPanels.start({
	factories = panelFactories,
	ui = {
		components = require(Forge.core["ui-kit"].Components),
		theme = require(Forge.core["ui-kit"].Theme),
	},
	locale = locale,
	names = names,
	-- One sheet at a time: a panel opening closes the HUD sheet, and the reverse below.
	onOpen = hud.close,
	contextual = true,
	launchers = {
		{
			id = "bag",
			label = if string.sub(locale, 1, 2) == "ko" then "가방" else "Bag",
			open = function()
				hud.open("bag")
			end,
		},
		{
			id = "craft",
			label = if string.sub(locale, 1, 2) == "ko" then "제작" else "Craft",
			open = function()
				hud.open("craft")
			end,
		},
		{
			id = "build",
			label = if string.sub(locale, 1, 2) == "ko" then "건설" else "Build",
			open = function()
				hud.open("build")
			end,
		},
		{
			id = "skills",
			label = if string.sub(locale, 1, 2) == "ko" then "스킬" else "Skills",
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
local camera = QuarterView.start()
gui.Destroying:Connect(camera.stop)
script.Destroying:Connect(camera.stop)
local aerialGui = Instance.new("ScreenGui")
aerialGui.Name, aerialGui.ResetOnSpawn = "ForgeAerial", false
aerialGui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local aerialControls = Instance.new("Frame")
aerialControls.Size, aerialControls.Position = UDim2.new(1, -24, 0, 92), UDim2.new(0, 12, 1, -104)
aerialControls.BackgroundTransparency, aerialControls.Parent = 0.2, aerialGui
local aerialLayout = Instance.new("UIGridLayout")
aerialLayout.CellSize, aerialLayout.CellPadding = UDim2.new(0.24, 0, 0, 40), UDim2.fromOffset(4, 4)
aerialLayout.Parent = aerialControls
local aerialButtons: any = {}
local aerialLabels = {
	Return = { "Return", "돌아가기" },
	Toggle = { "Island view", "섬 전경" },
	OrbitLeft = { "Rotate left", "왼쪽 회전" },
	OrbitRight = { "Rotate right", "오른쪽 회전" },
	HideUI = { "Hide UI", "UI 숨기기" },
	ShowUI = { "Show UI", "UI 표시" },
	Capture = { "Capture", "촬영" },
}
for index, name in { "Toggle", "Return", "OrbitLeft", "OrbitRight", "HideUI", "ShowUI", "Capture" } do
	local button = Instance.new("TextButton")
	button.Text, button.LayoutOrder, button.Parent =
		aerialLabels[name][if string.sub(locale, 1, 2) == "ko" then 2 else 1], index, aerialControls
	aerialButtons[name] = button
end
local aerialGuis: { ScreenGui } = {}
for _, child in game:GetService("Players").LocalPlayer.PlayerGui:GetChildren() do
	if child:IsA("ScreenGui") and child ~= aerialGui then
		table.insert(aerialGuis, child)
	end
end
local aerial = require(script.Parent.AerialCamera).new({
	aerial = require(Forge.genres["survival-coop"].module.AerialView),
	workspace = workspace,
	quarterView = camera,
	controls = aerialControls,
	buttons = aerialButtons,
	guis = aerialGuis,
	bounds = function()
		local minimum = Vector3.new(math.huge, math.huge, math.huge)
		local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
		local root = assert(workspace:FindFirstChild("ForgeRoleWorld"), "AERIAL_WORLD_REQUIRED")
		for _, part in root:GetDescendants() do
			if part:IsA("BasePart") then
				local cf, half = part.CFrame, part.Size / 2
				for _, x in { -1, 1 } do
					for _, y in { -1, 1 } do
						for _, z in { -1, 1 } do
							local point = cf:PointToWorldSpace(Vector3.new(x * half.X, y * half.Y, z * half.Z))
							minimum, maximum = minimum:Min(point), maximum:Max(point)
						end
					end
				end
			end
		end
		return { x = minimum.X, y = minimum.Y, z = minimum.Z }, { x = maximum.X, y = maximum.Y, z = maximum.Z }
	end,
	scriptable = Enum.CameraType.Scriptable,
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
			then (if string.sub(locale, 1, 2) == "ko" then "저장 완료" else "Saved")
			else (if string.sub(locale, 1, 2) == "ko" then "저장 취소" else "Not saved")
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
		if typeof(position) == "Vector3" and typeof(target) == "Vector3" then
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
	local registry: { [Model]: { state: string, elapsed: number } } = {}
	local connections: { RBXScriptConnection } = {}
	local destroyed = false
	local function discover(instance: Instance)
		local model = if instance:IsA("Model") then instance else instance:FindFirstAncestorOfClass("Model")
		if
			model
			and model:IsA("Model")
			and model:FindFirstChild("Torso")
			and model:FindFirstChild("HumanoidRootPart")
		then
			registry[model] = registry[model] or { state = "idle", elapsed = 0 }
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
	for _, child in workspace:GetChildren() do
		if child.Name == "Wildlife" or child.Name == "OwnedCreatures" or child.Name == "ForgeWildlife" then
			bind(child)
		end
	end
	table.insert(
		connections,
		workspace.ChildAdded:Connect(function(child)
			if child.Name == "Wildlife" or child.Name == "OwnedCreatures" or child.Name == "ForgeWildlife" then
				bind(child)
			end
		end)
	)
	table.insert(connections, workspace.DescendantAdded:Connect(discover))
	table.insert(
		connections,
		RunService.RenderStepped:Connect(function(dt)
			local viewCamera = workspace.CurrentCamera
			for model, animation in registry do
				local root = model.PrimaryPart
				if not model:IsDescendantOf(workspace) then
					registry[model] = nil
					continue
				end
				if not root then
					continue
				end
				local distance = if viewCamera then (viewCamera.CFrame.Position - root.Position).Magnitude else 0
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local speed = root.AssemblyLinearVelocity.Magnitude
				local serverState = model:GetAttribute("ForgeWildlifeState")
				if humanoid and humanoid.Health <= 0 then
					serverState = "dead"
				end
				local state, elapsed = CreaturePose.sample(
					animation,
					if type(serverState) == "string" then serverState else nil,
					speed,
					model:GetAttribute("Rider") ~= nil or model:GetAttribute("ForgeMountSpecies") ~= nil,
					dt
				)
				-- At long range hold the articulated silhouette. Telegraphs remain active.
				if
					distance <= 100
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
task.spawn(function()
	local island = workspace:WaitForChild("DevelopmentIsland", 15)
	if island then
		local propPlacements = {
			{ key = "robango-flint-crystal", name = "FlintCrystalMesh", cf = CFrame.new(-10.2, 2.2, 13.2) },
			{ key = "survival-coop-starter-prop", name = "FlintRockMesh", cf = CFrame.new(-11.8, 1.4, 14.6) },
			{ key = "robango-supply-crate", name = "WarehouseCrateMesh", cf = CFrame.new(13.2, 1.2, -9.2) },
			{ key = "robango-forest-tree", name = "CampTreeMeshNW", cf = CFrame.new(-26, 3.2, 8) },
			{ key = "robango-forest-tree", name = "CampTreeMeshNE", cf = CFrame.new(22, 3.2, 8) },
			{ key = "robango-forest-tree", name = "CampTreeMeshSW", cf = CFrame.new(-24, 3.2, 22) },
		}
		for _, item in propPlacements do
			local built = ProcAssets.build(ProcAssetsSpecs, item.key, item.name)
			if built and built.PrimaryPart then
				for _, d in built:GetDescendants() do
					if d:IsA("BasePart") then
						d.CanCollide = false
						d.CanQuery = false
						d.CanTouch = false
					end
				end
				built:PivotTo(item.cf)
				built.Parent = island
			end
		end
	end
end)
