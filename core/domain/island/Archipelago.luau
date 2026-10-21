--!strict
-- Pure expedition state. Receipts enter only through the server extension's
-- verifier; client commands never carry completed-objective counts.
local Expedition = require("./Expedition")
local M = {}

local function definitions(content: any, layout: string): { any }
	local result = {}
	for _, stage in content.stages do
		if stage.layout == layout then
			table.insert(result, stage)
		end
	end
	assert(#result == 2, "archipelago requires two mission definitions per island")
	return result
end

function M.layout(state: any): string
	return state.templateId .. ".s" .. tostring(state.stage)
end

function M.admit(state: any, content: any, facts: any, now: number, entryBuffer: number): (boolean, string?)
	if now >= state.expiresAt then
		return false, "route_expired"
	end
	if now + entryBuffer >= state.expiresAt then
		return false, "expiry_imminent"
	end
	if state.status ~= "active" then
		return false, "expedition_inactive"
	end
	for _, definition in definitions(content, M.layout(state)) do
		if facts.level < (definition.gates.characterLevel or 1) then
			return false, "level_gate"
		end
		if facts.developmentRank < (definition.gates.developmentRank or 0) then
			return false, "development_gate"
		end
		for _, id in definition.gates.completed or {} do
			if not state.completed[id] then
				return false, "mission_gate"
			end
		end
	end
	if facts.instabilityAccess < state.index then
		return false, "instability_gate"
	end
	return true, nil
end

function M.open(content: any, options: any, facts: any, now: number): (any?, string?)
	local template = "rw.a" .. tostring(options.index)
	local island = Expedition.open({ routeId = options.id, templateId = template }, options.seed, now, options.ttl)
	local state: any = {
		id = options.id,
		actor = options.actor,
		revision = options.revision,
		index = options.index,
		templateId = template,
		seed = island.seed,
		delta = island.delta,
		expiresAt = island.expiresAt,
		stage = 1,
		status = "active",
		openedAt = now,
		completed = {},
		progress = {},
		receipts = {},
		questCargo = nil,
		treated = false,
		escortAtStart = true,
	}
	local ok, reason = M.admit(state, content, facts, now, options.entryBuffer)
	return if ok then state else nil, reason
end

-- The verifier resolves the authoritative operation receipt, including mineral
-- gates, consumed inputs, party contribution, survey holds and escort arrival.
function M.record(state: any, content: any, receipt: any, now: number): (boolean, string?)
	if now >= state.expiresAt then
		return false, "route_expired"
	end
	if state.status ~= "active" then
		return false, "expedition_inactive"
	end
	if receipt.actor ~= state.actor or receipt.expedition ~= state.id or receipt.revision ~= state.revision then
		return false, "receipt_scope"
	end
	local objective = nil
	for _, definition in definitions(content, M.layout(state)) do
		for _, candidate in definition.objectives do
			if candidate.id == receipt.objective then
				objective = candidate
			end
		end
	end
	if objective == nil or receipt.action ~= objective.action or receipt.target ~= objective.target then
		return false, "objective_mismatch"
	end
	if type(receipt.quantity) ~= "number" or receipt.quantity <= 0 or receipt.quantity % 1 ~= 0 then
		return false, "invalid_quantity"
	end
	if type(receipt.id) ~= "string" or receipt.id == "" then
		return false, "invalid_receipt"
	end
	if state.receipts[receipt.id] then
		return false, "duplicate_receipt"
	end
	state.receipts[receipt.id] = true
	local count = math.min(objective.quantity, (state.progress[objective.id] or 0) + receipt.quantity)
	state.progress[objective.id] = count
	if count == objective.quantity then
		state.completed[objective.id] = true
	end
	return true, nil
end

function M.advance(state: any, content: any, facts: any, now: number, entryBuffer: number): (boolean, string?)
	local ok, reason = M.admit(state, content, facts, now, entryBuffer)
	if not ok then
		return false, reason
	end
	for _, definition in definitions(content, M.layout(state)) do
		for _, objective in definition.objectives do
			if not state.completed[objective.id] then
				return false, "mission_gate"
			end
		end
	end
	if state.stage == 4 then
		state.status = "complete"
	else
		state.stage += 1
	end
	state.questCargo = nil
	state.treated = false
	state.escortAtStart = true
	state.escort, state.surveyHold = nil, nil
	state.bandage, state.bandageClaimed, state.cargoClaimed = nil, nil, nil
	return true, nil
end

-- This document does not own inventory. Recovery never clears or reconstructs
-- the bag, equipment, earned rewards, node deltas or completed checkpoints.
function M.recover(state: any, now: number, cause: string): string
	state.escortAtStart = true
	state.escort, state.surveyHold = nil, nil
	if now >= state.expiresAt then
		state.status = "expired"
	elseif cause == "abandon" or cause == "fail" or cause == "return" then
		state.status = cause
	end
	if state.status ~= "active" then
		state.questCargo = nil
		return "home"
	end
	return M.layout(state)
end

return M
