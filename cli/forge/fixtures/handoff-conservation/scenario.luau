--!strict
-- Production camp ownership and transactions; all injected failures and
-- observations are declared by the native scenario, not reimplemented here.
local Camp = require("../camp-ladder/scenario")
local M = {}
local function handoff(ctx, step): string?
	local actor = ctx.playerOf(step)
	local methods = {
		prepare_handoff = ctx.session.prepareHandoff,
		resume_handoff = ctx.session.resumeHandoff,
		complete_handoff = ctx.session.completeHandoff,
	}
	local result = methods[step.op](actor)
	ctx.results[actor] = result
	if (step.expect == "refused") == result.ok then
		return "handoff unexpected result: " .. tostring(result.reason)
	end
	return nil
end
M.operations = { prepare_handoff = handoff, resume_handoff = handoff, complete_handoff = handoff }
function M.new(ctx)
	assert(ctx.scenario.genre == "survival-coop" and ctx.scenario.pack == "robango-island", "fixture pack binding")
	return Camp.new(ctx.packPath, ctx.backend, ctx.now)
end
return M
