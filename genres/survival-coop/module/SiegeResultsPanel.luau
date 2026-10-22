--!strict
-- ui.siege-results: opens when a match this actor's clan fought settles. Win or tie, the
-- 24-hour ownership, whether the previous owner's ownership was retained (tie keeps its
-- original expiry) or ended, and the advanced-capture research consequence.
local Sheet = require("./SocialSheet")
local L = require("./SocialLocale")
local M = {}

function M.latest(outpost: any, clanId: string): (string?, any?)
	local best, bestMatch = nil, nil
	for id, match in (outpost and outpost.matches) or {} do
		if match.status == "settled" then
			for _, team in match.teams do
				if team.clanId == clanId and (best == nil or match.finishAt > bestMatch.finishAt) then
					best, bestMatch = id, match
				end
			end
		end
	end
	return best, bestMatch
end

-- state = { outpost, clan, clanId, now }
function M.rows(locale: string, state: any, act: any): { any }
	local _, match = M.latest(state.outpost, state.clanId)
	if not match then
		return { { text = L.text(locale, "siege.empty") } }
	end
	local outpost = state.outpost
	local rows: { any } = {}
	if match.winner ~= "" then
		table.insert(rows, { text = L.text(locale, "result.win", match.winner) })
		if outpost.owner == match.winner and state.now < outpost.expiresAt then
			table.insert(rows, { text = L.text(locale, "result.own", L.duration(outpost.expiresAt - state.now)) })
		end
	else
		table.insert(rows, { text = L.text(locale, "result.tie") })
	end
	local previous = match.previousOwner or ""
	if previous == "" then
		table.insert(rows, { text = L.text(locale, "result.prev_none") })
	elseif match.winner == "" or match.winner == previous then
		table.insert(rows, {
			text = L.text(
				locale,
				"result.prev_kept",
				previous,
				L.duration((match.previousExpiresAt or outpost.expiresAt) - state.now)
			),
		})
	else
		table.insert(rows, { text = L.text(locale, "result.prev_ended", previous) })
	end
	local research = state.clan ~= nil and state.clan.research ~= nil and state.clan.research["advanced-capture"]
	local owns = outpost.owner == state.clanId and state.now < outpost.expiresAt
	table.insert(
		rows,
		{ text = L.text(locale, if research and owns then "result.research_on" else "result.research_off") }
	)
	table.insert(rows, { text = L.text(locale, "result.continue"), onClick = act.close })
	return rows
end

function M.factory(ctx: any): any
	local seen: string? = nil
	local panel: any
	panel = Sheet.mount(ctx, {
		id = "siege-results",
		name = "SiegeResults",
		title = L.text(ctx.locale, "result.title"),
		order = 10,
		select = function(extensions: any): any
			return {
				outpost = extensions.outpost,
				clan = extensions.clan,
				clanId = if extensions.clan then extensions.clan.clanId else "",
			}
		end,
		autoOpen = function(state: any): boolean
			local id = M.latest(state.outpost, state.clanId)
			if id and seen ~= nil and id ~= seen then
				seen = id
				return true
			end
			-- The first snapshot only records history; it never replays an old result.
			seen = seen or id or ""
			return false
		end,
		rows = function(state: any): { any }
			local view = table.clone(state or {})
			view.now = ctx.serverNow()
			return M.rows(ctx.locale, view, {
				close = function()
					panel.close()
				end,
			})
		end,
	})
	return panel
end

return M
