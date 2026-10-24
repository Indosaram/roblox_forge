--!strict
-- Client region-safety panel (ui.danger-zone): a read-only explanation of the actor's zone from
-- snapshot.survivalExtensions["death-zone"] and where optional PvP lives (brawl, team siege).
-- Per the UI spec lead decision it never offers entering danger; a player still flagged danger
-- (older saves) gets only the way back to safe. The server owns the zone.
-- Strings mirror games/robango-island/locale/strings.csv keys (zone_*).
local M = {}

-- Durable ids are namespaced: the server's action list carries "survival-coop:zone-set".
local SET = "survival-coop:zone-set"

local strings: { [string]: { string } } = {
	zone_title = { "Region safety", "지역 안전" },
	zone_safe = { "Safe zone: you keep your bag when you fall", "안전 구역: 쓰러져도 가방을 지켜요" },
	zone_danger = {
		"Danger zone: your bag drops when you fall",
		"위험 구역: 쓰러지면 가방을 떨어뜨려요",
	},
	zone_leave = { "Return to safe zone", "안전 구역으로 돌아가기" },
	zone_pvp = {
		"Optional PvP is in Brawl and Team siege, with a snapshot loadout: your bag is never at risk there.",
		"선택형 PvP는 난투와 팀 공성전에서 해요. 장비 스냅샷으로 싸우니 가방은 잃지 않아요.",
	},
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

--- The only action the panel offers from `zone`: leaving danger; nothing ever enters it.
function M.nextStep(zone: string): string?
	return if zone == "danger" then "leave" else nil
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
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	local dock = if ctx.dock
		then ctx.dock({
			id = "death-zone",
			label = M.text(ctx.locale, "zone_title"),
			order = 7,
			setOpen = function(open: boolean)
				gui.Enabled = open
			end,
			isOpen = function()
				return gui.Enabled
			end,
		})
		else nil
	local indicator = ui.components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 36) })
	indicator.Name, indicator.LayoutOrder, indicator.Parent = "ZoneIndicator", 1, sheet.scroll
	local status = ui.components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 40) })
	status.Name, status.LayoutOrder, status.Visible, status.Parent = "ZoneStatus", 2, false, sheet.scroll
	local rules = ui.components.label(theme, { text = M.text(ctx.locale, "zone_pvp"), size = UDim2.new(1, 0, 0, 56) })
	rules.Name, rules.LayoutOrder, rules.Parent = "ZoneRules", 3, sheet.scroll
	local zone = "safe"
	local alive = true
	local function setStatus(text: string)
		status.Text = text
		status.Visible = text ~= ""
	end
	-- Shown only while the actor is in danger: the way back. There is no way in.
	local toggle = ui.components.button(theme, {
		text = M.text(ctx.locale, "zone_leave"),
		size = UDim2.new(1, 0, 0, 44),
		onClick = function()
			if not alive then
				setStatus(M.text(ctx.locale, "zone_dead"))
			elseif M.nextStep(zone) == "leave" then
				local result = ctx.send(SET, { "safe" })
				setStatus(if result.ok then "" else M.refusal(ctx.locale, result.reason))
			end
		end,
	})
	toggle.Name, toggle.LayoutOrder, toggle.Visible, toggle.Parent = "ZoneLeave", 4, false, sheet.scroll
	local function render(snapshot: { [string]: any })
		local state = snapshot["death-zone"]
		if type(state) ~= "table" then
			gui.Enabled = false
			if dock then
				dock.setAvailable(false)
			end
			return
		end
		if dock then
			dock.setAvailable(true)
		end
		zone, alive = state.zone, state.alive ~= false
		indicator.Text = M.text(ctx.locale, if zone == "danger" then "zone_danger" else "zone_safe")
		toggle.Visible = M.nextStep(zone) == "leave"
		-- The panel opens from the dock (or Z); a snapshot only refreshes its text and never
		-- pops the sheet over the world.
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
