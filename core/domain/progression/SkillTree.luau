--!strict
-- Purchased specializations are separate from legacy tool-capped mastery.
-- Only server-confirmed action receipts may enter award; clocks are explicit.
local M = {}

export type Mastery = { level: number, xp: number }
export type State = {
	level: number,
	xp: number?,
	sp: number,
	paid: { [string]: number },
	mastery: { [string]: Mastery },
	receipts: { [string]: boolean },
	version: number,
}
export type Policy = {
	maxLevel: number,
	spPerLevel: number,
	maxMastery: number,
	actionXP: number,
	xpBase: number,
	xpStep: number,
}

function M.copy(state: State): State
	local result = table.clone(state)
	result.paid = table.clone(state.paid)
	result.receipts = table.clone(state.receipts)
	result.mastery = {}
	for id, mastery in state.mastery do
		result.mastery[id] = table.clone(mastery)
	end
	return result
end

function M.new(content: any, policy: Policy): State
	local state: State = { level = 1, sp = policy.spPerLevel, paid = {}, mastery = {}, receipts = {}, version = 0 }
	for _, category in content.skillCategories do
		state.mastery[category.id] = { level = 0, xp = 0 }
	end
	return state
end

function M.level(state: State, policy: Policy, level: number): State
	assert(level % 1 == 0 and level >= state.level and level <= policy.maxLevel, "INVALID_CHARACTER_LEVEL")
	local result = M.copy(state)
	result.sp += (level - state.level) * policy.spPerLevel
	result.level = level
	result.version += 1
	return result
end

function M.award(state: State, policy: Policy, category: string, receipt: string): State
	assert(state.mastery[category] ~= nil and #receipt > 0, "INVALID_PROFICIENCY_EVENT")
	if state.receipts[receipt] then
		return state
	end
	local result = M.copy(state)
	result.receipts[receipt] = true
	-- Character experience is earned by the same finalized action as mastery.
	-- Older saves start at zero remaining XP; replayed receipts award neither.
	local characterXP = (result.xp or 0) + policy.actionXP
	while result.level < policy.maxLevel do
		local required = policy.xpBase + policy.xpStep * result.level
		if characterXP < required then
			break
		end
		characterXP -= required
		result.sp += policy.spPerLevel
		result.level += 1
	end
	result.xp = characterXP
	local mastery = result.mastery[category]
	if mastery.level == 0 then
		mastery.level = 1
	else
		mastery.xp += policy.actionXP
		while mastery.level < policy.maxMastery do
			local required = policy.xpBase + policy.xpStep * mastery.level
			if mastery.xp < required then
				break
			end
			mastery.xp -= required
			mastery.level += 1
		end
	end
	if mastery.level == policy.maxMastery then
		mastery.xp = 0
	end
	result.version += 1
	return result
end

function M.learn(content: any, state: State, id: string): (State?, string?)
	local node: any = nil
	for _, row in content.skillNodes do
		if row.id == id then
			node = row
			break
		end
	end
	if not node then
		return nil, "UNKNOWN_NODE"
	elseif state.paid[id] then
		return nil, "ALREADY_LEARNED"
	elseif state.mastery[node.category].level < node.proficiency then
		return nil, "PROFICIENCY_GATE"
	elseif state.sp < node.cost then
		return nil, "INSUFFICIENT_SP"
	end
	for _, prerequisite in node.prerequisites do
		if not state.paid[prerequisite] then
			return nil, "PREREQUISITE_GATE"
		end
	end
	local result = M.copy(state)
	result.sp -= node.cost
	result.paid[id] = node.cost
	result.version += 1
	return result, nil
end

-- A quote is versioned: a concurrent purchase cannot silently change its refund.
function M.quote(state: State): { version: number, refund: number }
	local refund = 0
	for _, cost in state.paid do
		refund += cost
	end
	return { version = state.version, refund = refund }
end

function M.reset(state: State, version: number, inCombat: boolean, activeJobs: number): (State?, string?)
	if state.version ~= version then
		return nil, "STALE_QUOTE"
	elseif inCombat or activeJobs > 0 then
		return nil, "RESET_BUSY"
	end
	local result = M.copy(state)
	result.sp += M.quote(state).refund
	result.paid = {}
	result.version += 1
	return result, nil
end

function M.gate(state: State, gate: any): string?
	if state.level < (gate.characterLevel or 1) then
		return "CHARACTER_LEVEL_GATE"
	end
	for _, id in gate.skillNodes or {} do
		if not state.paid[id] then
			return "SKILL_GATE"
		end
	end
	return nil
end

return M
