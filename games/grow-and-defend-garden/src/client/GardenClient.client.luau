--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = ReplicatedStorage:WaitForChild("Forge")
local Config = require(Forge.games["grow-and-defend-garden"].src.shared.Config)
local Assets = require(Forge.games["grow-and-defend-garden"].src.shared.Assets)
local AudioKit = require(Forge.core["ui-kit"].genre.AudioKit)
-- The genre's declared cue bindings, in the runtime form the genre package ships.
-- The pack names the canonical action it just committed and the kit resolves the
-- cue from that declaration, so no cue key appears in this file.
local GrowHarvestAudio = require(Forge.genres["grow-harvest"].module.Audio)

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Plant = Remotes:WaitForChild("Plant") :: RemoteFunction
local BuySeed = Remotes:WaitForChild("BuySeed") :: RemoteFunction
local Harvest = Remotes:WaitForChild("Harvest") :: RemoteFunction
local Sell = Remotes:WaitForChild("Sell") :: RemoteFunction
local StateChanged = Remotes:WaitForChild("StateChanged") :: RemoteEvent

-- The pack's client owns its own transport, so it reports each committed action
-- instead of subscribing to ForgeState packets. A cue whose asset is missing (or
-- not uploaded yet) is recorded on the kit's folder and plays nothing.
local audio = AudioKit.start({
	genre = "grow-harvest",
	audio = GrowHarvestAudio,
	contentIds = Assets,
})

local function create(className: string, props: { [string]: any }, parent: Instance): any
	local instance = Instance.new(className) :: any
	for key, value in props do
		instance[key] = value
	end
	instance.Parent = parent
	return instance
end

local screenGui = create("ScreenGui", { Name = "GardenGui", ResetOnSpawn = false }, playerGui)
local frame = create("Frame", {
	Name = "GardenFrame",
	-- 340 px overflowed 320-pt phones and sat under notches. Clamp to the viewport
	-- and inset from the real safe area instead of a fixed 20 px top-right anchor.
	-- A 0.9 scale also covered most of the world on desktop and every wide screen:
	-- the panel is a readout plus three short button rows, so it gets a readable
	-- fixed cap and shrinks to 0.9 only when the viewport is narrower than that.
	Size = UDim2.fromScale(0.9, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Position = UDim2.new(1, -8, 0, 8),
	AnchorPoint = Vector2.new(1, 0),
	BackgroundColor3 = Color3.fromRGB(28, 38, 28),
	BorderSizePixel = 0,
}, screenGui)
-- GuiService inset keeps the top row below the notch/topbar on every device.
-- The chat frame is a reserved region: Roblox draws it top-left (measured on a
-- 390x844 phone: x 0..156, y 105..379) and the QA gate rejects any owned control
-- inside it (CRITICAL_UI_CHAT_OVERLAP). The 360 px cap cannot fit beside chat on
-- a narrow phone, and chat is tall enough that dropping below it wastes the top
-- half of the screen, so a viewport too narrow to sit beside chat anchors the
-- panel to the bottom-right instead. Width decides this, not height.
--
-- The bottom-right corner is not free on touch: Roblox draws its jump button
-- there (measured top edge at y~735 on a 390x844 phone), and a flush-bottom panel
-- put that button on top of the last seed chip.
local CHAT_RESERVED_WIDTH = 160
local TOUCH_CONTROL_CLEARANCE = 120
do
	local gui = game:GetService("GuiService")
	local input = game:GetService("UserInputService")
	local inset = gui:GetGuiInset()
	local function place()
		local camera = workspace.CurrentCamera
		local viewport = if camera ~= nil then camera.ViewportSize else Vector2.new(1280, 720)
		-- 360 is the panel cap below, and 16 keeps a visible gutter beside chat.
		local besideChat = viewport.X >= CHAT_RESERVED_WIDTH + 360 + 16
		if besideChat then
			frame.AnchorPoint = Vector2.new(1, 0)
			frame.Position = UDim2.new(1, -8, 0, inset.Y + 8)
		else
			-- Bottom-right is diagonally opposite chat's top-left band at every
			-- viewport height, so no fixed pixel offset has to track chat's size.
			local bottom = if input.TouchEnabled then TOUCH_CONTROL_CLEARANCE else 8
			frame.AnchorPoint = Vector2.new(1, 1)
			frame.Position = UDim2.new(1, -8, 1, -bottom)
		end
	end
	place()
	input:GetPropertyChangedSignal("TouchEnabled"):Connect(place)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local camera = workspace.CurrentCamera
		if camera ~= nil then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(place)
		end
		place()
	end)
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(place)
	end
