--!strict
local Match = require("../../../core/domain/brawl/Match")
local M = {}

-- Geometry is viewport-relative and all controls remain at least 44px high.
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

-- ctx.ui is the Roblox datatype/Instance namespace (injectable for engine tests).
-- ctx.text owns localization; server refusals are rendered, never swallowed.
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
			button.Visible = model[name] == true
		end
	end
	for index, name in { "join", "leave", "claim" } do
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
				if not model[name] then
					return
				end
				local actions = { join = "brawl-queue", leave = "brawl-leave", claim = "brawl-reward" }
				local result = ctx.send("survival-coop:" .. actions[name], {})
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

return M
