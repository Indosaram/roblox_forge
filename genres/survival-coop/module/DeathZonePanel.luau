--!strict
-- Client death-zone panel: shows the actor's zone (safe or danger) from
-- snapshot.survivalExtensions["death-zone"] and a toggle. Entering danger asks for a confirm
-- warning first; leaving needs none. The server owns the zone; this panel only sends zone-set.
-- Strings mirror games/robango-island/locale/strings.csv keys (zone_*).
local M = {}

local SET = "zone-set"

local strings: { [string]: { string } } = {
	zone_title = { "Death zone", "데스 존" },
	zone_safe = { "Safe zone: you keep your bag when you fall", "안전 구역: 쓰러져도 가방을 지켜요" },
	zone_danger = {
		"Danger zone: your bag drops when you fall",
		"위험 구역: 쓰러지면 가방을 떨어뜨려요",
	},
	zone_enter = { "Enter danger zone", "위험 구역 입장" },
	zone_leave = { "Return to safe zone", "안전 구역으로 돌아가기" },
	zone_warning = {
		"If you fall in the danger zone, everything in your bag drops. Others can take it for ten minutes after you.",
		"위험 구역에서 쓰러지면 가방의 모든 물건을 떨어뜨려요. 열 분 뒤에는 다른 사람도 가져갈 수 있어요.",
	},
	zone_confirm = { "Enter anyway", "그래도 입장" },
	zone_cancel = { "Stay safe", "안전하게 있기" },
	zone_failed = {
		"The zone could not be changed. Try again later",
		"구역을 바꾸지 못했어요. 잠시 후 다시 시도하세요",
	},
	zone_dead = { "You cannot change zone while down", "쓰러진 동안은 구역을 바꿀 수 없어요" },
}
local refusals: { [string]: string } = {
	NOT_ALIVE = "zone_dead",
}

M.keys = {} :: { string }
for key in strings do
	table.insert(M.keys, key)
end
table.sort(M.keys)

--- Pure text lookup (specced): falls back to the key itself when unknown.
function M.text(locale: string, key: string): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end

--- Maps a server refusal reason to its localized message.
function M.refusal(locale: string, reason: string?): string
	return M.text(locale, refusals[reason or ""] or "zone_failed")
end

--- What a toggle press does from `zone`: danger is entered only through the confirm warning.
function M.nextStep(zone: string): string
	return if zone == "danger" then "leave" else "confirm"
end

function M.factory(ctx: any): { destroy: () -> () }?
	local ui = ctx.ui
	local theme = ui.theme.default
	local players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeDeathZone", false, 15, false
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ui.components.modalSheet(theme, {
		name = "DeathZoneSheet",
		title = M.text(ctx.locale, "zone_title"),
		parent = gui,
	})
	sheet.frame.Visible = true
	local indicator = ui.components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 56) })
	indicator.Name, indicator.LayoutOrder, indicator.Parent = "ZoneIndicator", 1, sheet.scroll
	local status = ui.components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 40) })
	status.Name, status.LayoutOrder, status.Parent = "ZoneStatus", 2, sheet.scroll
	local warning = ui.components.label(theme, {
		text = M.text(ctx.locale, "zone_warning"),
		size = UDim2.new(1, 0, 0, 88),
	})
	warning.Name, warning.LayoutOrder, warning.Visible, warning.Parent = "ZoneWarning", 3, false, sheet.scroll
	local zone = "safe"
	local alive = true
	local toggle: TextButton
	local confirm: TextButton
	local cancel: TextButton
	local function show(confirming: boolean)
		warning.Visible, confirm.Visible, cancel.Visible = confirming, confirming, confirming
		toggle.Visible = not confirming
	end
	local function send(target: string)
		local result = ctx.send(SET, { target })
		status.Text = if result.ok then "" else M.refusal(ctx.locale, result.reason)
		show(false)
	end
	toggle = ui.components.button(theme, {
		text = "",
		size = UDim2.new(1, 0, 0, 44),
		onClick = function()
			if not alive then
				status.Text = M.text(ctx.locale, "zone_dead")
			elseif M.nextStep(zone) == "confirm" then
				status.Text = ""
				show(true)
			else
				send("safe")
			end
		end,
	})
	toggle.Name, toggle.LayoutOrder, toggle.Parent = "ZoneToggle", 4, sheet.scroll
	confirm = ui.components.button(theme, {
		text = M.text(ctx.locale, "zone_confirm"),
		size = UDim2.new(1, 0, 0, 44),
		onClick = function()
			send("danger")
		end,
	})
	confirm.Name, confirm.LayoutOrder, confirm.Visible, confirm.Parent = "ZoneConfirm", 5, false, sheet.scroll
	cancel = ui.components.button(theme, {
		text = M.text(ctx.locale, "zone_cancel"),
		size = UDim2.new(1, 0, 0, 44),
		onClick = function()
			show(false)
		end,
	})
	cancel.Name, cancel.LayoutOrder, cancel.Visible, cancel.Parent = "ZoneCancel", 6, false, sheet.scroll
	local function render(snapshot: { [string]: any })
		local state = snapshot["death-zone"]
		if type(state) ~= "table" then
			gui.Enabled = false
			return
		end
		zone, alive = state.zone, state.alive ~= false
		indicator.Text = M.text(ctx.locale, if zone == "danger" then "zone_danger" else "zone_safe")
		toggle.Text = M.text(ctx.locale, if zone == "danger" then "zone_leave" else "zone_enter")
		gui.Enabled = true
	end
	sheet.close.Activated:Connect(function()
		gui.Enabled = false
	end)
	local unsubscribe = ctx.onSnapshot(render)
	local input = game:GetService("UserInputService")
	local keyConnection = input.InputBegan:Connect(function(event, processed)
		if not processed and event.KeyCode == Enum.KeyCode.Z then
			gui.Enabled = not gui.Enabled
		end
	end)
	return {
		destroy = function()
			keyConnection:Disconnect()
			unsubscribe()
			gui:Destroy()
		end,
	}
end

return M