end
-- SortOrder must be stated: the default is `Name`, which sorted the panel
-- alphabetically (Barricades, Coins, Held, NextWave, plot-1..) and ignored every
-- element's LayoutOrder, which put the seed picker below the plots it controls.
create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, frame)
-- 0.9 of a 1280-wide viewport is 1152 px of panel over a 340 px-wide HUD's worth of
-- text: it covered most of the world in the release capture. The constraint keeps
-- the phone behaviour (fill the width, inset from notches) and caps it on desktop.
create("UISizeConstraint", { MaxSize = Vector2.new(360, math.huge) }, frame)

local function makeLabel(parent: Instance, name: string, size: UDim2, color: Color3, textSize: number): TextLabel
	return create("TextLabel", {
		Name = name,
		Size = size,
		Text = "",
		TextColor3 = color,
		TextSize = textSize,
		BackgroundTransparency = 1,
	}, parent)
end

local coinsLabel = makeLabel(frame, "Coins", UDim2.new(1, 0, 0, 26), Color3.fromRGB(255, 215, 0), 18)
local barricadeLabel = makeLabel(frame, "Barricades", UDim2.new(1, 0, 0, 20), Color3.fromRGB(200, 220, 255), 14)
local waveLabel = makeLabel(frame, "NextWave", UDim2.new(1, 0, 0, 20), Color3.fromRGB(255, 170, 80), 14)
-- "Last wave: none yet" is 176 px of text that says nothing on a first play, and on a
-- 390x844 phone the panel below chat and above the jump button has no room for it.
-- Waves read from NextWave; the last-wave summary appears only once a wave has run.
local lastWaveLabel = makeLabel(frame, "LastWave", UDim2.new(1, 0, 0, 20), Color3.fromRGB(230, 230, 230), 14)
lastWaveLabel.Visible = false
-- What the Sell button will sell, so harvesting has visible payoff before selling.
local heldLabel = makeLabel(frame, "Held", UDim2.new(1, 0, 0, 20), Color3.fromRGB(190, 240, 190), 14)
heldLabel.Text = "Held: none"
-- The list sorts by LayoutOrder and breaks ties alphabetically, which reordered the
-- readout (Barricades before Coins) and pushed the seed picker below the plots it
-- controls. These orders are the reading order the panel is designed around.
coinsLabel.LayoutOrder = 1
barricadeLabel.LayoutOrder = 2
waveLabel.LayoutOrder = 3
lastWaveLabel.LayoutOrder = 4
heldLabel.LayoutOrder = 5

-- A row remembers the crop the player chose to buy/plant next. Rotation was the only
-- behaviour before, which meant the player never made a decision: the defense value
-- of a harvest and its price differ by crop, so the choice IS the game.
type Row = { label: TextLabel, cursor: number, cropId: string?, chosen: string }

local function makeButton(row: Instance, name: string, offset: number, color: Color3, onClick: () -> ())
	-- The instance name is the qa click target (`plot-1.Sell`, etc.), so it must be
	-- unique per row and stable: a Text-only button is unfindable by the driver.
	return create("TextButton", {
		Name = name,
		Size = UDim2.fromScale(0.16, 1),
		Position = UDim2.fromScale(0.355 + offset * 0.1625, 0),
		Text = name,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundColor3 = color,
	}, row).MouseButton1Click:Connect(onClick)
end

