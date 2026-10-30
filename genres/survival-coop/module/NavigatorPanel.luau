--!strict
local Text = require("./MusicText")
local ScreenText = require("./ScreenText")
local Sheet = require("./MusicSheet")
local env: any = getfenv()
local game: any = env.game
local Instance: any = env.Instance
local Enum: any = env.Enum
local UDim2: any = env.UDim2
local UDim: any = env.UDim
local Color3: any = env.Color3
local M = {}

M.ROWS = {
	{ "nav_survival", "survival" },
	{ "nav_craft", "craft" },
	{ "nav_build", "build" },
	{ "nav_skills", "skills" },
	{ "nav_journal", "journal" },
	{ "nav_explore", "explore" },
	{ "nav_social", "camp" },
	{ "nav_market", "market" },
	{ "nav_music", "music" },
	{ "nav_import", "score-import" },
	{ "nav_share", "score-share" },
	{ "nav_ensemble", "ensemble-lobby" },
	{ "nav_inbox", "inbox" },
	{ "scr.nav.tracker", "recipe-tracker" },
	{ "scr.nav.library", "score-library" },
	{ "scr.nav.players", "players" },
	{ "scr.nav.treasury", "clan-treasury" },
	{ "scr.nav.research", "clan-research" },
	{ "scr.nav.territory", "territory" },
	{ "scr.nav.manage", "build-manage" },
	{ "scr.nav.arrival", "arrival" },
	{ "scr.nav.jobs", "jobs" },
	{ "scr.nav.roles", "clan-roles" },
	{ "nav_settings", "audio" },
} :: { { any } }

--- `hidden` (optional): rows the pack keeps off in this mode, by label key or destination id
--- (single-player mode: screens that only act on other players).
function M.model(
	locale: string,
	availability: (string) -> (boolean, boolean, string?),
	hidden: ((string, string?) -> boolean)?
): { any }
	local rows = {}
	for _, row in M.ROWS do
		if hidden and hidden(row[1], row[2]) then
			continue
		end
		local label = if ScreenText.has(row[1]) then ScreenText.text(locale, row[1]) else Text.text(locale, row[1])
		local id = row[2]
		local open, reason = false, nil
		if id then
			local known, available, why = availability(id)
			open = known and available
			if not known then
				reason = Text.text(locale, "lock_unknown")
			elseif not available then
				reason = if why then Text.text(locale, why) else Text.text(locale, "lock_unavailable")
			end
		else
			reason = Text.text(locale, row[3])
		end
		table.insert(rows, {
			key = row[1],
			id = id,
			open = open,
			reason = reason,
			text = if open then label else Text.text(locale, "nav_locked", label, reason :: string),
		})
	end
	return rows
end

function M.press(row: any, open: (string) -> boolean): string?
	if row.open and open(row.id) then
		return nil
	end
	return row.reason
end

function M.factory(ctx: any): any
	if not ctx.dock or not ctx.open or not ctx.availability then
		return nil
	end
	local view = Sheet.mount(ctx, "navigator", "nav_title", false, 0)
	local status = view.label("NavigatorStatus")
	status.Visible = false
	-- U7: with pack icons the destinations are an icon tile grid (R15-5 main menu), 2-3 columns.
	local grid: any = nil
	if ctx.icons then
		grid = Instance.new("Frame")
		grid.Name, grid.BackgroundTransparency, grid.LayoutOrder = "NavGrid", 1, 100
		grid.Size, grid.AutomaticSize = UDim2.new(1, -6, 0, 0), Enum.AutomaticSize.Y
		local cells = Instance.new("UIGridLayout")
		cells.CellPadding, cells.SortOrder, cells.Parent = UDim2.fromOffset(8, 8), Enum.SortOrder.LayoutOrder, grid
		local function fit()
			local width = view.sheet.scroll.AbsoluteSize.X - 30
			local columns = math.clamp(math.floor(width / 200), 2, 3)
			cells.CellSize = UDim2.new(1 / columns, -8, 0, 56)
		end
		view.sheet.scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
		fit()
		grid.Parent = view.sheet.scroll
	end
	local buttons: { any } = {}
	local function render()
		for _, button in buttons do
			button:Destroy()
		end
		table.clear(buttons)
		local function hidden(key: string, id: string?): boolean
			return (ctx.navHidden ~= nil and ctx.navHidden[key] ~= nil)
				or (id ~= nil and ctx.held ~= nil and ctx.held[id] ~= nil)
		end
		for index, row in M.model(ctx.locale, ctx.availability, hidden) do
			local button = view.button("Nav-" .. tostring(row.id or row.text), row.text, function()
				local reason = M.press(row, ctx.open)
				status.Text, status.Visible = reason or "", reason ~= nil
			end)
			button.BackgroundTransparency = if row.open then 0 else 0.45
			button.TextWrapped = true
			if grid then
				local Panels = require("./ExtensionPanels")
				button.Parent, button.LayoutOrder = grid, if row.open then index else 100 + index
				button.TextXAlignment = Enum.TextXAlignment.Left
				local pad = Instance.new("UIPadding")
				pad.PaddingLeft, pad.PaddingRight, pad.Parent = UDim.new(0, 50), UDim.new(0, 6), button
				local badge = Panels.mountIcon(
					button,
					Panels.iconId(row.id or "inbox", ctx.icons),
					ctx.icons,
					UDim2.fromOffset(36, 36),
					UDim2.new(0, -42, 0.5, -18),
					"NavIcon",
					{ r = 237, g = 230, b = 214 }
				)
				local asset = badge and badge:FindFirstChild("Asset")
				if asset and not row.open then
					asset.ImageTransparency = 0.5
				end
				if not row.open then
					-- Locked: the name only; the reason shows in the status line on a tap.
					button.Text = ScreenText.has(row.key) and ScreenText.text(ctx.locale, row.key)
						or Text.text(ctx.locale, row.key)
					button:SetAttribute("ForgeNavLocked", row.text)
				end
			end
			table.insert(buttons, button)
		end
	end
	table.insert(view.opened, function()
		status.Visible = false
		render()
	end)
	return {
		destroy = function()
			view.gui:Destroy()
		end,
	}
end

return M
