--!strict
local CommandTransport = require("../../../core/infra/genre/CommandTransport")
local M = {}
-- Optional `locale` (label) and `names` (kind/catalog id -> display name).
export type Options = { onResult: ((any, any?) -> ())?, locale: string?, names: { [string]: string }? }
local TAG = "ForgeSurvivalNode"
local ACTION = "survival-coop:gather"

local function integer(value: any): boolean
	return type(value) == "number" and value >= 0 and value <= 2 ^ 53 - 2 and value % 1 == 0
end

--- Gather action label for a locale (specced); `busy` while a request is pending.
function M.actionText(locale: string?, busy: boolean?): string
	local ko = locale and string.sub(locale, 1, 2) == "ko"
	return if busy then (if ko then "채집 중..." else "Collecting...") elseif ko then "채집하기" else "Gather"
end

--- Localized, player-visible text for a refused gather (never a silent no-op).
--- `result.data.requirement` carries the server's admission detail when known.
function M.refusalText(locale: string?, result: any, names: { [string]: string }?): string?
	if type(result) ~= "table" or result.ok ~= false or type(result.reason) ~= "string" then
		return nil
	end
	local ko = locale and string.sub(locale, 1, 2) == "ko"
	local need = if type(result.data) == "table" and type(result.data.requirement) == "table"
		then result.data.requirement
		else {}
	local reason = result.reason
	if reason == "LEVEL_LOCKED" then
		local level = tostring(need.level or "?")
		return if ko then "레벨 " .. level .. " 필요" else "Requires level " .. level
	elseif reason == "TOOL_UNAVAILABLE" then
		local tool = if type(need.tool) == "string" then (names and names[need.tool]) or need.tool else nil
		if tool and need.orBetter == true then
			return if ko then tool .. " 이상 도구 장착 필요" else "Requires " .. tool .. " or better (equip it)"
		elseif tool then
			return if ko then tool .. " 장착 필요" else "Requires " .. tool .. " (equip it)"
		end
		return if ko then "맞는 도구를 장착하세요" else "Equip the right tool"
	elseif reason == "SKILL_LOCKED" then
		local skill = if type(need.skill) == "string" then (names and names[need.skill]) or need.skill else nil
		return if ko
			then "기술 필요" .. (if skill then ": " .. skill else "")
			else "Requires skill" .. (if skill then ": " .. skill else "")
	elseif reason == "NODE_DEPLETED" then
		-- The server reports how long until the node regrows; show it instead of a silent press.
		if type(need.retryMillis) == "number" and need.retryMillis >= 0 then
			local seconds = math.max(1, math.ceil(need.retryMillis / 1000))
			return if ko
				then "아직 다시 채집할 수 없어요 (" .. seconds .. "초)"
				else "Not ready to gather again (" .. seconds .. "s)"
		end
		return if ko then "자원이 고갈되었습니다" else "This node is depleted"
	elseif reason == "NODE_UNREACHABLE" then
		return if ko then "너무 멉니다. 더 가까이 가세요" else "Too far away, move closer"
	elseif string.find(reason, "WEIGHT") or string.find(reason, "SLOTS") or string.find(reason, "CAPACITY") then
		return if ko then "가방이 가득 찼습니다" else "Your bag is full"
	elseif reason == "STALE_VERSION" then
		return nil -- the node changed under the request; the next press uses the new version
	end
	return if ko then "채집할 수 없습니다 (" .. reason .. ")" else "Cannot gather (" .. reason .. ")"
end

--- A final refusal ends the frozen request: the source kept no grant, so the prompt returns
--- to a fresh gather. STALE_VERSION/NODE_DEPLETED and every `rejected` answer (tool, level,
--- skill admission) are final; transient answers (pending, recovering, transport) keep the
--- frozen identity for the source's dedupe.
function M.final(result: any): boolean
	if type(result) ~= "table" or result.ok ~= false then
		return false
	end
	return result.reason == "STALE_VERSION"
		or result.reason == "NODE_DEPLETED"
		or (type(result.data) == "table" and result.data.status == "rejected")
