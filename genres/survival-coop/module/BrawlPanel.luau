--!strict
local Match = require("../../../core/domain/brawl/Match")
local M = {}

function M.layout(width: number, height: number): any
	return { width = math.min(440, width - 24), height = math.min(480, height - 96), controlHeight = 44 }
end

function M.model(state: any, actor: string, now: number, receipt: any): any
	local player = state.actors[actor]
	local alive = 0
	for _, participant in state.actors do
		if participant.alive then
			alive += 1
		end
	end
	local finished = state.phase == "finished"
	local remaining = if state.startsAt
		then math.max(
			0,
			math.ceil(state.startsAt + (if state.phase == "preparing" then 0 else state.policy.durationSeconds) - now)
		)
		else 0
	return {
		phase = state.phase,
		queued = #state.order,
		minimum = state.policy.minimumPlayers,
		maximum = state.policy.maximumPlayers,
		minimumLevel = state.policy.minimumLevel,
		alive = alive,
		remaining = remaining,
		weather = if state.startsAt then Match.weather(state, now).id else "clear",
		timeline = state.policy.weather,
		spectator = player ~= nil and not player.alive and not finished,
		result = if not finished
			then nil
			elseif state.winner == actor then "win"
			elseif not state.winner then "draw"
			else "eliminated",
		join = state.phase == "queue" and not player,
		leave = player ~= nil and not finished,
		claim = finished and player ~= nil and not (receipt and receipt.ok),
		settlement = receipt,
		participationReward = state.policy.participationReward,
		winReward = state.policy.winReward,
		dailySettlements = state.policy.dailySettlements,
		radius = if state.startsAt
			then state.policy.initialRadius * math.clamp(
				(state.startsAt + state.policy.durationSeconds - now)
					/ (state.policy.durationSeconds - state.policy.collapseAt),
				0,
				1
			)
			else state.policy.initialRadius,
	}
end

function M.mount(ctx: any): any
	local ui = ctx.ui
	local connections = {}
	local function make(class: string, properties: any, parent: any): any
		local object = ui.Instance.new(class)
		for key, value in properties do
			object[key] = value
		end
		object.Parent = parent
		return object
	end
	local root = make("Frame", {
		Name = "BrawlPanel",
		AnchorPoint = ui.Vector2.new(0.5, 0.5),
		Position = ui.UDim2.fromScale(0.5, 0.5),
	}, ctx.parent)
	local scroll = make("ScrollingFrame", {
		Size = ui.UDim2.fromScale(1, 1),
		AutomaticCanvasSize = ui.Enum.AutomaticSize.Y,
		CanvasSize = ui.UDim2.fromOffset(0, 0),
		ScrollBarThickness = 6,
	}, root)
	make("UIListLayout", { Padding = ui.UDim.new(0, 8), SortOrder = ui.Enum.SortOrder.LayoutOrder }, scroll)
	make("UIPadding", {
		PaddingTop = ui.UDim.new(0, 12),
		PaddingBottom = ui.UDim.new(0, 12),
		PaddingLeft = ui.UDim.new(0, 12),
		PaddingRight = ui.UDim.new(0, 12),
	}, scroll)
	local labels = {}
	for index, name in
		{ "brawl_title", "brawl_status", "brawl_snapshot", "brawl_weather", "brawl_rewards", "brawl_feedback" }
	do
		labels[name] = make("TextLabel", {
			Name = name,
			LayoutOrder = index,
			Text = ctx.text(name),
			TextWrapped = true,
			AutomaticSize = ui.Enum.AutomaticSize.Y,
			Size = ui.UDim2.new(1, -8, 0, 44),
			TextSize = 18,
		}, scroll)
	end
	local state: any = nil
	local receipt: any = nil
	local buttons: { [string]: any } = {}
	local api = {}
	function api.resize(width: number, height: number)
		local layout = M.layout(width, height)
		root.Size = ui.UDim2.fromOffset(layout.width, layout.height)
	end
	function api.update(value: any, now: number)
		if state and state.id ~= value.id then
			receipt = nil
		end
		state = value
		local model = M.model(state, ctx.actor, now, receipt)
		labels.brawl_status.Text = ctx.text("brawl_status", model)
		labels.brawl_weather.Text = ctx.text("brawl_weather", model)
		labels.brawl_rewards.Text = ctx.text("brawl_rewards", model)
		for name, button in buttons do
			local combat = name == "attack" or name == "ranged" or name == "dodge" or name == "guard"
			local participant = state.actors[ctx.actor]
			button.Visible = model[name] == true
				or (combat and participant ~= nil and participant.alive and state.phase == "active")
		end
	end
	for index, name in { "join", "leave", "claim", "attack", "ranged", "dodge", "guard" } do
		local button = make("TextButton", {
			Name = name,
			LayoutOrder = 10 + index,
			Size = ui.UDim2.new(1, -8, 0, 44),
			Text = ctx.text("brawl_" .. name),
			TextSize = 18,
			Visible = false,
		}, scroll)
		buttons[name] = button
		table.insert(
			connections,
			button.Activated:Connect(function()
				if not state then
					return
				end
				local model = M.model(state, ctx.actor, ctx.now(), receipt)
				local combat = name == "attack" or name == "ranged" or name == "dodge" or name == "guard"
				local participant = state.actors[ctx.actor]
				if
					not model[name] and not (combat and participant and participant.alive and state.phase == "active")
				then
					return
				end
				local actions = { join = "brawl-queue", leave = "brawl-leave", claim = "brawl-reward" }
				local args = {}
				if combat then
					local token = name
					if name == "attack" or name == "ranged" then
						local target = if ctx.target then ctx.target(state) else nil
						if not target then
							return
						end
						token = (if name == "ranged" then "ranged:" else "melee:") .. target
					end
					args = { token }
				end
				local result = ctx.send("survival-coop:" .. (if combat then "brawl-action" else actions[name]), args)
				if name == "claim" then
					receipt = result
				end
				labels.brawl_feedback.Text = ctx.text(if result.ok then "brawl_ok" else result.reason, result)
				api.update(state, ctx.now())
			end)
		)
	end
	function api.destroy()
		for _, connection in connections do
			connection:Disconnect()
		end
		root:Destroy()
	end
	api.resize(ctx.width, ctx.height)
	return api
