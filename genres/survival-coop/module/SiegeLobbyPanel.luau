--!strict
-- ui.siege-lobby: opt-in team outpost queue. Shows the 3-8 vs 3-8 roster per clan with
-- readiness, the rules (ten minutes, 180 control seconds) and current ownership; Join /
-- Leave queue send survival-coop:outpost-queue { enabled }.
local Sheet = require("./SocialSheet")
local L = require("./SocialLocale")
local M = {}

M.OUTPOST = "rw.team-outpost"

function M.roster(outpost: any, policy: any): { any }
	local byClan: { [string]: number } = {}
	for _, clanId in (outpost and outpost.queue) or {} do
		byClan[clanId] = (byClan[clanId] or 0) + 1
	end
	local rows = {}
	for clanId, count in byClan do
		table.insert(rows, { clanId = clanId, count = count, ready = count >= policy.minTeam })
	end
	table.sort(rows, function(a: any, b: any): boolean
		return a.clanId < b.clanId
	end)
	return rows
end

-- state = { outpost, policy, actorId, now, status }
function M.rows(locale: string, state: any, act: any): { any }
	local policy, outpost = state.policy, state.outpost or {}
	local rows: { any } = {
		{
			text = L.text(
				locale,
				"siege.rules",
				policy.minTeam,
				policy.maxTeam,
				policy.minTeam,
				policy.maxTeam,
				policy.matchSeconds // 60,
				policy.captureSeconds
			),
		},
	}
	if outpost.owner and outpost.owner ~= "" and state.now < (outpost.expiresAt or 0) then
		table.insert(rows, {
			text = L.text(locale, "siege.owner", outpost.owner, L.duration(outpost.expiresAt - state.now)),
		})
	else
		table.insert(rows, { text = L.text(locale, "siege.no_owner") })
	end
	local roster = M.roster(outpost, policy)
	if #roster == 0 then
		table.insert(rows, { text = L.text(locale, "siege.empty") })
	end
	for _, entry in roster do
		local readiness = if entry.ready
			then L.text(locale, "siege.ready")
			else L.text(locale, "siege.waiting", policy.minTeam - entry.count)
		table.insert(rows, { text = L.text(locale, "siege.roster", entry.clanId, entry.count, readiness) })
	end
	local queued = outpost.queue ~= nil and outpost.queue[state.actorId] ~= nil
	if queued then
		table.insert(rows, { text = L.text(locale, "siege.you_queued") })
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	table.insert(rows, {
		text = L.text(locale, if queued then "siege.leave_queue" else "siege.queue"),
		onClick = function()
			act.queue(not queued)
		end,
	})
	return rows
end

function M.factory(ctx: any): any
	local status: string? = nil
	local panel: any
	panel = Sheet.mount(ctx, {
		id = "outpost",
		name = "SiegeLobby",
		title = L.text(ctx.locale, "siege.title"),
		order = 8,
		select = function(extensions: any): any
			return { outpost = extensions.outpost }
		end,
		rows = function(state: any): { any }
			return M.rows(ctx.locale, {
				outpost = state and state.outpost,
				policy = ctx.outpostPolicy,
				actorId = ctx.actorId,
				now = ctx.serverNow(),
				status = status,
			}, {
				queue = function(enabled: boolean)
					local result = ctx.send("survival-coop:outpost-queue", { M.OUTPOST, { enabled = enabled } :: any })
					status = if result.ok then nil else L.refusal(ctx.locale, result.reason)
					panel.render()
				end,
			})
		end,
	})
	return panel
end

return M
