--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Transport = require("../../../../core/infra/genre/CommandTransport")
local function signal(): any
	local callbacks: { { any } } = {}
	return {
		Connect = function(_, callback)
			local connection = { Connected = true }
			connection.Disconnect = function()
				connection.Connected = false
			end
			table.insert(callbacks, { connection, callback })
			return connection
		end,
		Fire = function(_, ...)
			for _, entry in table.clone(callbacks) do
				if entry[1].Connected then
					entry[2](...)
				end
			end
		end,
		count = function()
			local count = 0
			for _, entry in callbacks do
				if entry[1].Connected then
					count += 1
				end
			end
			return count
		end,
	}
end
local objects: { any } = {}
local function instance(class): any
	local object: any = { ClassName = class, Activated = signal(), Destroying = signal(), Event = signal() }
	function object:FindFirstChild(name)
		for _, child in objects do
			if child.Parent == self and child.Name == name then
				return child
			end
		end
		return nil
	end
	object.WaitForChild = object.FindFirstChild
	function object:Destroy()
		self.Destroying:Fire()
		self.destroyed, self.Parent = true, nil
	end
	function object:Fire(...)
		self.Event:Fire(...)
	end
	table.insert(objects, object)
	return object
end
local gui, panel, player = instance("ScreenGui"), instance("ScrollingFrame"), instance("Player")
panel.Name, panel.Parent, player.UserId = "Snapshots", gui, 1
local reserve = instance("TextButton")
reserve.Name, reserve.Parent = "reserve", panel
local state = signal()
local broadcasts = 0
state:Connect(function()
	broadcasts += 1
end)
local jobs: { [string]: any } = {}
local epoch, ids, handshakes = 2, 0, 0
local calls = {}
local behavior = "ack"
local function policy()
	return {
		actions = { "survival-coop:craft-start", "survival-coop:craft-complete", "survival-coop:craft-cancel" },
		sessionEpoch = epoch,
	}
end
local function push()
	state:Fire({
		durable = policy(),
		snapshots = { ["survival-coop"] = { workshop = { actorId = "1", entries = jobs } } },
	})
end
reserve.Activated:Connect(function()
	jobs["job-1"] = { job = { id = "job-1", recipeId = "cord", state = "Reserved" } }
	push()
end)
local remote = {}
function remote:InvokeServer(...): any
	local args = table.pack(...)
	if args.n == 0 then
		assert(state.count() == 2, "subscribe before handshake preserves core listener")
		handshakes += 1
		push()
		return { ok = true, durable = policy() }
	end
	assert(args.n == 2 and args[1] == "command", "durable ingress")
	local request = args[2]
	assert(table.isfrozen(request) and table.isfrozen(request.args) and #request.args == 1, "immutable exact job args")
	table.insert(calls, request)
	if behavior == "lost" then
		jobs[request.args[1]].job.state = "Running"
		push()
		error("lost ACK")
	elseif behavior == "pending" then
		return { ok = false, reason = "COMMAND_PENDING" }
	elseif behavior == "early" then
		return { ok = false, reason = "NOT_READY", stateVersion = #calls }
	elseif behavior == "expired" then
		epoch = 5
		return { ok = false, reason = "REQUEST_EXPIRED" }
	end
	local verb = string.sub(request.action, 21)
	jobs[request.args[1]].job.state = if verb == "start"
		then "Running"
		elseif verb == "complete" then "Committed"
		else "Cancelled"
	push()
	return { ok = true, stateVersion = #calls }
end
local services = {
	Players = { LocalPlayer = player },
	HttpService = {
		GenerateGUID = function()
			ids += 1
			return "craft-guid-" .. ids
		end,
	},
	ReplicatedStorage = {
		WaitForChild = function(_, name)
			return if name == "ForgeAction" then remote else { OnClientEvent = state }
		end,
	},
}
local function tuple(...)
	return { ... }
end
local module = luau.load(fs.readFile("genres/survival-coop/module/CraftingClient.luau"), {
	environment = {
		game = {
			GetService = function(_, name)
				return services[name]
			end,
		},
		Instance = { new = instance },
		Enum = { AutomaticSize = { Y = "Y" } },
		UDim2 = { new = tuple },
		UDim = { new = tuple },
		Color3 = { new = tuple, fromRGB = tuple },
		require = function(path)
			assert(path == "../../../core/infra/genre/CommandTransport", "real transport")
			return Transport
		end,
	},
})()
local resource = module.start(gui)
local frame = assert(panel:FindFirstChild("ForgeCrafting"), "bounded frame")
assert(frame.Size[4] == 220 and frame.AutomaticCanvasSize == "Y", "bounded scrolling rows")
local function button(id: string, verb: string)
	return assert(frame:FindFirstChild(id .. ":" .. verb), "actual button exists")
end
assert(handshakes == 1 and broadcasts == 1 and #calls == 0, "initial handshake no command")
local evidence: { any } = {}
player:FindFirstChild("ForgeCraftResult").Event:Connect(function(packet)
	table.insert(evidence, packet)
end)
reserve.Activated:Fire()
local start = button("job-1", "start")
assert(start.Size[4] == 44, "touch target height")
behavior = "lost"
start.Activated:Fire()
assert(calls[1].action == "survival-coop:craft-start" and calls[1].args[1] == "job-1", "snapshot job ID starts")
assert(not start.destroyed and #evidence == 0, "lost ACK preserves retry despite advanced snapshot")
behavior = "pending"
start.Activated:Fire()
assert(calls[2] == calls[1] and ids == 1, "same ID pending retry")
assert(
	evidence[1].requestId == calls[1].requestId and evidence[1].result.reason == "COMMAND_PENDING",
	"pending evidence"
)
behavior = "ack"
start.Activated:Fire()
assert(calls[3] == calls[1] and start.destroyed, "ACK retires start retry")
local complete = button("job-1", "complete")
behavior = "early"
complete.Activated:Fire()
assert(jobs["job-1"].job.state == "Running" and not complete.destroyed, "no local ready or completion simulation")
behavior = "ack"
complete.Activated:Fire()
assert(
	calls[5].action == "survival-coop:craft-complete" and calls[5].requestId ~= calls[4].requestId,
	"terminal refusal permits fresh attempt"
)
local completedState: string = jobs["job-1"].job.state
assert(complete.destroyed and completedState == "Committed", "server completion removes actions")
reserve.Activated:Fire()
local cancel = button("job-1", "cancel")
behavior = "expired"
cancel.Activated:Fire()
assert(handshakes == 2, "expired request refreshes")
behavior = "ack"
cancel.Activated:Fire()
assert(calls[7].action == "survival-coop:craft-cancel" and calls[7].sessionEpoch == 5, "cancel uses refreshed epoch")
assert(cancel.destroyed and evidence[#evidence].jobId == "job-1", "cancel terminal evidence")
reserve.Activated:Fire()
local stale = button("job-1", "start")
gui.Destroying:Fire()
resource.destroy()
stale.Activated:Fire()
assert(#calls == 7 and state.count() == 1 and stale.Activated.count() == 0, "owned connections disposed")
assert(frame.destroyed and not reserve.destroyed and panel.Parent == gui, "core controls preserved")
assert(not player:FindFirstChild("ForgeCraftResult"), "owned evidence removed")
print(
	"PASS actual CraftingClient reserve snapshot -> start -> complete/cancel buttons, immutable retries, epochs, cleanup"
)
