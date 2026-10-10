--!strict
local Transport = require("../../../core/infra/genre/CommandTransport")
local M = {}

function M.start(gui: ScreenGui)
	local player = game:GetService("Players").LocalPlayer
	local storage = game:GetService("ReplicatedStorage")
	local http = game:GetService("HttpService")
	local action = storage:WaitForChild("ForgeAction") :: RemoteFunction
	local state = storage:WaitForChild("ForgeState") :: RemoteEvent
	local panel = gui:WaitForChild("Snapshots")
	local frame = Instance.new("ScrollingFrame")
	frame.Name, frame.Size = "ForgeCrafting", UDim2.new(1, -12, 0, 220)
	frame.AutomaticCanvasSize, frame.CanvasSize, frame.ScrollBarThickness = Enum.AutomaticSize.Y, UDim2.new(), 6
	frame.BackgroundColor3 = Color3.fromRGB(25, 28, 36)
	local layout = Instance.new("UIListLayout")
	layout.Padding, layout.Parent = UDim.new(0, 8), frame
	local status = Instance.new("TextLabel")
	status.Name, status.Size = "CraftResult", UDim2.new(1, -12, 0, 44)
	status.BackgroundTransparency, status.TextColor3 = 1, Color3.new(1, 1, 1)
	status.TextSize, status.TextWrapped = 16, true
	status.Text, status.Parent = "Reserve a recipe to create a job", frame
	frame.Parent = panel
	local evidence: BindableEvent? = nil
	if not player:FindFirstChild("ForgeCraftResult") then
		local event = Instance.new("BindableEvent")
		event.Name, event.Parent = "ForgeCraftResult", player
		evidence = event
	end
	local disposed, refreshing = false, false
	local durable: any = nil
	local jobs: { [string]: any } = {}
	local pending: { [string]: any } = {}
	local busy: { [string]: boolean } = {}
	local rows: { [string]: { button: TextButton, connection: RBXScriptConnection } } = {}
	local connections: { RBXScriptConnection } = {}
	local function refresh()
		if disposed or refreshing then
			return
		end
		refreshing = true
		local ok, result = pcall(function()
			return action:InvokeServer()
		end)
		refreshing = false
		if not disposed then
			if ok and result.ok then
				durable = result.durable
			else
				status.Text = "Profile refresh failed; activate again to retry"
			end
		end
	end
	local render: () -> ()
	local function activate(id: string, verb: string)
		if disposed or refreshing or busy[id] then
			return
		end
		local key = id .. ":" .. verb
		local request = pending[key]
		if not request then
			local job = jobs[id]
			if not job or job.state == "Committed" or job.state == "Cancelled" then
				return
			end
			local name = "survival-coop:craft-" .. verb
			local epoch = if durable and durable.epochs
				then durable.epochs[name]
				else if durable then durable.sessionEpoch else nil
			if not Transport.durable(durable, name) or type(epoch) ~= "number" then
				refresh()
				return
			end
			request = Transport.request(nil, name, { id }, epoch, function()
				return http:GenerateGUID(false)
			end)
			table.freeze(request.args)
			table.freeze(request)
			pending[key] = request
		end
		busy[id] = true
		local ok, result = pcall(function()
			return action:InvokeServer("command", request)
		end)
		busy[id] = nil
		if disposed then
			return
		end
		if ok then
			pending[key] = Transport.settle(request, result)
			if result.reason == "REQUEST_EXPIRED" then
				durable = nil
				refresh()
			end
			status.Text = if result.stateVersion ~= nil
				then (if result.ok then "Craft command confirmed" else "Rejected: " .. tostring(result.reason))
				else "Awaiting confirmation: " .. tostring(result.reason)
			if evidence then
				evidence:Fire({ jobId = id, requestId = request.requestId, action = request.action, result = result })
			end
		else
			status.Text = "Transport failed; retry the same action"
		end
		render()
	end
	render = function()
		local wanted: { [string]: { id: string, verb: string, label: string } } = {}
		for id, job in jobs do
			if job.state ~= "Committed" and job.state ~= "Cancelled" then
				local verb = if job.state == "Reserved" then "start" else "complete"
				for _, operation in { verb, "cancel" } do
					wanted[id .. ":" .. operation] =
						{ id = id, verb = operation, label = job.recipeId .. " - " .. job.state .. " - " .. operation }
				end
			end
		end
		-- A snapshot can advance before the ACK arrives. Keep the exact retry button.
		for key, request in pending do
			wanted[key] = {
				id = request.args[1],
				verb = string.sub(request.action, 21),
				label = "Retry " .. request.action .. " " .. request.args[1],
			}
		end
		for key, row in rows do
			if not wanted[key] then
				row.connection:Disconnect()
				row.button:Destroy()
				rows[key] = nil
			end
		end
		local keys = {}
		for key in wanted do
			table.insert(keys, key)
		end
		table.sort(keys)
		for _, key in keys do
			local entry = wanted[key]
			local row = rows[key]
			if not row then
				local button = Instance.new("TextButton")
				button.Name, button.Size = key, UDim2.new(1, -12, 0, 44)
				button.TextWrapped, button.TextSize = true, 16
				button.Parent = frame
				row = {
					button = button,
					connection = button.Activated:Connect(function()
						activate(entry.id, entry.verb)
					end),
				}
				rows[key] = row
			end
			row.button.Text = entry.label
		end
	end
	local function destroy()
		if disposed then
			return
		end
		disposed = true
		for _, connection in connections do
			connection:Disconnect()
		end
		for _, row in rows do
			row.connection:Disconnect()
		end
		frame:Destroy()
		if evidence then
			evidence:Destroy()
		end
		table.clear(rows)
		table.clear(pending)
	end
	table.insert(connections, gui.Destroying:Connect(destroy))
	table.insert(
		connections,
		state.OnClientEvent:Connect(function(packet)
			if packet.durable then
				durable = packet.durable
			end
			local snapshot = if packet.snapshots then packet.snapshots["survival-coop"] else nil
			if not snapshot then
				return
			end
			jobs = {}
			local workshop = snapshot.workshop
			if workshop and workshop.actorId == tostring(player.UserId) then
				for id, entry in workshop.entries do
					jobs[id] = entry.job
				end
			end
			render()
		end)
	)
	refresh()
	return { destroy = destroy }
end
return M
