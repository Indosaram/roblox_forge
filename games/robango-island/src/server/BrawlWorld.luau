--!strict
-- Pack role candidate: renderer is injected so headless QA uses the same plan.
local M = {}
function M.plan(content: any): any
	local policy = assert(content.brawlPolicy, "BRAWL_POLICY_MISSING")
	local layout: any = nil
	for _, candidate in content.layouts do
		if candidate.id == policy.layout then
			layout = candidate
		end
	end
	assert(layout, "BRAWL_LAYOUT_MISSING")
	return { layout = layout, spawns = policy.spawns, capacity = policy.maximumPlayers, role = "brawl" }
end
function M.build(config: any): any
	assert(config.isServer(), "BRAWL_SERVER_ONLY")
	local plan = M.plan(config.content)
	config.render(plan)
	return plan
end
function M.live(content: any, source: any, wildlife: any, nowMillis: any): any
	local plan = M.plan(content)
	local world = source.renderRole(content, source, wildlife, nowMillis, plan.layout.id, source.seed)
	world.brawlPlan = plan
	return world
end
return M