end

function M.factory(ctx: any): any
	local env: any = getfenv()
	local players = env.game:GetService("Players")
	local workspace = env.game:GetService("Workspace")
	local gui = env.Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeBrawl", false, 18, false
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local korean = string.sub(ctx.locale, 1, 2) == "ko"
	local strings = {
		brawl_title = { "Brawl", "난투" },
		brawl_snapshot = {
			"Snapshot equipment only. Original equipment is not consumed.",
			"복제 장비만 사용합니다. 원본 장비는 소모되지 않습니다.",
		},
		brawl_join = { "Join queue", "대기열 참가" },
		brawl_leave = { "Leave", "나가기" },
		brawl_claim = { "Claim result", "결과 받기" },
		brawl_feedback = { "", "" },
		brawl_ok = { "Confirmed", "확인됨" },
		brawl_attack = { "Attack nearest rival", "가까운 상대 공격" },
		brawl_ranged = { "Shoot nearest rival", "가까운 상대 사격" },
		NO_AMMO = { "No snapshot ammunition", "복제 탄약이 없습니다" },
		brawl_dodge = { "Dodge", "회피" },
		brawl_guard = { "Guard", "방어" },
		LEVEL_REQUIRED = { "Required level not reached", "참가 레벨이 부족합니다" },
		QUEUE_FULL = { "Queue full", "대기열이 가득 찼습니다" },
		QUEUE_CLOSED = { "Queue closed", "대기열이 마감되었습니다" },
		NOT_ACTIVE = { "Match has not started", "경기가 시작되지 않았습니다" },
		ELIMINATED = { "Eliminated: spectating", "탈락: 관전 중" },
		WEATHER_RANGE = { "Fog restricts range", "안개로 사거리가 제한됩니다" },
		WEATHER_MOUNT = { "Storm prevents mounting", "폭풍 중에는 탑승할 수 없습니다" },
		UNVERIFIED_ACTION = { "Action unavailable", "사용할 수 없는 행동입니다" },
		RECOVERY = { "Recovering", "회복 중" },
		PERSONAL_UNAVAILABLE = { "Settlement pending", "정산 대기 중" },
		COMMAND_PENDING = { "Previous command pending", "이전 명령 처리 중" },
	}
	local statuses = {
		queue = "대기열",
		preparing = "준비 중",
		active = "경기 중",
		finished = "종료",
		win = "승리",
		draw = "무승부",
		eliminated = "탈락",
		spectator = "관전 중",
	}
	local function text(key: string, model: any?): string
		if key == "brawl_status" and model then
			local result = model.result or (if model.spectator then "spectator" else "")
			return string.format(
				"%s | %d/%d | %ds | %s",
				if korean then statuses[model.phase] or model.phase else model.phase,
				model.queued,
				model.maximum,
				model.remaining,
				if korean then statuses[result] or result else result
			)
		elseif key == "brawl_weather" and model then
			return string.format(
				"%s | %.0f | %s",
				model.weather,
				model.radius,
				if korean
					then "비: 질주 기력 증가 / 안개: 사거리 제한 / 폭풍: 탑승 해제"
					else "Rain: sprint cost / Fog: range limit / Storm: dismount"
			)
		elseif key == "brawl_rewards" and model then
			return string.format(
				"%s %d / %d | %d",
				if korean then "참가 / 승리" else "Participation / win",
				model.participationReward,
				model.winReward,
				model.dailySettlements
			)
		end
		local row = strings[key]
		return if row then row[if korean then 2 else 1] else key
	end
	local function now(): number
		return workspace:GetServerTimeNow()
	end
	local panel = M.mount({
		ui = { Instance = env.Instance, Enum = env.Enum, UDim = env.UDim, UDim2 = env.UDim2, Vector2 = env.Vector2 },
		parent = gui,
		target = function(state: any): string?
			local character = players.LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then
				return nil
			end
			local nearest, distance = nil, math.huge
			for actor, participant in state.actors do
				if actor ~= tostring(players.LocalPlayer.UserId) and participant.alive then
					local player = players:GetPlayerByUserId(tonumber(actor) or 0)
					local other = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
					if other and (other.Position - root.Position).Magnitude < distance then
						nearest, distance = actor, (other.Position - root.Position).Magnitude
					end
				end
			end
			return nearest
		end,
		actor = tostring(players.LocalPlayer.UserId),
		send = ctx.send,
		now = now,
		width = gui.AbsoluteSize.X,
		height = gui.AbsoluteSize.Y,
		text = text,
	})
	local dock = if ctx.dock
		then ctx.dock({
			id = "brawl",
			label = text("brawl_title"),
			order = 65,
			setOpen = function(open: boolean)
				gui.Enabled = open
			end,
			isOpen = function(): boolean
				return gui.Enabled
			end,
		})
		else nil
	-- Keep the launcher usable outside the brawl role and explain the restriction in its sheet.
	local root = gui:FindFirstChild("BrawlPanel")
	if ctx.fitSheet then
		ctx.fitSheet(root)
	end
	local unavailable = env.Instance.new("TextLabel")
	unavailable.Name, unavailable.TextWrapped = "Unavailable", true
	unavailable.Size = env.UDim2.new(1, -24, 0, 88)
	unavailable.Position = env.UDim2.fromOffset(12, 12)
	unavailable.Text = if korean
		then "난투 서버에서만 이용할 수 있어요. 항구에서 난투 서버로 이동하세요."
		else "Brawl is available on a brawl server. Travel there from the harbor."
	unavailable.Parent = root
	local close = env.Instance.new("TextButton")
	close.Name, close.Text = "Close", if korean then "닫기" else "Close"
	close.Size, close.Position = env.UDim2.fromOffset(88, 44), env.UDim2.new(1, -100, 1, -56)
	close.Parent = root
	local closeConnection = close.Activated:Connect(function()
		gui.Enabled = false
	end)
	local unsubscribe = ctx.onSnapshot(function(snapshots)
		local state = snapshots.brawl
		unavailable.Visible = state == nil
		for _, child in root:GetChildren() do
			if child:IsA("ScrollingFrame") then
				child.Visible = state ~= nil
			end
		end
		if state then
			panel.update(state, now())
		end
	end)
	local resize = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		panel.resize(gui.AbsoluteSize.X, gui.AbsoluteSize.Y)
	end)
	return {
		destroy = function()
			closeConnection:Disconnect()
			if dock then
				dock.setAvailable(false)
			end
			unsubscribe()
			resize:Disconnect()
			panel.destroy()
			gui:Destroy()
		end,
	}
end

return M
