--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Transport = require("../../../../core/infra/genre/CommandTransport")
local function event(): any
	local listeners: { { connection: any, callback: (...any) -> () } } = {}
	local signal = {}
	function signal:Connect(callback)
		local connection = { Connected = true }
		function connection.Disconnect()
			connection.Connected = false
		end
		table.insert(listeners, { connection = connection, callback = callback })
		return connection
	end
	function signal:Fire(...)
		for _, listener in table.clone(listeners) do
			if listener.connection.Connected then
				listener.callback(...)
			end
		end
	end
	function signal:count()
		local count = 0
		for _, listener in listeners do
			if listener.connection.Connected then
				count += 1
			end
		end
		return count
	end
	return signal
end
local objects = {}
local function instance(kind: string): any
	local object: any = {
		ClassName = kind,
		Anchored = true,
		Size = { Y = 4 },
		attrs = {},
		Triggered = event(),
		Activated = event(),
		Event = event(),
		AttributeChanged = event(),
		AncestryChanged = event(),
	}
	function object:IsA(class)
		return self.ClassName == class or (self.ClassName == "Part" and class == "BasePart")
	end
	function object:IsDescendantOf(parent)
		return self.Parent == parent
	end
	function object:GetAttribute(key)
		return self.attrs[key]
	end
	function object:SetAttribute(key, value)
		self.attrs[key] = value
		self.AttributeChanged:Fire(key)
	end
	function object:Destroy()
		self.destroyed = true
		self.Parent = nil
	end
	function object:Fire(...)
		self.Event:Fire(...)
	end
	table.insert(objects, object)
	return object
end
local world = instance("Workspace")
function world:GetServerTimeNow()
	return 0
end
local player = { UserId = 1 }
function player:FindFirstChild(name)
	for _, object in objects do
		if object.Parent == self and object.Name == name then
			return object
		end
	end
	return nil
end
function player:WaitForChild(name)
	return player:FindFirstChild(name)
end
local playerGui = instance("PlayerGui")
playerGui.Name, playerGui.Parent = "PlayerGui", player
local added, removed, state = event(), event(), event()
local tagged = {}
local tags = {}
function tags:GetTagged(_tag)
	local result = {}
	for part in tagged do
		table.insert(result, part)
	end
	return result
end
function tags:HasTag(part, _tag)
	return tagged[part] == true
end
function tags:GetInstanceAddedSignal(_tag)
	return added
end
function tags:GetInstanceRemovedSignal(_tag)
	return removed
end
local function node(id: string): any
	local part = instance("Part")
	part.Parent = world
	part.attrs = {
		ForgeNodeId = id,
		ForgeNodeKind = "tree",
		ForgeNodeVersion = 7,
		ForgeNodeWorldRevision = "world-1",
		ForgeNodeCount = 2,
		ForgeNodeDepleted = false,
	}
	tagged[part] = true
	return part
end
local tree = node("tree-1")
local authored = instance("ProximityPrompt")
authored.Name, authored.Parent = "ForgeGather", tree
local calls, ids, handshakes = {}, 0, 0
local epoch = 4
local behavior = "lost"
local function policy()
	return { actions = { "survival-coop:gather" }, epochs = { ["survival-coop:gather"] = epoch }, sessionEpoch = 99 }
