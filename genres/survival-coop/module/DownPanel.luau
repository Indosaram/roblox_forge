--!strict
-- Client down panel and rescue flares (Robango plan C6, G19; ui-spec 6.5). Opt-in: renders only
-- while snapshot.survivalExtensions.rescue exists (RescueExtension is active for the pack).
--   * Down: the world desaturates to a lilac-grey grade, "You're down" sits top-centre and a row of
--     horizontal cards (rift / camp / flare, or one "Get up" card in safe roles) sits lower-centre.
--   * Flares: other players see a world marker over each live flare in range, a chat line, and a
--     "Help up" button when close enough; the server validates every revive.
-- Strings are rsc.* rows of the pack locale table (games/robango-island/locale/strings.csv).
local PackLocale = require("./PackLocale")

local M = {}
M.CHOOSE = "survival-coop:rescue-choose"
M.REVIVE = "survival-coop:rescue-revive"

local STRINGS: { [string]: { string } } = PackLocale.rows({}, { "rsc." })
M.KEYS = {
	"title",
	"rift",
	"rift_line",
	"camp",
	"camp_line",
	"rescue",
	"rescue_line",
	"getup",
	"getup_line",
	"waiting",
	"flare_chat",
	"flare_marker",
	"help",
	"help_far",
	"failed",
	"too_far",
	"expired",
	"lost_owner",
}
--- World label text for a dropped bundle; `owner` is the HudShell drop key ("owner:<name>").
function M.dropLabel(locale: string, key: string): string?
	local owner = string.match(key, "^owner:(.+)$")
	return if owner then M.text(locale, "lost_owner", owner) else nil
end
local LABELS = { rift = "rift", camp = "camp", rescue = "rescue", ["get-up"] = "getup" }
local ICONS = { rift = "death.rift", camp = "death.camp", rescue = "death.rescue", ["get-up"] = "death.camp" }
local REFUSALS = { TOO_FAR = "too_far", REQUEST_EXPIRED = "expired", NO_REQUEST = "expired" }

function M.text(locale: string, key: string, ...: any): string
	local entry = STRINGS[key]
	if entry == nil then
		return key
	end
	local value = if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
	return if select("#", ...) > 0 then string.format(value, ...) else value
end

function M.refusal(locale: string, reason: string?): string
	return M.text(locale, REFUSALS[reason or ""] or "failed")
end

--- Pure view model for the down screen, or nil when the actor is up.
function M.model(locale: string, state: any): any
	if type(state) ~= "table" or state.down ~= true then
		return nil
	end
	local cards = {}
	for _, option in state.options or {} do
		local key = LABELS[option]
		if key then
			table.insert(cards, {
				option = option,
				icon = ICONS[option],
				title = M.text(locale, key),
				line = M.text(locale, key .. "_line"),
				active = state.choice == option,
			})
		end
	end
	local waiting = if (state.waitingMillis or 0) > 0
		then M.text(locale, "waiting", math.ceil(state.waitingMillis / 1000))
		else nil
	return { title = M.text(locale, "title"), cards = cards, waiting = waiting }
end

--- Chat line for a flare (map X, Z rounded like the HUD coordinates).
function M.flareLine(locale: string, flare: any): string
	return M.text(locale, "flare_chat", flare.name, flare.x, flare.z)
end

--- Flares that are new since `seen` (by id); updates `seen` to the live set.
function M.newFlares(seen: { [string]: boolean }, flares: { any }): { any }
	local fresh = {}
	local live: { [string]: boolean } = {}
	for _, flare in flares do
		live[flare.id] = true
		if not seen[flare.id] then
			table.insert(fresh, flare)
		end
	end
	table.clear(seen)
	for id in live do
		seen[id] = true
	end
	return fresh
end

