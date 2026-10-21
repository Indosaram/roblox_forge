--!strict
-- Pure checkpoint machine. Evidence comes only from settled authoritative commands.
local M = {}
export type State = {
	version: number,
	active: string?,
	completed: { [string]: boolean },
	counts: { [string]: number },
	receipts: { [string]: boolean },
	markers: { [string]: boolean },
}
export type Evidence = { id: string, action: string, target: string, quantity: number, marker: string? }
function M.new(): State
	return { version = 1, completed = {}, counts = {}, receipts = {}, markers = {} }
end
function M.copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[key] = M.copy(child)
	end
	return out
end
function M.current(state: State, catalog: { any }): any
	for _, chapter in catalog do
		if chapter.id == state.active then
			return chapter
		end
	end
	return nil
end
function M.open(state: State, catalog: { any }, id: string, level: number): (State?, string?)
	local found = nil
	for _, chapter in catalog do
		if chapter.id == id then
			found = chapter
			break
		end
		if not state.completed[chapter.id] then
			return nil, "CHAPTER_ORDER"
		end
	end
	if not found then
		return nil, "UNKNOWN_CHAPTER"
	elseif state.completed[id] then
		return nil, "ALREADY_COMPLETED"
	elseif level < found.gates.characterLevel then
		return nil, "LEVEL_GATE"
	elseif state.active and state.active ~= id then
		return nil, "CHAPTER_ACTIVE"
	end
	for _, prerequisite in found.gates.completed or {} do
		if not state.completed[prerequisite] then
			return nil, "CHAPTER_ORDER"
		end
	end
	local out = M.copy(state)
	out.active = id
	return out, nil
end
function M.observe(state: State, catalog: { any }, evidence: Evidence): (State?, string?)
	local chapter = M.current(state, catalog)
	if not chapter then
		return nil, "NO_ACTIVE_CHAPTER"
	elseif evidence.id == "" or evidence.quantity % 1 ~= 0 or evidence.quantity < 1 then
		return nil, "INVALID_EVIDENCE"
	elseif state.receipts[evidence.id] then
		return M.copy(state), nil
	end
	local out = M.copy(state)
	for _, objective in chapter.objectives do
		if (out.counts[objective.id] or 0) >= objective.quantity then
			continue
		end
		-- Checkpoints are sequential; later actions cannot pre-fill future chapters.
		if evidence.action ~= objective.action or evidence.target ~= objective.target then
			return nil, "WRONG_OBJECTIVE"
		end
		local marker = objective.id .. ":" .. (evidence.marker or "")
		if
			objective.action == "survey"
			and (evidence.quantity ~= 1 or not evidence.marker or evidence.marker == "" or out.markers[marker])
		then
			return nil, "DISTINCT_MARKER_REQUIRED"
		end
		out.receipts[evidence.id] = true
		out.markers[marker] = true
		out.counts[objective.id] = math.min(objective.quantity, (out.counts[objective.id] or 0) + evidence.quantity)
		return out, nil
	end
	return nil, "AWAITING_CLAIM"
end
function M.claim(state: State, catalog: { any }): (State?, any)
	local chapter = M.current(state, catalog)
	if not chapter then
		return nil, "NO_ACTIVE_CHAPTER"
	end
	for _, objective in chapter.objectives do
		if (state.counts[objective.id] or 0) < objective.quantity then
			return nil, "OBJECTIVES_INCOMPLETE"
		end
	end
	local out = M.copy(state)
	out.completed[chapter.id], out.active = true, nil
	-- Receipts are scoped to the active chapter; completed chapters cannot reopen.
	out.counts, out.receipts, out.markers = {}, {}, {}
	return out, M.copy(chapter.rewards)
end
function M.restore(raw: any, catalog: { any }): State
	assert(type(raw) == "table" and raw.version == 1, "INVALID_JOURNAL_SAVE")
	local state: State = M.copy(raw)
	local gap = false
	for _, chapter in catalog do
		if state.completed[chapter.id] then
			assert(not gap, "INVALID_CHAPTER_ORDER")
		else
			gap = true
		end
	end
	if state.active then
		assert(M.open(state, catalog, state.active, math.huge), "INVALID_ACTIVE_CHAPTER")
		local chapter = M.current(state, catalog)
		local incomplete = false
		for _, objective in chapter.objectives do
			local count = state.counts[objective.id] or 0
			assert(count % 1 == 0 and count >= 0 and count <= objective.quantity, "INVALID_CHECKPOINT")
			assert(not incomplete or count == 0, "INVALID_CHECKPOINT_ORDER")
			incomplete = incomplete or count < objective.quantity
		end
	end
	return state
end
return M