end

--- Sends one frozen gather request until it leaves the durable transfer's `pending` phase.
--- The server advances one crash-safe transfer step per call (the first answer is credited
--- but not finalized), so replaying the same identity finishes it; it never mints again.
function M.drive(send: () -> (any, any?)): (any, any?)
	local result, diagnostic = send()
	for _ = 1, 4 do
		if
			type(result) ~= "table"
			or result.ok ~= false
			or result.reason ~= nil
			or type(result.data) ~= "table"
			or result.data.status ~= "pending"
		then
			break
		end
		result, diagnostic = send()
	end
	return result, diagnostic
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
	local notice = Instance.new("TextLabel")
	notice.Name, notice.Visible, notice.Text = "GatherNotice", false, ""
	notice.Size, notice.Position = UDim2.fromOffset(320, 36), UDim2.new(0.5, -160, 1, -160)
	notice.BackgroundColor3, notice.BackgroundTransparency = Color3.fromRGB(58, 32, 28), 0.15
	notice.BorderSizePixel = 0
	notice.Font = Enum.Font.GothamBold
	notice.TextSize = 15
	notice.TextColor3 = Color3.fromRGB(250, 236, 226)
	notice.Parent = touchGui
	local noticeSerial = 0
	touchGui.Parent = player:WaitForChild("PlayerGui")
	local shown: { [ProximityPrompt]: BasePart } = {}
	local selected: BasePart? = nil
	local nodes: { [BasePart]: { prompt: ProximityPrompt, connections: { RBXScriptConnection } } } = {}
	local function report(result: any, diagnostic: any?)
		if disposed then
			return
		end
		local text = M.refusalText(options and options.locale, result, names)
		if text then
			noticeSerial += 1
			local serial = noticeSerial
			notice.Text, notice.Visible = text, true
			task.delay(3, function()
				if serial == noticeSerial then
					notice.Visible = false
				end
			end)
		end
		if options and options.onResult then
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
	-- A published node on cooldown keeps its prompt: E asks the server, whose refusal
	-- carries the remaining regrow time for the notice.
	local function published(part: BasePart): boolean
		return integer(part:GetAttribute("ForgeNodeVersion"))
			and integer(part:GetAttribute("ForgeNodeCount"))
			and type(part:GetAttribute("ForgeNodeDepleted")) == "boolean"
	end
	local function update(part: BasePart)
		local entry = nodes[part]
		if entry then
			local id, kind = registered(part)
			entry.prompt.Enabled = not disposed and id ~= nil and (pending[id] ~= nil or published(part))
			-- E on a pending node replays it (no new items): label it so.
			entry.prompt.ActionText =
				M.actionText(options and options.locale, id ~= nil and (pending[id] ~= nil or busy[id] == true))
			if kind then
				local item = part:GetAttribute("ForgeNodeItem")
				local key = if type(item) == "string" then item else kind
				entry.prompt.ObjectText = names[kind] or names[key] or key
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
			if not published(part) then
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
		update(part)
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
			return M.drive(function()
				return action:InvokeServer("command", request)
			end)
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
			if confirmed or M.final(result) then
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
		end
	end
	local function add(instance: Instance)
		if disposed or not instance:IsA("BasePart") or nodes[instance] then
			return
		end
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name, prompt.ActionText = "ForgeGather", actionText
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.MaxActivationDistance, prompt.HoldDuration = 8, 0
		-- At the server reach point; dressing may occlude it, the server enforces reach.
		prompt.RequiresLineOfSight, prompt.ClickablePrompt, prompt.Enabled = false, true, false
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
		nodes[instance] = { prompt = prompt, connections = owned }
		prompt.Parent = instance
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
	-- Subscribe before the handshake.
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
