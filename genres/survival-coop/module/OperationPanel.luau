--!strict
-- Client sheet for content operations OperationExtension executes (practice drills and
-- instruments): one row per operation with its inputs, its gate and a Make button that sends
-- survival-coop:operation-run. Rows come from snapshot.survivalExtensions.operations; the server
-- re-checks every gate, input and station. Strings mirror locale/strings.csv (operation_*).
local M = {}
M.RUN = "survival-coop:operation-run"
-- Engine globals resolve at call time so the pure helpers load under Lune specs.
local env: any = getfenv()
local game: any = env.game
local Instance: any = env.Instance
local Enum: any = env.Enum
local UDim2: any = env.UDim2

local strings: { [string]: { string } } = {
	operation_title = { "Practice and instruments", "연습과 악기" },
	operation_make = { "Make", "만들기" },
	operation_done = { "Made", "만들었어요" },
	operation_hand = { "By hand", "맨손" },
	operation_station = { "Workbench nearby", "근처 작업대" },
	operation_level = { "Character level too low", "캐릭터 레벨이 부족해요" },
	operation_skill = { "Learn the required skill first", "필요한 기술을 먼저 배우세요" },
	operation_items = { "Not enough materials", "재료가 부족해요" },
	operation_away = { "Stand next to a workbench", "작업대 옆에 서세요" },
	operation_failed = { "That did not work. Try again", "실패했어요. 다시 시도하세요" },
}
local refusals: { [string]: string } = {
	CHARACTER_LEVEL_GATE = "operation_level",
	SKILL_GATE = "operation_skill",
	INSUFFICIENT_ITEMS = "operation_items",
	STATION_GATE = "operation_away",
}

function M.keys(): { string }
	local keys = {}
	for key in strings do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

function M.text(locale: string, key: string): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end

function M.refusal(locale: string, reason: string?): string
	return M.text(locale, refusals[reason or ""] or "operation_failed")
end

--- Pure rows: label, input line, gate text and whether Make is offered.
function M.rows(locale: string, state: any, names: { [string]: string }?): { any }
	local out = {}
	for _, row in if type(state) == "table" and type(state.operations) == "table" then state.operations else {} do
		local inputs = {}
		for _, input in row.inputs or {} do
			table.insert(inputs, string.format("%s x%d", (names or {})[input.item] or input.item, input.quantity))
		end
		local output = (row.outputs or {})[1]
		local named = (names or {})[row.id] or (if output then (names or {})[output.item] else nil)
		table.insert(out, {
			id = row.id,
			label = named or row.id,
			inputs = table.concat(inputs, ", "),
			where = M.text(locale, if row.station then "operation_station" else "operation_hand"),
			station = row.station,
			locked = if row.reason then M.refusal(locale, row.reason) else nil,
		})
	end
	return out
end

function M.factory(ctx: any): { destroy: () -> () }?
	local ui = ctx.ui
	local theme, components = ui.theme.default, ui.components
	local players = game:GetService("Players")
	local tags = game:GetService("CollectionService")
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.Enabled, gui.DisplayOrder = "ForgeOperations", false, false, 20
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local dock = if ctx.dock
		then ctx.dock({
			id = "operations",
			label = M.text(ctx.locale, "operation_title"),
			order = 3,
			setOpen = function(open: boolean)
				gui.Enabled = open
			end,
			isOpen = function()
				return gui.Enabled
			end,
		})
		else nil
	local sheet = components.modalSheet(theme, {
		name = "OperationsSheet",
		title = M.text(ctx.locale, "operation_title"),
		parent = gui,
	})
	sheet.frame.Visible = true
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	sheet.close.Activated:Connect(function()
		gui.Enabled = false
	end)
	local status = components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 32) })
	status.Name, status.LayoutOrder, status.Parent = "OperationStatus", 0, sheet.scroll
	-- The nearest registered station of `kind` within reach; the server re-checks reach.
	local function stationId(kind: string?): string
		local character = players.LocalPlayer.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if not kind or not root then
			return "hand"
		end
		local best, distance = "hand", 12
		for _, part in tags:GetTagged("ForgeSurvivalStation") do
			if part:IsA("BasePart") and part:GetAttribute("ForgeStationKind") == kind then
				local d = (part.Position - root.Position).Magnitude
				local id = part:GetAttribute("ForgeStationId")
				if d < distance and type(id) == "string" then
					best, distance = id, d
				end
			end
		end
		return best
	end
	local shown: { any } = {}
	local lastKey = ""
	local function render(snapshot: { [string]: any })
		local state = snapshot.operations
		if dock then
			dock.setAvailable(type(state) == "table")
		end
		local rows = M.rows(ctx.locale, state, ctx.names)
		local parts = {}
		for _, row in rows do
			table.insert(parts, row.id .. ":" .. tostring(row.locked))
		end
		local key = table.concat(parts, "|")
		if key == lastKey then
			return
		end
		lastKey = key
		for _, item in shown do
			item:Destroy()
		end
		table.clear(shown)
		for index, row in rows do
			local text = row.label .. "\n" .. row.inputs .. " / " .. (row.locked or row.where)
			local label = components.label(theme, { text = text, size = UDim2.new(1, 0, 0, 44) })
			label.Name, label.LayoutOrder, label.Parent = "Operation-" .. row.id, index * 2, sheet.scroll
			table.insert(shown, label)
			if not row.locked then
				local make = components.button(theme, {
					text = M.text(ctx.locale, "operation_make"),
					size = UDim2.new(1, 0, 0, 44),
					onClick = function()
						local result = ctx.send(M.RUN, { row.id, stationId(row.station) })
						status.Text = if result.ok
							then M.text(ctx.locale, "operation_done")
							else M.refusal(ctx.locale, result.reason)
					end,
				})
				make.Name, make.LayoutOrder, make.Parent = "Make-" .. row.id, index * 2 + 1, sheet.scroll
				table.insert(shown, make)
			end
		end
	end
	local unsubscribe = ctx.onSnapshot(render)
	-- World prompts (harbor practice stands) send the command directly; show its outcome here.
	local unsend = if ctx.onSend
		then ctx.onSend(function(action: string, _args: any, result: any)
			if action == M.RUN and type(result) == "table" then
				status.Text = if result.ok
					then M.text(ctx.locale, "operation_done")
					else M.refusal(ctx.locale, result.reason)
			end
		end)
		else nil
	return {
		destroy = function()
			unsubscribe()
			if unsend then
				unsend()
			end
			gui:Destroy()
		end,
	}
end

return M
