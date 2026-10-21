--!strict
-- One owner persists this aggregate with bag and wallet in the same transaction.
-- No transition mutates its input; rejected commands have no consumable effects.
local Data = require("../genre/SerializedData")
local Tree = require("../progression/SkillTree")
local M = {}

function M.new(): any
	return { version = 0, completed = {}, jobs = {}, receipts = {} }
end

function M.operation(content: any, id: string): any
	for _, row in content.operations do
		if row.id == id then
			return row
		end
	end
	return nil
end

function M.effects(content: any, state: any): any
	local effects: any = {}
	for id in state.completed do
		local row = M.operation(content, id)
		if row and row.kind == "research" then
			for _, effect in row.effects do
				effects[effect.id] = math.min(effects[effect.id] or 0, effect.value)
			end
		end
	end
	return effects
end

function M.start(
	content: any,
	state: any,
	tree: any,
	id: string,
	target: string?,
	slot: number?,
	receipt: string,
	now: number,
	facts: any
): (any?, string?)
	if state.receipts[receipt] then
		return nil, "DUPLICATE_RECEIPT"
	end
	local row = M.operation(content, id)
	if not row or not table.find({ "research", "modifier", "support-tier" }, row.kind) then
		return nil, "UNKNOWN_OPERATION"
	end
	local reason = Tree.gate(tree, row.gates or {})
	if reason then
		return nil, reason
	end
	if facts.developmentRank < ((row.gates or {}).developmentRank or 0) then
		return nil, "DEVELOPMENT_GATE"
	end
	if facts.station ~= row.station or facts.stationTier < (row.stationTier or 1) or not facts.reachable then
		return nil, "STATION_GATE"
	end
	local equipment = if target then facts.equipment[target] else nil
	if row.kind ~= "research" then
		if not equipment then
			return nil, "UNKNOWN_EQUIPMENT"
		end
		local eligible = false
		for _, tag in row.eligibleTags or {} do
			eligible = eligible or table.find(equipment.tags, tag) ~= nil
		end
		if not eligible then
			return nil, "INELIGIBLE_EQUIPMENT"
		end
	end
	if row.kind == "modifier" and slot ~= 1 and slot ~= 2 then
		return nil, "INVALID_MODIFICATION_SLOT"
	end
	for _, job in state.jobs do
		if job.status == "running" and ((target and target == job.target) or (not target and job.id == id)) then
			return nil, "JOB_PENDING"
		end
	end
	local completed = if row.kind == "support-tier" then (equipment.completed or {}) else state.completed
	if completed[id] then
		return nil, "ALREADY_COMPLETED"
	end
	for _, prerequisite in (row.gates or {}).completed or {} do
		if not completed[prerequisite] then
			return nil, "UPGRADE_PREREQUISITE"
		end
	end
	if facts.coins < (row.cost or 0) then
		return nil, "INSUFFICIENT_COINS"
	end
	for _, input in row.inputs do
		if (facts.materials[input.item] or 0) < input.quantity then
			return nil, "INSUFFICIENT_MATERIALS"
		end
	end
	local result = Data.clone(state)
	result.jobs[receipt] = {
		id = id,
		target = target,
		slot = slot,
		finishAt = now + row.seconds,
		status = "running",
		cost = row.cost or 0,
		escrow = Data.clone(row.inputs),
	}
	result.receipts[receipt] = true
	result.version += 1
	return result, nil
end

function M.finish(content: any, state: any, jobId: string, now: number, cancel: boolean): (any?, any?, string?)
	local job = state.jobs[jobId]
	if not job or job.status ~= "running" then
		return nil, nil, "JOB_TERMINAL"
	end
	if cancel and now >= job.finishAt then
		return nil, nil, "JOB_FINISHED"
	end
	if not cancel and now < job.finishAt then
		return nil, nil, "NOT_READY"
	end
	local row = M.operation(content, job.id)
	if cancel and row.kind ~= "research" then
		return nil, nil, "CANNOT_CANCEL"
	end
	local result = Data.clone(state)
	result.jobs[jobId].status = if cancel then "cancelled" else "completed"
	result.version += 1
	if not cancel and row.kind == "research" then
		result.completed[job.id] = true
	end
	return result,
		{
			target = job.target,
			slot = job.slot,
			operation = row,
			refund = if cancel then math.floor(job.cost / 2) else 0,
			cancelled = cancel,
		},
		nil
end

return M