end
local remote = {}
function remote:InvokeServer(...): (any, any?)
	local args = table.pack(...)
	if args.n == 0 then
		assert(state:count() == 2, "both core subscriber and gathering subscribed before handshake")
		handshakes += 1
		state:Fire({ durable = policy(), snapshots = {} })
		return { ok = true, durable = policy() }
	end
	assert(args.n == 2 and args[1] == "command", "exact durable remote ingress")
	local request = args[2]
	assert(request.action == "survival-coop:gather" and #request.args == 2, "exact gather action arguments")
	assert(table.isfrozen(request) and table.isfrozen(request.args), "immutable pending payload")
	table.insert(calls, request)
	if behavior == "lost" then
		error("lost ACK")
	elseif behavior == "pending" then
		return { ok = false, reason = "COMMAND_PENDING" }
	elseif behavior == "expired" then
		epoch = 8
		return { ok = false, reason = "REQUEST_EXPIRED" }
	elseif behavior == "stale" then
		return { ok = false, reason = "STALE_VERSION", data = { status = "rejected" } }
	elseif behavior == "busy" then
		return { ok = false, reason = "SOURCE_BUSY", data = { status = "recovering" } }
	elseif behavior == "reentrant" then
		for _, object in objects do
			if object.Parent == tree and object ~= authored then
				object.Triggered:Fire(player)
			end
		end
	end
	return { ok = true, data = { status = "confirmed" } }, { confirmed = true }
end
local broadcasts = 0
state:Connect(function()
	broadcasts += 1
end)
local services = {
	Workspace = world,
	CollectionService = tags,
	Players = { LocalPlayer = player },
	ProximityPromptService = { PromptShown = event(), PromptHidden = event() },
	RunService = { RenderStepped = event() },
	UserInputService = { TouchEnabled = false },
	HttpService = {
		GenerateGUID = function(_, braces)
			assert(braces == false, "GUID format")
			ids += 1
			return "guid-" .. ids
		end,
	},
	ReplicatedStorage = {
		WaitForChild = function(_, name)
			return if name == "ForgeAction" then remote else { OnClientEvent = state }
		end,
	},
}
local client = luau.load(fs.readFile("genres/survival-coop/module/GatheringClient.luau"), {
	environment = {
		game = {
			GetService = function(_, name)
				return assert(services[name], "known service")
			end,
		},
		Instance = { new = instance },
		Enum = { KeyCode = { E = "E" }, ScreenInsets = { CoreUISafeInsets = "CoreUISafeInsets" } },
		UDim2 = {
			fromOffset = function(x, y)
				return { X = x, Y = y }
			end,
			new = function(xScale, xOffset, yScale, yOffset)
				return { X = { Scale = xScale, Offset = xOffset }, Y = { Scale = yScale, Offset = yOffset } }
			end,
		},
		Vector3 = {
			new = function(x, y, z)
				return { X = x, Y = y, Z = z }
			end,
		},
		require = function(path)
			assert(path == "../../../core/infra/genre/CommandTransport", "transport dependency")
			return Transport
		end,
	},
})()
local results: { any } = {}
local resource = client.start({
	onResult = function(result, diagnostic)
		table.insert(results, { result = result, diagnostic = diagnostic })
	end,
})
local function prompt(part): any
	for _, object in objects do
		if
			object.ClassName == "ProximityPrompt"
			and object.Parent
			and object.Parent.Parent == part
			and object ~= authored
		then
			return object
		end
	end
	error("missing owned prompt")
end
local input = prompt(tree)
local resultEvent = assert(player:FindFirstChild("ForgeGatherResult"))
local evidence: { any } = {}
resultEvent.Event:Connect(function(packet)
	table.insert(evidence, packet)
end)
assert(
	input.Name == "ForgeGather" and input.KeyboardKeyCode == "E" and input.ClickablePrompt,
	"keyboard and touch input"
)
assert(input.MaxActivationDistance == 8 and input.RequiresLineOfSight and input.Enabled, "prompt range and sight")
assert(
	input.Parent.ClassName == "Attachment" and input.Parent.Position.Y == 3,
	"prompt anchored above resource geometry"
)
local ownedAnchor = input.Parent
assert(handshakes == 1 and broadcasts == 1 and #calls == 0, "initial handshake only")
input.Triggered:Fire({ UserId = 2 })
assert(#calls == 0, "other player ignored")
input.Triggered:Fire(player)
assert(#calls == 1 and ids == 1 and calls[1].sessionEpoch == 4, "initial epoch")
assert(calls[1].args[1] == "tree-1" and calls[1].args[2] == 7, "node ID and confirmed version")
assert(results[1].result.reason == "TRANSPORT_FAILED", "no fake success on lost ACK")
assert(#evidence == 0, "transport exception is not a remote result")
tree:SetAttribute("ForgeNodeVersion", 10)
epoch = 6
state:Fire({ durable = policy() })
behavior = "pending"
input.Triggered:Fire(player)
assert(calls[2] == calls[1] and calls[2].args[2] == 7 and ids == 1, "same pending request")
assert(evidence[1].nodeId == "tree-1" and evidence[1].requestId == calls[1].requestId, "event identity")
assert(evidence[1].result.reason == "COMMAND_PENDING", "pending event")
behavior = "ack"
input.Triggered:Fire(player)
assert(calls[3] == calls[1] and ids == 1, "pending response keeps request until ACK")
assert(results[3].result.data.status == "confirmed" and results[3].diagnostic.confirmed, "confirmed callback")
assert(
	evidence[2].requestId == calls[1].requestId and evidence[2].result.data.status == "confirmed",
	"terminal event identity"
)
behavior = "reentrant"
input.Triggered:Fire(player)
assert(
	#calls == 4 and ids == 2 and calls[4].args[2] == 10 and calls[4].sessionEpoch == 6,
	"new epoch after ACK and no concurrent duplicate"
)
tree:SetAttribute("ForgeNodeCount", 0)
tree:SetAttribute("ForgeNodeDepleted", true)
assert(not input.Enabled, "depleted disabled")
input.Triggered:Fire(player)
assert(#calls == 4 and ids == 2, "depleted does not allocate or dispatch")
tree:SetAttribute("ForgeNodeVersion", 11)
tree:SetAttribute("ForgeNodeCount", 3)
assert(not input.Enabled, "partial respawn stays disabled")
tree:SetAttribute("ForgeNodeDepleted", false)
assert(input.Enabled, "confirmed respawn enables input")
behavior = "expired"
input.Triggered:Fire(player)
assert(#calls == 5 and handshakes == 2, "expiration refreshes before new input")
behavior = "ack"
input.Triggered:Fire(player)
assert(
	#calls == 6 and calls[6].sessionEpoch == 8 and calls[6].requestId ~= calls[5].requestId,
	"expiration new identity"
)
local bad = node("bad")
bad.attrs.ForgeNodeVersion = "forged"
added:Fire(bad)
local badInput = prompt(bad)
assert(not badInput.Enabled, "malformed disabled")
badInput.Triggered:Fire(player)
assert(#calls == 6 and ids == 4, "malformed node ignored")
local late = node("late")
added:Fire(late)
added:Fire(late)
local lateInput = prompt(late)
assert(lateInput.Enabled and late.AttributeChanged:count() == 1, "dynamic node registered once")
behavior = "lost"
lateInput.Triggered:Fire(player)
local latePending = calls[7]
tagged[late] = nil
removed:Fire(late)
assert(
	lateInput.destroyed and lateInput.Triggered:count() == 0 and late.AttributeChanged:count() == 0,
	"removed node disconnected"
)
lateInput.Triggered:Fire(player)
assert(#calls == 7, "removed input ignored")
tagged[late] = true
added:Fire(late)
behavior = "ack"
prompt(late).Triggered:Fire(player)
assert(calls[8] == latePending, "retagging cannot replace unresolved request identity")
behavior = "lost"
input.Triggered:Fire(player)
local finalCharge = calls[9]
tree:SetAttribute("ForgeNodeVersion", 12)
tree:SetAttribute("ForgeNodeCount", 0)
tree:SetAttribute("ForgeNodeDepleted", true)
assert(input.Enabled, "depleted final-charge lost ACK still offers pending retry")
behavior = "ack"
input.Triggered:Fire(player)
assert(calls[10] == finalCharge and calls[10].args[2] == 11, "final-charge retry preserves original payload")
assert(not input.Enabled, "depleted prompt disables after ACK settlement")
input.Triggered:Fire(player)
assert(#calls == 10, "depleted settled node cannot allocate a new request")
-- A refusal that decided against the frozen payload settles the request, so the
-- next activation re-reads the published version under a fresh identity and
-- reaches the remote as a new command; the source keeps no pending outcome.
local stale = node("stale-1")
stale.attrs.ForgeNodeVersion = 20
added:Fire(stale)
local staleInput = prompt(stale)
assert(staleInput.Enabled, "fresh node offers input")
behavior = "stale"
staleInput.Triggered:Fire(player)
assert(#calls == 11 and ids == 7 and calls[11].args[2] == 20, "stale probe sends the confirmed version")
assert(evidence[#evidence].result.reason == "STALE_VERSION", "stale refusal reported")
stale:SetAttribute("ForgeNodeVersion", 21)
behavior = "ack"
staleInput.Triggered:Fire(player)
assert(
	#calls == 12 and ids == 8 and calls[12].args[2] == 21 and calls[12].requestId ~= calls[11].requestId,
	"stale refusal settles and the next activation re-reads the confirmed version"
)
-- Every other refusal keeps the frozen identity for the source's dedupe.
behavior = "busy"
staleInput.Triggered:Fire(player)
assert(#calls == 13 and ids == 9 and calls[13].args[2] == 21, "unresolved refusal keeps the current version")
staleInput.Triggered:Fire(player)
assert(#calls == 14 and calls[14] == calls[13], "unresolved refusal replays the identical request")
resource.destroy()
resource.destroy()
assert(
	input.destroyed and badInput.destroyed and not authored.destroyed and authored.Parent == tree,
	"authored prompt preserved"
)
assert(
	input.Triggered:count() == 0 and tree.AttributeChanged:count() == 0 and tree.AncestryChanged:count() == 0,
	"owned connections disconnected"
)
assert(added:count() == 0 and removed:count() == 0 and state:count() == 1, "only owned listeners disconnected")
input.Triggered:Fire(player)
added:Fire(node("after-dispose"))
assert(#calls == 14, "disposed input ignored")
assert(resultEvent.destroyed, "owned result event disposed")
assert(ownedAnchor.destroyed, "owned prompt anchor disposed")
local userEvent = instance("BindableEvent")
userEvent.Name, userEvent.Parent = "ForgeGatherResult", player
local second = client.start()
second.destroy()
assert(not userEvent.destroyed and player:FindFirstChild("ForgeGatherResult") == userEvent, "user event preserved")
print("PASS actual GatheringClient prompt input, immutable retries, ACK, epochs, depletion, respawn, lifecycle")
