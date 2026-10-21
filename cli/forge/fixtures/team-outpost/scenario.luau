--!strict
local Governance = require("../clan-governance/scenario")
local M = {}
M.new = Governance.new
M.operations = {
	outpost_command = function(ctx: any, step: any): string?
		ctx.fixture.joinAll()
		ctx.fixture.advance(step.seconds or 0, step.occupants or {})
		local result =
			ctx.fixture.command(ctx.playerOf(step), "outpost", step.action, { matchId = step.match }, step.request)
		ctx.results[ctx.playerOf(step)] = result
		return if result.ok == (step.expect == "refused")
			then "unexpected outpost result: " .. tostring(result.reason)
			else nil
	end,
	outpost_check = function(ctx: any, step: any): string?
		local state = ctx.fixture.snapshot().outpost
		local match = state.matches[step.match]
		if step.check == "contested" then
			return if match.score[1] == 0 and match.score[2] == 0 then nil else "contested score advanced"
		end
		return if match.status == "settled"
				and match.winner == "alpha"
				and state.owner == "alpha"
				and state.revision == 3
			then nil
			else "capture settlement changed"
	end,
	outpost_reconnect = Governance.operations.clan_reconnect,
}
return M
