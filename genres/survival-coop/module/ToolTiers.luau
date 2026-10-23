--!strict
-- Gather tool acceptance from content.toolPolicy. Without a policy (or for a tool outside
-- every family) a node accepts exactly its declared tool, as before.
local M = {}

local function rank(policy: any, item: string): (string?, number?)
	for _, family in if policy then policy.families else {} do
		for _, member in family.members do
			if member.item == item then
				return family.id, member.tier
			end
		end
	end
	return nil, nil
end

--- True when an owned `candidate` item satisfies a node that requires `required`.
function M.accepts(content: any, required: string, candidate: string): boolean
	if candidate == required then
		return true
	end
	local policy = content and content.toolPolicy
	local family, tier = rank(policy, required)
	local candidateFamily, candidateTier = rank(policy, candidate)
	return family ~= nil and family == candidateFamily and (candidateTier :: number) >= (tier :: number)
end

--- True when other tools in the same family can stand in for `required`.
function M.hasFamily(content: any, required: string): boolean
	return (rank(content and content.toolPolicy, required)) ~= nil
end

return M
