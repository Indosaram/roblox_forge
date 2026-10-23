--!strict
-- ui.organizations: the four mission organizations (Wayfarers, Scholars, Wardens,
-- Traders), trust rank 0-5 where rank r -> r+1 costs 100*(r+1) reputation, the progress to the
-- next rank, and which mission types credit each one. Reads the archipelago snapshot's
-- `reputation` ledger (MissionRewards settles +20 per eligible objective); display only.
local Sheet = require("./SocialSheet")
local L = require("./SocialLocale")
local M = {}

M.IDS = { "wayfarers", "scholars", "wardens", "traders" }
M.MAX_RANK = 5

--- Rank for a reputation total: rank, reputation into the current rank, cost of the next rank.
function M.rank(total: number): { rank: number, into: number, next: number? }
	local rank, left = 0, math.max(0, math.floor(total or 0))
	while rank < M.MAX_RANK and left >= 100 * (rank + 1) do
		left -= 100 * (rank + 1)
		rank += 1
	end
	return { rank = rank, into = left, next = if rank < M.MAX_RANK then 100 * (rank + 1) else nil }
end

function M.rows(locale: string, reputation: { [string]: number }?): { any }
	local rows: { any } = { { text = L.text(locale, "org.intro") } }
	for _, id in M.IDS do
		local row = M.rank((reputation or {})[id] or 0)
		local progress = if row.next then L.text(locale, "org.next", row.into, row.next) else L.text(locale, "org.max")
		table.insert(rows, {
			text = L.text(locale, "org." .. id)
				.. "\n"
				.. L.text(locale, "org.rank", row.rank)
				.. " · "
				.. progress
				.. "\n"
				.. L.text(locale, "org." .. id .. ".missions"),
		})
	end
	return rows
end

function M.factory(ctx: any): any
	local panel: any
	panel = Sheet.mount(ctx, {
		id = "organizations",
		name = "Organizations",
		title = L.text(ctx.locale, "org.title"),
		order = 16,
		select = function(extensions: any): any
			return extensions.archipelago and extensions.archipelago.reputation
		end,
		rows = function(reputation: any): { any }
			local rows = M.rows(ctx.locale, reputation)
			table.insert(rows, {
				text = L.text(ctx.locale, "dialogue.bye"),
				onClick = function()
					panel.close()
				end,
			})
			return rows
		end,
	})
	return panel
end

return M
