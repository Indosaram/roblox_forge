--!strict
-- Client taming panel: pen list (species, ready time, feed button) plus mount/dismount buttons,
-- rendered from snapshot.survivalExtensions.taming. The server owns every decision (ready time,
-- feed value, ride speed and carry); this panel only sends durable commands and renders results.
-- Strings mirror games/robango-island/locale/strings.csv keys (tame_*); species names are the
-- pack's wildlife_<id> strings, with the raw id as fallback.
local M = {}

local FEED = "tame-feed"
local MOUNT = "tame-mount"
local DISMOUNT = "tame-dismount"

local strings: { [string]: { string } } = {
	tame_title = { "Tamed animals", "길들인 동물" },
	tame_empty = {
		"No tamed animals yet. Stun a wild animal, then capture it with a bola.",
		"길들인 동물이 아직 없어요. 야생 동물을 기절시킨 뒤 볼라로 붙잡으세요.",
	},
	tame_ready = { "Ready", "준비 완료" },
	tame_remaining = { "Ready in %s", "%s 후 준비" },
	tame_feed = { "Feed", "먹이 주기" },
	tame_mount = { "Mount", "타기" },
	tame_dismount = { "Dismount", "내리기" },
	tame_mounted = { "Riding %s", "%s 탑승 중" },
	tame_failed = { "That did not work. Try again.", "잘 안 됐어요. 다시 시도하세요." },
	tame_pending = {
		"Saving... try the same action again.",
		"저장 중이에요. 같은 동작을 다시 시도하세요.",
	},
	wildlife_ridge_strider = { "Ridge Strider", "능선걸음이" },
	wildlife_fen_trotter = { "Fen Trotter", "늪종종이" },
	wildlife_bluff_bounder = { "Bluff Bounder", "벼랑깡충이" },
}

local function pick(locale: string, entry: { string }): string
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end

--- Pure text lookup (specced): falls back to the key; `%s` is filled with `arg`.
function M.text(locale: string, key: string, arg: string?): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	local text = pick(locale, entry)
	if arg ~= nil then
		text = string.format(text, arg)
	end
	return text
end

--- Localized species name for a wildlife id.
function M.species(locale: string, species: string): string
	local entry = strings["wildlife_" .. string.gsub(species, "%-", "_")]
	return if entry then pick(locale, entry) else species
end

--- m:ss for a remaining time in milliseconds (rounded up to whole seconds).
function M.clock(remainingMillis: number): string
	local seconds = math.max(0, math.ceil(remainingMillis / 1000))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

--- Pen label for a row: "Ready" once the timer is spent, else the localized countdown.
function M.pen(locale: string, remainingMillis: number): string
	if remainingMillis <= 0 then
		return M.text(locale, "tame_ready")
	end
	return M.text(locale, "tame_remaining", M.clock(remainingMillis))
end

--- Maps a send result to the message shown under the list ("" on success).
function M.refusal(locale: string, result: { ok: boolean?, reason: string? }): string
	if result.ok then
		return ""
	end
	return M.text(locale, if result.reason == "CHARGE_PENDING" then "tame_pending" else "tame_failed")
end

function M.factory(ctx: any): { destroy: () -> () }?
	local ui = ctx.ui
	local theme = ui.theme.default
	local players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeTaming", false, 15, false
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ui.components.modalSheet(theme, {
		name = "TamingSheet",
		title = M.text(ctx.locale, "tame_title"),
		parent = gui,
	})
	local status = ui.components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 28), parent = sheet.content })
	status.Name = "TamingStatus"
	local rows = Instance.new("Frame")
	rows.Name, rows.BackgroundTransparency, rows.Size, rows.Parent =
		"TamingRows", 1, UDim2.new(1, 0, 0, 0), sheet.content
	rows.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIListLayout")
	layout.Padding, layout.Parent = UDim.new(0, 6), rows
	local timers: { { label: TextLabel, remaining: number } } = {}
	local received = os.clock()
	local function send(action: string, args: { any }): any
		local result = ctx.send(action, args)
		status.Text = M.refusal(ctx.locale, result)
		return result
	end
	local function feed(animalId: string, feeds: { string })
		for _, feedId in feeds do
			local result = send(FEED, { animalId, feedId })
			if result.ok or result.reason ~= "NO_FEED_ITEM" then
				return
			end
		end
	end
	local function render(snapshot: { [string]: any })
		for _, child in rows:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		table.clear(timers)
		received = os.clock()
		local state = snapshot.taming
		if type(state) ~= "table" then
			return
		end
		local order = 0
		local function line(): Frame
			order += 1
			local frame = Instance.new("Frame")
			frame.Name, frame.BackgroundTransparency, frame.Size = "Row" .. order, 1, UDim2.new(1, 0, 0, 48)
			frame.LayoutOrder, frame.Parent = order, rows
			return frame
		end
		if state.ride then
			local mounted = line()
			ui.components.label(theme, {
				text = M.text(ctx.locale, "tame_mounted", M.species(ctx.locale, state.ride.species)),
				size = UDim2.fromScale(0.62, 1),
				parent = mounted,
			})
			local dismount = ui.components.button(theme, {
				text = M.text(ctx.locale, "tame_dismount"),
				size = UDim2.fromScale(0.36, 1),
				position = UDim2.fromScale(0.64, 0),
				parent = mounted,
				onClick = function()
					send(DISMOUNT, {})
				end,
			})
			dismount.Name = "Dismount"
		end
		if #state.animals == 0 then
			ui.components.label(
				theme,
				{ text = M.text(ctx.locale, "tame_empty"), size = UDim2.new(1, 0, 0, 48), parent = line() }
			)
		end
		for _, animal in state.animals do
			local frame = line()
			local label = ui.components.label(theme, {
				text = M.species(ctx.locale, animal.species) .. "  " .. M.pen(ctx.locale, animal.remainingMillis),
				size = UDim2.fromScale(0.5, 1),
				parent = frame,
			})
			table.insert(timers, { label = label, remaining = animal.remainingMillis, species = animal.species } :: any)
			local feedButton = ui.components.button(theme, {
				text = M.text(ctx.locale, "tame_feed"),
				size = UDim2.fromScale(0.23, 1),
				position = UDim2.fromScale(0.51, 0),
				parent = frame,
				onClick = function()
					feed(animal.id, state.feeds)
				end,
			})
			feedButton.Name = "Feed-" .. animal.id
			local mountButton = ui.components.button(theme, {
				text = M.text(ctx.locale, "tame_mount"),
				size = UDim2.fromScale(0.23, 1),
				position = UDim2.fromScale(0.76, 0),
				parent = frame,
				onClick = function()
					send(MOUNT, { animal.id })
				end,
			})
			mountButton.Name = "Mount-" .. animal.id
		end
	end
	local unsubscribe = ctx.onSnapshot(render)
	local alive = true
	task.spawn(function()
		while alive do
			task.wait(1)
			local elapsed = (os.clock() - received) * 1000
			for _, timer in timers do
				local entry: any = timer
				entry.label.Text = M.species(ctx.locale, entry.species)
					.. "  "
					.. M.pen(ctx.locale, entry.remaining - elapsed)
			end
		end
	end)
	local input = game:GetService("UserInputService")
	local keyConnection = input.InputBegan:Connect(function(event, processed)
		if not processed and event.KeyCode == Enum.KeyCode.T then
			gui.Enabled = not gui.Enabled
		end
	end)
	return {
		destroy = function()
			alive = false
			keyConnection:Disconnect()
			unsubscribe()
			gui:Destroy()
		end,
	}
end

return M
