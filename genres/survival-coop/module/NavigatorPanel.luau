--!strict
local Text = require("./MusicText")
local Sheet = require("./MusicSheet")
local env: any = getfenv()
local game: any = env.game
local Instance: any = env.Instance
local Enum: any = env.Enum
local UDim2: any = env.UDim2
local Color3: any = env.Color3
local M = {}

M.ROWS = {
	{ "nav_survival", "bag" },
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
	{ "nav_inbox", false, "lock_inbox" },
	{ "nav_settings", "audio" },
} :: { { any } }

function M.model(locale: string, availability: (string) -> (boolean, boolean, string?)): { any }
	local rows = {}
	for _, row in M.ROWS do
		local label = Text.text(locale, row[1])
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
	local buttons: { any } = {}
	local function render()
		for _, button in buttons do
			button:Destroy()
		end
		table.clear(buttons)
		for _, row in M.model(ctx.locale, ctx.availability) do
			local button = view.button("Nav-" .. tostring(row.id or row.text), row.text, function()
				local reason = M.press(row, ctx.open)
				status.Text, status.Visible = reason or "", reason ~= nil
			end)
			button.BackgroundTransparency = if row.open then 0 else 0.45
			button.TextWrapped = true
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
