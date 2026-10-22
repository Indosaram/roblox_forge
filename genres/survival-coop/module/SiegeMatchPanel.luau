--!strict
-- ui.siege-match: opens on match arrival (an active outpost match listing this actor).
-- Teams, central control progress toward captureSeconds, the timer and ownership; Leave
-- requires an explicit second confirmation and sends survival-coop:outpost-leave.
local Sheet = require("./SocialSheet")
local L = require("./SocialLocale")
local M = {}

function M.active(outpost: any, actor: string): (string?, any?)
	local ids = {}
	for id in (outpost and outpost.matches) or {} do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local match = outpost.matches[id]
		if match.status == "active" and match.actors[actor] then
			return id, match
		end
	end
	return nil, nil
end

-- state = { outpost, policy, actorId, now, confirming, status }
function M.rows(locale: string, state: any, act: any): { any }
	local matchId, match = M.active(state.outpost, state.actorId)
	if not match then
		return { { text = L.text(locale, "siege.empty") } }
	end
	local rows: { any } = {}
	for index, team in match.teams do
		table.insert(rows, {
			text = L.text(
				locale,
				"match.team",
				team.clanId,
				#team.actors,
				math.min(state.policy.captureSeconds, math.floor(match.score[index])),
				state.policy.captureSeconds
			),
		})
	end
	table.insert(rows, { text = L.text(locale, "match.timer", L.duration(match.finishAt - state.now)) })
	local outpost = state.outpost
	if outpost.owner ~= "" and state.now < outpost.expiresAt then
		table.insert(rows, {
			text = L.text(locale, "siege.owner", outpost.owner, L.duration(outpost.expiresAt - state.now)),
		})
	else
		table.insert(rows, { text = L.text(locale, "siege.no_owner") })
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	if state.confirming then
		table.insert(rows, { text = L.text(locale, "match.confirm") })
		table.insert(rows, {
			text = L.text(locale, "match.leave_yes"),
			onClick = function()
				act.leave(matchId)
			end,
		})
		table.insert(rows, { text = L.text(locale, "match.stay"), onClick = act.stay })
	else
		table.insert(rows, { text = L.text(locale, "match.leave"), onClick = act.ask })
	end
	return rows
end

function M.factory(ctx: any): any
	local confirming, status = false, nil :: string?
	local seen: string? = nil
	local panel: any
	panel = Sheet.mount(ctx, {
		id = "siege-match",
		name = "SiegeMatch",
		title = L.text(ctx.locale, "match.title"),
		order = 9,
		select = function(extensions: any): any
			return { outpost = extensions.outpost }
		end,
		-- Match arrival: open once per match the actor is part of.
		autoOpen = function(state: any): boolean
			local id = M.active(state.outpost, ctx.actorId)
			if id and id ~= seen then
				seen = id
				return true
			end
			return false
		end,
		rows = function(state: any): { any }
			return M.rows(ctx.locale, {
				outpost = state and state.outpost,
				policy = ctx.outpostPolicy,
				actorId = ctx.actorId,
				now = ctx.serverNow(),
				confirming = confirming,
				status = status,
			}, {
				ask = function()
					confirming = true
					panel.render()
				end,
				stay = function()
					confirming = false
					panel.render()
				end,
				leave = function(matchId: string)
					local result =
						ctx.send("survival-coop:outpost-leave", { "rw.team-outpost", { matchId = matchId } :: any })
					confirming = false
					status = if result.ok then nil else L.refusal(ctx.locale, result.reason)
					if result.ok then
						panel.close()
					end
					panel.render()
				end,
			})
		end,
	})
	return panel
end

return M
