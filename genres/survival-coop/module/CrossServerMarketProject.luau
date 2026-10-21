--!strict
-- Project contributions and rewards belong to a single durable project record.
-- The caller escrows real inputs before recording each immutable contribution;
-- claim delivery uses the same deterministic id in the durable claim port.
local Ledger = require("../../../core/domain/command/Ledger")
local M = {}
function M.complete(project: any, rewards: { [string]: number }): any
	if project.completed then
		assert(project.rewardBinding == Ledger.canonical(rewards), "PROJECT_CONFLICT")
		return project
	end
	local actors = {}
	for actor, contribution in project.contributions do
		assert(contribution.escrowCommitted == true and contribution.units > 0, "PROJECT_ESCROW_REQUIRED")
		table.insert(actors, actor)
	end
	table.sort(actors)
	assert(#actors == 2 and actors[1] ~= actors[2], "PROJECT_TWO_CONTRIBUTORS")
	local total = project.contributions[actors[1]].units + project.contributions[actors[2]].units
	local claims = {}
	for index, actor in actors do
		local claim = {}
		for catalogId, quantity in rewards do
			assert(quantity % 1 == 0 and quantity >= 0, "PROJECT_REWARD_INTEGER")
			local first = math.floor(quantity * project.contributions[actors[1]].units / total)
			claim[catalogId] = if index == 1 then first else quantity - first
		end
		claims[project.id .. ":" .. actor] = { owner = actor, items = claim }
	end
	local result = table.clone(project)
	result.completed = true
	result.rewardBinding = Ledger.canonical(rewards)
	result.claims = claims
	return result
end
return M
