--!strict
local CommandTransport = require("../../../core/infra/genre/CommandTransport")
local M = {}
-- `locale` picks the action label (Korean on a "ko" prefix); `names` maps a node kind or catalog id
-- to its display name, so prompts never show a raw id. Both are optional.
export type Options = { onResult: ((any, any?) -> ())?, locale: string?, names: { [string]: string }? }
local TAG = "ForgeSurvivalNode"
local ACTION = "survival-coop:gather"

local function integer(value: any): boolean
	return type(value) == "number" and value >= 0 and value <= 2 ^ 53 - 2 and value % 1 == 0
end

--- Gather action label for a locale (specced).
function M.actionText(locale: string?): string
	return if locale and string.sub(locale, 1, 2) == "ko" then "채집하기" else "Gather"
end

function M.start(options: Options?)
	local actionText = M.actionText(options and options.locale)
	local names: { [string]: string } = options and options.names or {}
	local tags = game:GetService("CollectionService")
	local storage = game:GetService("ReplicatedStorage")
	local http = game:GetService("HttpService")
	local player = game:GetService("Players").LocalPlayer
	local world = game:GetService("Workspace")
	local action = storage:WaitForChild("ForgeAction") :: RemoteFunction
	local state = storage:WaitForChild("ForgeState") :: RemoteEvent
	local resultEvent: BindableEvent? = nil
	local requestEvent = Instance.new("BindableEvent")
	requestEvent.Name, requestEvent.Parent = "ForgeGatherRequested", player
	if not player:FindFirstChild("ForgeGatherResult") then
		local owned = Instance.new("BindableEvent")
		owned.Name, owned.Parent = "ForgeGatherResult", player
		resultEvent = owned
	end
	local durable: any = nil
	local disposed = false
	local refreshing = false
	local pending: { [string]: any } = {}
	local busy: { [string]: boolean } = {}
	local connections: { RBXScriptConnection } = {}
	local touchGui = Instance.new("ScreenGui")
	touchGui.Name, touchGui.ResetOnSpawn = "ForgeGatherTouch", false
	touchGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	local touch = Instance.new("TextButton")
	touch.Name, touch.Text, touch.Visible = "Gather", actionText, false
	touch.Size, touch.Position = UDim2.fromOffset(132, 48), UDim2.new(0.5, -66, 1, -112)
	touch.BackgroundColor3 = Color3.fromRGB(54, 108, 82)
	touch.BorderSizePixel = 0
	touch.Font = Enum.Font.GothamBold
	touch.TextSize = 15
	touch.TextColor3 = Color3.fromRGB(240, 246, 240)
	pcall(function()
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 10)
		c.Parent = touch
		local s = Instance.new("UIStroke")
		s.Color = Color3.fromRGB(142, 196, 162)
		s.Thickness = 1.5
		s.Parent = touch
	end)
	touch.Parent = touchGui
	touchGui.Parent = player:WaitForChild("PlayerGui")
	local shown: { [ProximityPrompt]: BasePart } = {}
	local selected: BasePart? = nil
	local nodes: { [BasePart]: { prompt: ProximityPrompt, anchor: Attachment, connections: { RBXScriptConnection } } } =
		{}
	local function report(result: any, diagnostic: any?)
		if not disposed and options and options.onResult then
			options.onResult(result, diagnostic)
		end
	end
	local function registered(part: BasePart): (string?, string?)
		local id = part:GetAttribute("ForgeNodeId")
		local kind = part:GetAttribute("ForgeNodeKind")
		local revision = part:GetAttribute("ForgeNodeWorldRevision")
		if
			not tags:HasTag(part, TAG)
			or not part:IsDescendantOf(world)
			or not part.Anchored
			or type(id) ~= "string"
			or #id == 0
			or #id > 64
			or type(kind) ~= "string"
			or #kind == 0
			or type(revision) ~= "string"
			or #revision == 0
			or #revision > 128
		then
			return nil, nil
		end
		return id, kind
	end
	local function harvestable(part: BasePart): boolean
		local count = part:GetAttribute("ForgeNodeCount")
		return integer(part:GetAttribute("ForgeNodeVersion"))
			and integer(count)
			and count ~= 0
			and part:GetAttribute("ForgeNodeDepleted") == false
	end
	local function update(part: BasePart)
		local entry = nodes[part]
		if entry then
			local id, kind = registered(part)
			entry.prompt.Enabled = not disposed and id ~= nil and (pending[id] ~= nil or harvestable(part))
			if kind then
				entry.prompt.ObjectText = names[kind] or kind
			end
		end
	end
	local function refresh()
		if refreshing or disposed then
			return
		end
		refreshing = true
		local ok, result = pcall(function()
			return action:InvokeServer()
		end)
		refreshing = false
		if not disposed and ok and type(result) == "table" and result.ok then
			durable = result.durable
		elseif not disposed then
			report({ ok = false, reason = "HANDSHAKE_FAILED" }, result)
		end
	end
	local function activate(part: BasePart, triggeringPlayer: Player, inputSource: string?)
		if disposed or refreshing or triggeringPlayer ~= player or not nodes[part] then
			return
		end
		local id = registered(part)
		if not id or busy[id] then
			return
		end
		if pending[id] == nil then
			if not harvestable(part) then
				return
			end
			local version = part:GetAttribute("ForgeNodeVersion")
			local epoch = if durable and durable.epochs
				then durable.epochs[ACTION]
				else if durable then durable.sessionEpoch else nil
			if not CommandTransport.durable(durable, ACTION) or not integer(epoch) then
				refresh()
				return -- A refreshed epoch is used only by the next user activation.
			end
			pending[id] = CommandTransport.request(nil, ACTION, { id, version }, epoch, function()
				return http:GenerateGUID(false)
			end)
			table.freeze(pending[id].args)
			table.freeze(pending[id])
		end
		busy[id] = true
		local request = pending[id]
		local ok, result, diagnostic = pcall(function()
			requestEvent:Fire(table.freeze({
				requestId = request.requestId,
				nodeId = request.args[1],
				nodeVersion = request.args[2],
				actorId = tostring(player.UserId),
				serverTime = world:GetServerTimeNow(),
				inputSource = inputSource or "prompt",
			}))
			return action:InvokeServer("command", request)
		end)
		busy[id] = nil
		if disposed then
			return
		end
		if ok then
			pending[id] = CommandTransport.settle(pending[id], result)
			local confirmed = type(result) == "table"
				and result.ok == true
				and type(result.data) == "table"
				and result.data.status == "confirmed"
			local refused = type(result) == "table" and result.ok == false and result.reason == "STALE_VERSION"
			if confirmed or refused then
				-- A confirmed outcome and a refusal that decided against the frozen payload
				-- both end this request: the source persisted a grant for the former and
				-- writes no grant and no outcome for the latter, so neither leaves a pending
				-- settlement to honour. Settling here lets the next activation read the
				-- published version under a fresh identity; every other refusal keeps the
				-- frozen identity for the source's dedupe.
				pending[id] = nil
			end
			if resultEvent then
				resultEvent:Fire({ nodeId = id, requestId = request.requestId, request = request, result = result })
			end
			if type(result) == "table" and result.reason == "REQUEST_EXPIRED" then
				durable = nil
				refresh()
			end
			report(result, diagnostic)
		else
			report({ ok = false, reason = "TRANSPORT_FAILED" }, result)
		end
		update(part)
	end
	local function remove(instance: Instance)
		if not instance:IsA("BasePart") then
			return
		end
		local entry = nodes[instance]
		if entry then
			shown[entry.prompt] = nil
			nodes[instance] = nil
			for _, connection in entry.connections do
				connection:Disconnect()
			end
			entry.prompt:Destroy()
			entry.anchor:Destroy()
		end
	end
	local function add(instance: Instance)
		if disposed or not instance:IsA("BasePart") or nodes[instance] then
			return
		end
		local anchor = Instance.new("Attachment")
		anchor.Name = "ForgeGatherAnchor"
		anchor.Position = Vector3.new(0, instance.Size.Y / 2 + 1, 0)
		anchor.Parent = instance
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name, prompt.ActionText = "ForgeGather", actionText
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.MaxActivationDistance, prompt.HoldDuration = 8, 0
		prompt.RequiresLineOfSight, prompt.ClickablePrompt, prompt.Enabled = true, true, false
		local owned = {
			prompt.Triggered:Connect(function(actor)
				activate(instance, actor)
			end),
			instance.AttributeChanged:Connect(function()
				update(instance)
			end),
			instance.AncestryChanged:Connect(function()
				update(instance)
			end),
		}
		nodes[instance] = { prompt = prompt, anchor = anchor, connections = owned }
		prompt.Parent = anchor
		update(instance)
	end
	local prompts = game:GetService("ProximityPromptService")
	table.insert(
		connections,
		prompts.PromptShown:Connect(function(prompt: ProximityPrompt)
			for part, entry in nodes do
				if entry.prompt == prompt then
					shown[prompt] = part
				end
			end
		end)
	)
	table.insert(
		connections,
		prompts.PromptHidden:Connect(function(prompt)
			shown[prompt] = nil
		end)
	)
	table.insert(
		connections,
		game:GetService("RunService").RenderStepped:Connect(function()
			selected = nil
			for prompt, part in shown do
				if prompt.Enabled and registered(part) and harvestable(part) then
					if
						not selected
						or tostring(part:GetAttribute("ForgeNodeId"))
							< tostring(selected:GetAttribute("ForgeNodeId"))
					then
						selected = part
					end
				end
			end
			touch.Visible = selected ~= nil and game:GetService("UserInputService").TouchEnabled
			touch:SetAttribute("ForgeNodeId", if selected then selected:GetAttribute("ForgeNodeId") else nil)
		end)
	)
	table.insert(
		connections,
		touch.Activated:Connect(function()
			local part = selected
			if part and touch.Visible then
				activate(part, player, "touch-button-activated")
			end
		end)
	)
	-- Preserve the shared client handshake's broadcast side effects; subscribe first.
	table.insert(
		connections,
		state.OnClientEvent:Connect(function(packet)
			if type(packet) == "table" and packet.durable then
				durable = packet.durable
			end
		end)
	)
	table.insert(connections, tags:GetInstanceAddedSignal(TAG):Connect(add))
	table.insert(connections, tags:GetInstanceRemovedSignal(TAG):Connect(remove))
	for _, instance in tags:GetTagged(TAG) do
		add(instance)
	end
	refresh()
	return {
		destroy = function()
			if disposed then
				return
			end
			disposed = true
			for _, connection in connections do
				connection:Disconnect()
			end
			for part in nodes do
				remove(part)
			end
			table.clear(connections)
			table.clear(pending)
			table.clear(busy)
			if resultEvent then
				resultEvent:Destroy()
			end
			requestEvent:Destroy()
			touchGui:Destroy()
		end,
	}
end
return M
