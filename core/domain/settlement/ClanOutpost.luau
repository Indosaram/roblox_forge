--!strict
local Data = require("../genre/SerializedData")
local M = {}

function M.new(id: string, _owner: string): any
	return { schemaVersion = 1, revision = 0, outpostId = id, owner = "", expiresAt = 0, matches = {}, receipts = {} }
end

function M.apply(
	state: any,
	actor: string,
	operation: string,
	args: any,
	receipt: string,
	now: number,
	ctx: any
): (any?, string?)
	if operation ~= "queue" and not ctx.server then
		return nil, "SERVER_ONLY"
	end
	if state.receipts[receipt] then
		return Data.clone(state), nil
	end
	local out = Data.clone(state)
	if operation == "queue" then
		if ctx.role ~= "team-outpost" or not ctx.clanId or not ctx.eligible(actor, ctx.clanId) then
			return nil, "NOT_TEAM_MEMBER"
		end
		for _, match in state.matches do
			if match.status == "active" and match.actors[actor] then
				return nil, "MATCH_ACTIVE"
			end
		end
		out.queue = out.queue or {}
		out.queue[actor] = if args.enabled then ctx.clanId else nil
	elseif operation == "start" then
		if ctx.role ~= "team-outpost" then
			return nil, "NOT_TEAM_OUTPOST"
		end
		if state.matches[args.matchId] then
			return nil, "MATCH_EXISTS"
		end
		for _, match in state.matches do
			if match.status == "active" then
				return nil, "MATCH_ACTIVE"
			end
		end
		if type(args.matchId) ~= "string" or args.matchId == "" then
			return nil, "INVALID_MATCH"
		end
		local seen = {}
		local clans = {}
		local teams = ctx.teams
		for _, team in teams do
			if #team.actors < ctx.rules.minTeam or #team.actors > ctx.rules.maxTeam or clans[team.clanId] then
				return nil, "INVALID_TEAMS"
			end
			clans[team.clanId] = true
			for _, player in team.actors do
				if seen[player] or not ctx.eligible(player, team.clanId) or not ctx.optedIn(player) then
					return nil, "INVALID_PARTICIPANT"
				end
				seen[player] = team.clanId
			end
		end
		if #teams ~= 2 then
			return nil, "INVALID_TEAMS"
		end
		out.matches[args.matchId] = {
			status = "active",
			teams = Data.clone(teams),
			actors = seen,
			score = { 0, 0 },
			lastAt = now,
			finishAt = now + ctx.rules.matchSeconds,
			winner = "",
		}
		for player in seen do
			if out.queue then
				out.queue[player] = nil
			end
		end
	elseif operation == "advance" then
		local match = out.matches[args.matchId]
		if not match or match.status ~= "active" then
			return nil, "MATCH_SETTLED"
		end
		if now < match.lastAt then
			return nil, "STALE_CLOCK"
		end
		local elapsed = math.min(now, match.finishAt) - match.lastAt
		local occupying = {}
		for _, player in ctx.occupants do
			local clanId = match.actors[player]
			if clanId and ctx.eligible(player, clanId) then
				occupying[clanId] = true
			end
		end
		local count, controller = 0, ""
		for clanId in occupying do
			count += 1
			controller = clanId
		end
		if count == 1 then
			for index, team in match.teams do
				if team.clanId == controller then
					match.score[index] += elapsed
				end
			end
		end
		match.lastAt = math.min(now, match.finishAt)
		for index, score in match.score do
			if score >= ctx.rules.captureSeconds then
				match.winner = match.teams[index].clanId
			end
		end
		if match.winner ~= "" or now >= match.finishAt then
			match.status = "settled"
			if match.winner == "" and match.score[1] ~= match.score[2] then
				match.winner = match.teams[if match.score[1] > match.score[2] then 1 else 2].clanId
			end
			if match.winner ~= "" then
				out.owner = match.winner
				-- Settlement belongs to the first winning tick, not a delayed callback.
				local settledAt = math.min(now, match.finishAt)
				if count == 1 then
					for index, team in match.teams do
						if team.clanId == controller and match.score[index] >= ctx.rules.captureSeconds then
							settledAt -= match.score[index] - ctx.rules.captureSeconds
						end
					end
				end
				out.expiresAt = settledAt + ctx.rules.ownershipSeconds
			end
		end
	else
		return nil, "UNKNOWN_ACTION"
	end
	out.revision += 1
	out.receipts[receipt] = actor
	return out, nil
end

return M
