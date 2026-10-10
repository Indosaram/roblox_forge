--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Options = require("./Options")
local CommandTransport = require("./CommandTransport")
export type Options = { controls: { Options.Control }, guiName: string? }
local M = {}
function M.start(options: Options): ScreenGui
	local player = Players.LocalPlayer
	local action = ReplicatedStorage:WaitForChild("ForgeAction") :: RemoteFunction
	local state = ReplicatedStorage:WaitForChild("ForgeState") :: RemoteEvent
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn = options.guiName or "ForgeStarter", false
	local panel = Instance.new("ScrollingFrame")
	panel.Name, panel.Size, panel.Position = "Snapshots", UDim2.fromOffset(440, 560), UDim2.fromOffset(16, 16)
	panel.AutomaticCanvasSize, panel.CanvasSize, panel.ScrollBarThickness = Enum.AutomaticSize.Y, UDim2.new(), 6
	panel.BackgroundColor3 = Color3.fromRGB(25, 28, 36)
	panel.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.Parent = panel
	local function text(name: string): TextLabel
		local label = Instance.new("TextLabel")
		label.Name, label.Size, label.AutomaticSize = name, UDim2.new(1, -12, 0, 28), Enum.AutomaticSize.Y
		label.BackgroundTransparency, label.TextColor3 = 1, Color3.new(1, 1, 1)
		label.TextSize, label.TextWrapped = 16, true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = panel
		return label
	end
	local status = text("ActionResult")
	status.Text = "Loading profile"
	local selected: string? = nil
	local roster: { { id: string, name: string } } = {}
	local selector = Instance.new("TextButton")
	selector.Name, selector.Size, selector.Text = "RosterSelection", UDim2.new(1, -12, 0, 36), "Select a player"
	selector.Parent = panel
	local function selectionLabel()
		local name = "Select a player"
		for _, entry in roster do
			if entry.id == selected then
				name = "Target: " .. entry.name .. " (" .. entry.id .. ")"
			end
		end
		selector.Text = name
	end
	selector.Activated:Connect(function()
		if #roster == 0 then
			selected = nil
			selectionLabel()
			return
		end
		local index = 0
		for i, entry in roster do
			if entry.id == selected then
				index = i
			end
		end
		selected = roster[index % #roster + 1].id
		selectionLabel()
	end)
	local durable: any = nil
	local function showResult(result: any, diagnostic: any?)
		status.Text = if result.ok then "Action accepted" else "Rejected: " .. tostring(result.reason)
		if diagnostic and diagnostic.notificationError then
			status.Text ..= " (notification: " .. tostring(diagnostic.notificationError) .. ")"
		end
	end
	local labels: { [string]: TextLabel } = {}
	for _, control in options.controls do
		local inFlight = false
		local pending: any = nil
		local function activate()
			if inFlight then
				return
			end
			local args = table.clone(control.args)
			if control.kind == "player-button" then
				if not selected then
					status.Text = "Select a roster player first"
					return
				end
				table.insert(args, 1, selected)
			end
			inFlight = true
			local isDurable = CommandTransport.durable(durable, control.action)
			if control.kind == "prompt" and not isDurable then
				inFlight = false
				return
			end
			local commandEpoch = if durable and durable.epochs
				then durable.epochs[control.action]
				else if durable then durable.sessionEpoch else nil
			if isDurable and pending == nil and commandEpoch == nil then
				inFlight = false
				status.Text = "Command epoch unavailable; refresh profile"
				return
			end
			if isDurable then
				pending = CommandTransport.request(pending, control.action, args, commandEpoch, function()
					return HttpService:GenerateGUID(false)
				end)
			end
			local ok, result, diagnostic = pcall(function()
				if isDurable then
					return action:InvokeServer("command", pending)
				end
				return action:InvokeServer(control.action, args)
			end)
			inFlight = false
			if ok then
				if isDurable then
					pending = CommandTransport.settle(pending, result)
				end
				showResult(result, diagnostic)
				if isDurable and result.reason == "REQUEST_EXPIRED" then
					local refreshed, handshake = pcall(function()
						return action:InvokeServer()
					end)
					if refreshed and handshake.ok then
						durable = handshake.durable
					end
					status.Text = "Request expired; epoch refreshed. Activate again to submit a new request."
				end
			else
				status.Text = "Transport failed: " .. tostring(result)
			end
		end
		if control.kind == "prompt" then
			ProximityPromptService.PromptTriggered:Connect(function(prompt, triggeringPlayer)
				if triggeringPlayer == player and prompt.Name == control.id then
					activate()
				end
			end)
		else
			local button = Instance.new("TextButton")
			button.Name, button.Text, button.Size = control.id, control.label, UDim2.new(1, -12, 0, 36)
			button.Parent = panel
			button.Activated:Connect(activate)
		end
	end
	-- Subscribe before requesting initial state. No timer/polling race.
	state.OnClientEvent:Connect(function(packet)
		if packet.durable then
			durable = packet.durable
		end
		if packet.result then
			showResult(packet.result)
		end
		if not packet.snapshots then
			return
		end
		roster = {}
		for _, entry in packet.roster do
			if entry.id ~= tostring(player.UserId) then
				table.insert(roster, entry)
			end
		end
		local present = false
		for _, entry in roster do
			if entry.id == selected then
				present = true
			end
		end
		if not present then
			selected = if roster[1] then roster[1].id else nil
		end
		selectionLabel()
		local ids = {}
		for id in packet.snapshots do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local label = labels[id]
			if not label then
				label = text(id .. ":snapshot")
				labels[id] = label
			end
			label.Text = id .. "\n" .. HttpService:JSONEncode(packet.snapshots[id])
		end
		if status.Text == "Loading profile" then
			status.Text = "Ready"
		end
	end)
	gui.Parent = player:WaitForChild("PlayerGui")
	local ok, result = pcall(function()
		return action:InvokeServer()
	end)
	if not ok then
		status.Text = "Initial state failed: " .. tostring(result)
	elseif not result.ok then
		status.Text = tostring(result.reason)
	else
		durable = result.durable
	end
	return gui
end
return M