-- Seed choice is one shared selection: which crop the Buy and Plant buttons act on
-- for every plot. One per-row selector made five buttons in a 0.34-wide label slot
-- (0.355 + 4 * 0.1625 + 0.16 = 1.165 of the row width) and clipped the last label,
-- the same failure the collect-raid Claim button had. A single chooser above the
-- rows keeps four buttons that fit and still gives the player the decision.
local selectedCrop: string = Config.cropOrder[1]

local pickerRow =
	create("Frame", { Name = "seed-picker", Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 }, frame)
pickerRow.LayoutOrder = 6
local pickerLabel = makeLabel(pickerRow, "SeedChoice", UDim2.fromScale(1, 0.55), Color3.fromRGB(220, 255, 220), 12)
local pickerButtons: { TextButton } = {}
-- Seeds in hand for the selected crop. Declared before refreshPicker because the
-- picker line states it, and the state handler is what keeps it current.
local selectedSeeds = 0
-- Latest server-side in-hand seed counts, keyed by crop id, at module scope so the
-- picker can re-read the count for whichever crop the player just selected.
local seeds: { [string]: number } = {}
local function refreshPicker()
	local crop = Config.crops[selectedCrop]
	-- Seeds are keyed by crop, so the count is read for the CURRENT selection before the
	-- line is built. Reading it afterwards rendered the previous crop's count beside the
	-- new crop's name -- a wrong number at the moment the player chooses what to plant.
	selectedSeeds = seeds[selectedCrop] or 0
	if crop ~= nil then
		-- Growth, price and defense are the whole trade-off: a slower crop is worth
		-- more Coins and defends harder, which is what answers the wave curve. This
		-- line has to fit 351 px on a 390 px phone: "Seed: carrot  20s  10 coins
		-- +1 defense  (0 in hand)" clipped to "(0 in han", so the abbreviations
		-- are deliberate and the count trails the line.
		pickerLabel.Text = string.format(
			"%s: %ds, %dc, +%d def, %d held",
			selectedCrop,
			crop.growthSeconds,
			crop.sellPrice,
			crop.defense or 1,
			selectedSeeds
		)
	end
	for _, button in pickerButtons do
		local isSelected = button:GetAttribute("cropId") == selectedCrop
		button.BackgroundColor3 = if isSelected then Color3.fromRGB(70, 140, 80) else Color3.fromRGB(45, 60, 48)
	end
end

local pickerBar =
	create("Frame", { Name = "seed-buttons", Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 }, frame)
pickerBar.LayoutOrder = 7
local pickerLayout = create("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 4),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, pickerBar)
pickerLayout.Parent = pickerBar
for index, cropId in Config.cropOrder do
	local button: TextButton = create("TextButton", {
		Name = "seed-" .. cropId,
		LayoutOrder = index,
		Size = UDim2.fromScale(1 / #Config.cropOrder, 1),
		Text = cropId,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundColor3 = Color3.fromRGB(45, 60, 48),
	}, pickerBar)
	button:SetAttribute("cropId", cropId)
	button.MouseButton1Click:Connect(function()
		selectedCrop = cropId
		refreshPicker()
	end)
	table.insert(pickerButtons, button)
end
refreshPicker()

local rows: { Row } = {}
-- Latest server-side held (harvested, unsold) crop counts, keyed by crop id.
local heldCrops: { [string]: number } = {}
for index = 1, Config.plotCount do
	local plotIndex = index
	local row =
		create("Frame", { Name = "plot-" .. index, Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 }, frame)
	row.LayoutOrder = 7 + index
	local label = makeLabel(row, "Status", UDim2.fromScale(0.34, 1), Color3.fromRGB(240, 240, 240), 12)
	label.Text = string.format("%d: empty", plotIndex)

	local rowState: Row = { label = label, cursor = 0, cropId = nil, chosen = "" }
	rows[plotIndex] = rowState

	-- The seed a row buys next is the seed its Plant button plants, so Buy and Plant
	-- are two stages of the genre's buy -> plant -> harvest -> sell loop. The player
	-- picks which crop via the Seed button, which cycles the ladder.
	local function nextCrop(): string
		return selectedCrop
	end

	makeButton(row, "Buy", 0, Color3.fromRGB(90, 90, 140), function()
		local bought = BuySeed:InvokeServer(nextCrop())
		audio.result("grow-harvest:buy-seed", { ok = bought == true })
	end)
	makeButton(row, "Plant", 1, Color3.fromRGB(60, 130, 70), function()
		local cropId = nextCrop()
		local planted = Plant:InvokeServer(plotIndex, cropId)
		-- Advance only on a committed plant. Advancing first made a failed plant
		-- silently rotate the row onto a seed the player does not hold.
		if planted == true then
			rowState.cursor += 1
		end
		audio.result("grow-harvest:plant", { ok = planted == true })
	end)
	makeButton(row, "Harvest", 2, Color3.fromRGB(150, 120, 50), function()
		local harvested = Harvest:InvokeServer(plotIndex)
		audio.result("grow-harvest:harvest", { ok = harvested ~= nil })
	end)
	makeButton(row, "Sell", 3, Color3.fromRGB(80, 90, 150), function()
		-- Sell one unit of whatever the player actually holds. The old target was the
		-- plot's cropId, which stays set after a harvest and is not held inventory.
		for _, heldCropId in Config.cropOrder do
			if (heldCrops[heldCropId] or 0) > 0 then
				local price = Sell:InvokeServer(heldCropId)
				audio.result("grow-harvest:sell-held", { ok = type(price) == "number" and price > 0 })
				return
			end
		end
	end)
end

StateChanged.OnClientEvent:Connect(function(info: any)
	if type(info) ~= "table" then
		return
	end
	coinsLabel.Text = string.format("Coins: %d", info.coins or 0)
	barricadeLabel.Text = string.format("Barricade points: %d", info.barricades or 0)
	waveLabel.Text = string.format("Next wave in %ds", math.floor(info.nextWaveIn or 0))

	local last = info.lastWave
	if last == nil then
		lastWaveLabel.Text = "Last wave: none yet"
		lastWaveLabel.Visible = false
	else
		lastWaveLabel.Text = string.format(
			"Last wave %d: %s (defense %d vs %d)",
			last.index or 0,
			if last.won then "won" else "lost",
			last.defensePower or 0,
			last.enemies or 0
		)
		lastWaveLabel.Visible = true
	end

	local plots = info.plots or {}
	-- The assignment, not a new local: refreshPicker reads this between pushes when the
	-- player switches crops, and a shadowing local would leave it stale.
	seeds = if type(info.seeds) == "table" then info.seeds else {}
	heldCrops = if type(info.harvested) == "table" then info.harvested else {}
	local heldParts: { string } = {}
	for _, cropId in Config.cropOrder do
		local count = heldCrops[cropId] or 0
		if count > 0 then
			table.insert(heldParts, string.format("%s %d", cropId, count))
		end
	end
	heldLabel.Text = if #heldParts == 0 then "Held: none" else "Held: " .. table.concat(heldParts, ", ")
	-- One shared number for the shared selector, so it is stated once on the picker
	-- line rather than repeated in every plot row.
	selectedSeeds = seeds[selectedCrop] or 0
	refreshPicker()
	for plotIndex, rowState in rows do
		local plot = plots[plotIndex]
		if type(plot) == "table" then
			if plot.cropId ~= nil then
				rowState.cropId = plot.cropId
			end
			-- 0.34 of a 360 px panel is ~122 px, and "2: pumpkin (44s, 0)" needs ~135 px,
			-- so every capture clipped it mid-word (": pumpkin (44s, 0"). The row now
			-- reads "2 pumpkin 44s". The held count moved to the seed line because it is
			-- one shared number for the selected crop, not a per-row quantity; repeating
			-- it in three rows was both wider and more confusing than stating it once.
			local short = if plot.cropId == nil
				then "empty"
				elseif plot.ready then "ready"
				else string.format("%ds", math.floor(plot.remaining or 0))
			rowState.label.Text = string.format("%d %s %s", plotIndex, tostring(plot.cropId or "-"), short)
		end
	end
end)
