--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = ReplicatedStorage:WaitForChild("Forge")
local Config = require(Forge.games["grow-and-defend-garden"].src.shared.Config)

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Plant = Remotes:WaitForChild("Plant") :: RemoteFunction
local Harvest = Remotes:WaitForChild("Harvest") :: RemoteFunction
local Sell = Remotes:WaitForChild("Sell") :: RemoteFunction
local StateChanged = Remotes:WaitForChild("StateChanged") :: RemoteEvent

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
	Size = UDim2.fromOffset(340, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Position = UDim2.new(1, -20, 0, 20),
	AnchorPoint = Vector2.new(1, 0),
	BackgroundColor3 = Color3.fromRGB(28, 38, 28),
	BorderSizePixel = 0,
}, screenGui)
create("UIListLayout", { Padding = UDim.new(0, 6) }, frame)

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
local lastWaveLabel = makeLabel(frame, "LastWave", UDim2.new(1, 0, 0, 20), Color3.fromRGB(230, 230, 230), 14)

type Row = { label: TextLabel, cursor: number, cropId: string? }

local function makeButton(row: Instance, name: string, offset: number, color: Color3, onClick: () -> ())
	create("TextButton", {
		Size = UDim2.fromScale(0.19, 1),
		Position = UDim2.fromScale(0.43 + offset * 0.19, 0),
		Text = name,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundColor3 = color,
	}, row).MouseButton1Click:Connect(onClick)
end

local rows: { Row } = {}
for index = 1, Config.plotCount do
	local plotIndex = index
	local row = create("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 }, frame)
	local label = makeLabel(row, "Status", UDim2.fromScale(0.42, 1), Color3.fromRGB(240, 240, 240), 13)
	label.Text = string.format("Plot %d: empty", plotIndex)

	local rowState: Row = { label = label, cursor = 0, cropId = nil }
	rows[plotIndex] = rowState

	makeButton(row, "Plant", 0, Color3.fromRGB(60, 130, 70), function()
		rowState.cursor += 1
		Plant:InvokeServer(plotIndex, Config.cropOrder[(rowState.cursor - 1) % #Config.cropOrder + 1])
	end)
	makeButton(row, "Harvest", 1, Color3.fromRGB(150, 120, 50), function()
		Harvest:InvokeServer(plotIndex)
	end)
	makeButton(row, "Sell", 2, Color3.fromRGB(80, 90, 150), function()
		if rowState.cropId ~= nil then
			Sell:InvokeServer(rowState.cropId)
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
	else
		lastWaveLabel.Text = string.format(
			"Last wave %d: %s (defense %d vs %d)",
			last.index or 0,
			if last.won then "won" else "lost",
			last.defensePower or 0,
			last.enemies or 0
		)
	end

	local plots = info.plots or {}
	for plotIndex, rowState in rows do
		local plot = plots[plotIndex]
		if type(plot) == "table" then
			if plot.cropId ~= nil then
				rowState.cropId = plot.cropId
			end
			local status = if plot.cropId == nil
				then "empty"
				elseif plot.ready then "ready"
				else string.format("%ds", math.floor(plot.remaining or 0))
			rowState.label.Text = string.format("Plot %d: %s (%s)", plotIndex, tostring(plot.cropId or "-"), status)
		end
	end
end)