local function rgb(hex: number): Color3
	return Color3.fromRGB(hex // 65536, (hex // 256) % 256, hex % 256)
end

function M.factory(ctx: any): { destroy: () -> () }?
	local locale = ctx.locale
	local players = game:GetService("Players")
	local lighting = game:GetService("Lighting")
	local player = players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeDownPanel", false, 40, false
	gui.IgnoreGuiInset, gui.ZIndexBehavior = true, Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	local shade = Instance.new("Frame")
	shade.Name, shade.Size, shade.BorderSizePixel = "Shade", UDim2.fromScale(1, 1), 0
	shade.BackgroundColor3, shade.BackgroundTransparency, shade.Parent = rgb(0x4B4760), 0.55, gui
	local title = Instance.new("TextLabel")
	title.Name, title.BackgroundTransparency, title.AnchorPoint = "DownTitle", 1, Vector2.new(0.5, 0)
	title.Position, title.Size = UDim2.fromScale(0.5, 0.12), UDim2.fromScale(0.8, 0.09)
	title.Font, title.TextScaled, title.TextColor3 = Enum.Font.BuilderSansBold, true, rgb(0xEDE6D6)
	title.Parent = gui
	local status = Instance.new("TextLabel")
	status.Name, status.BackgroundTransparency, status.AnchorPoint = "DownStatus", 1, Vector2.new(0.5, 0)
	status.Position, status.Size = UDim2.fromScale(0.5, 0.22), UDim2.fromScale(0.8, 0.05)
	status.Font, status.TextScaled, status.TextColor3 = Enum.Font.BuilderSans, true, rgb(0xA9D3CC)
	status.Text, status.Parent = "", gui
	local row = Instance.new("Frame")
	row.Name, row.BackgroundTransparency, row.AnchorPoint = "DownCards", 1, Vector2.new(0.5, 1)
	row.Position, row.Size = UDim2.fromScale(0.5, 0.9), UDim2.fromScale(0.96, 0.3)
	row.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection, layout.HorizontalAlignment = Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Center
	layout.Padding, layout.SortOrder, layout.Parent = UDim.new(0.02, 0), Enum.SortOrder.LayoutOrder, row
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name, grade.Saturation, grade.TintColor, grade.Enabled = "ForgeDownGrade", -0.8, rgb(0xD8D2E6), false
	grade.Parent = lighting
	local markers = Instance.new("Folder")
	markers.Name, markers.Parent = "ForgeFlareMarkers", player.PlayerGui
	local cards: { any } = {}
	local boards: { [string]: any } = {}
	local seen: { [string]: boolean } = {}
	local shownDown = false
	local function choose(option: string)
		task.spawn(function()
			local result = ctx.send(M.CHOOSE, { option })
			if not result.ok then
				status.Text = M.refusal(locale, result.reason)
			end
		end)
	end
	local function card(index: number): any
		local existing = cards[index]
		if existing then
			return existing
		end
		local button = Instance.new("TextButton")
		button.Name, button.Text, button.AutoButtonColor = "DownCard", "", true
		button.Size, button.SizeConstraint = UDim2.fromScale(1.2, 1), Enum.SizeConstraint.RelativeYY
		button.BackgroundColor3, button.LayoutOrder, button.Parent = rgb(0x163735), index, row
		local corner = Instance.new("UICorner")
		corner.CornerRadius, corner.Parent = UDim.new(0.14, 0), button
		local rim = Instance.new("UIStroke")
		rim.Name, rim.Color, rim.Thickness, rim.Parent = "Rim", rgb(0x8A7560), 3, button
		local glyph = Instance.new("TextLabel")
		glyph.Name, glyph.BackgroundTransparency, glyph.Position = "Icon", 1, UDim2.fromScale(0.05, 0.06)
		glyph.Size, glyph.Font, glyph.TextScaled = UDim2.fromScale(0.9, 0.3), Enum.Font.BuilderSansBold, true
		glyph.TextColor3, glyph.Parent = rgb(0xC99A3B), button
		local name = Instance.new("TextLabel")
		name.Name, name.BackgroundTransparency, name.Position = "Title", 1, UDim2.fromScale(0.06, 0.4)
		name.Size, name.Font, name.TextScaled = UDim2.fromScale(0.88, 0.2), Enum.Font.BuilderSansBold, true
		name.TextColor3, name.Parent = rgb(0xEDE6D6), button
		local line = Instance.new("TextLabel")
		line.Name, line.BackgroundTransparency, line.Position = "Line", 1, UDim2.fromScale(0.06, 0.62)
		line.Size, line.Font, line.TextWrapped = UDim2.fromScale(0.88, 0.34), Enum.Font.BuilderSans, true
		line.TextScaled, line.TextColor3, line.Parent = true, rgb(0xCFC4AD), button
		local entry = { button = button, icon = glyph, title = name, line = line, rim = rim, option = "" }
		button.Activated:Connect(function()
			choose(entry.option)
		end)
		cards[index] = entry
		return entry
	end
	local function marker(flare: any): any
		local board = boards[flare.id]
		if not board then
			board = Instance.new("BillboardGui")
			board.Name, board.Size, board.AlwaysOnTop = "FlareMarker", UDim2.fromOffset(200, 72), true
			board.LightInfluence, board.StudsOffsetWorldSpace, board.Parent = 0, Vector3.new(0, 5, 0), markers
			local label = Instance.new("TextLabel")
			label.Name, label.Size, label.BackgroundColor3 = "Text", UDim2.new(1, 0, 0, 28), rgb(0x1B2224)
			label.BackgroundTransparency, label.TextColor3 = 0.4, rgb(0xC99A3B)
			label.Font, label.TextSize, label.Parent = Enum.Font.BuilderSansBold, 15, board
			local help = Instance.new("TextButton")
			help.Name, help.Position, help.Size = "Help", UDim2.fromOffset(30, 34), UDim2.fromOffset(140, 34)
			help.BackgroundColor3, help.TextColor3 = rgb(0x5FA8A0), rgb(0x1B2224)
			help.Font, help.TextSize, help.Parent = Enum.Font.BuilderSansBold, 15, board
			board.Active = true
			local id = flare.id
			help.Activated:Connect(function()
				task.spawn(function()
					local result = ctx.send(M.REVIVE, { id })
					if not result.ok then
						help.Text = M.refusal(locale, result.reason)
					end
				end)
			end)
			boards[flare.id] = board
		end
		return board
	end
	local function chat(line: string)
		pcall(function()
			local channels = game:GetService("TextChatService"):FindFirstChild("TextChannels")
			local general = channels and channels:FindFirstChild("RBXGeneral")
			if general then
				general:DisplaySystemMessage(line)
			end
		end)
	end
	local function render(snapshot: { [string]: any })
		local state = snapshot.rescue
		local view = M.model(locale, state)
		gui.Enabled, grade.Enabled = view ~= nil, view ~= nil
		if view then
			if not shownDown then
				status.Text = ""
			end
			title.Text = view.title
			if view.waiting then
				status.Text = view.waiting
			end
			for index, entry in view.cards do
				local item = card(index)
				item.option, item.button.Visible = entry.option, true
				item.title.Text, item.line.Text = entry.title, entry.line
				item.icon.Text = if entry.option == "rescue"
					then "( ! )"
					elseif entry.option == "rift" then "( o )"
					else "/\\"
				item.button:SetAttribute("ForgeIcon", entry.icon)
				item.rim.Color = if entry.active then rgb(0x5FA8A0) else rgb(0x8A7560)
			end
			for index = #view.cards + 1, #cards do
				cards[index].button.Visible = false
			end
		end
		shownDown = view ~= nil
		local flares = if type(state) == "table" and type(state.flares) == "table" then state.flares else {}
		for _, flare in M.newFlares(seen, flares) do
			chat(M.flareLine(locale, flare))
		end
		for id, board in boards do
			if not seen[id] then
				board:Destroy()
				boards[id] = nil
			end
		end
		for _, flare in flares do
			local board = marker(flare)
			local other = players:GetPlayerByUserId(tonumber(flare.id) or 0)
			local body = other and other.Character
			local anchor = body and body:FindFirstChild("HumanoidRootPart")
			board.Adornee = anchor
			board.Enabled = anchor ~= nil
			local label = board:FindFirstChild("Text") :: any
			label.Text = M.text(locale, "flare_marker", flare.name, math.ceil(flare.remainingMillis / 1000))
			local help = board:FindFirstChild("Help") :: any
			help.Visible = view == nil
			help.Text = M.text(locale, if flare.reachable then "help" else "help_far")
		end
	end
	local unsubscribe = ctx.onSnapshot(render)
	return {
		destroy = function()
			unsubscribe()
			grade:Destroy()
			markers:Destroy()
			gui:Destroy()
		end,
	}
end

return M
