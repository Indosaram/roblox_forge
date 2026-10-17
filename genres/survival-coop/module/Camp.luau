--!strict
-- Camp: the survival-coop social unit on top of an existing settlement tribe
-- (plan 7). Membership, the 4-member cap and the rejoin cooldown stay in
-- core Settlement; this module adds the shared project ladder only. Completed
-- joint builds unlock shared facilities and, at the top rung, season siege
-- league eligibility (still gated by Settlement.leagueEligibility).
-- Pure candidates: the caller persists the camp next to its settlement.
local Settlement = require("../../../core/domain/settlement/Settlement")
local M = {}

export type Contribution = { item: string, quantity: number }
export type Project = { id: string, rung: number, cost: { Contribution } }
export type Rung = { rung: number, completions: number, facility: string }
export type Ladder = { projects: { [string]: Project }, rungs: { Rung }, leagueRung: number }
export type Progress = { delivered: { [string]: number }, contributors: { [string]: boolean } }
export type State = {
	tribeId: string,
	version: number,
	active: { [string]: Progress },
	completed: { [string]: number },
	facilities: { [string]: boolean },
}

-- Two distinct members must contribute before a project counts as joint.
M.MIN_CONTRIBUTORS = 2

local MAX_CLOCK = 2 ^ 53 - 1

local function integer(value: any, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value >= minimum and value <= maximum and value % 1 == 0
end

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

function M.ladder(projects: { Project }, rungs: { Rung }, leagueRung: number): Ladder
	local byId: { [string]: Project } = {}
	for _, project in projects do
		assert(type(project.id) == "string" and project.id ~= "" and byId[project.id] == nil, "INVALID_PROJECT_ID")
		assert(integer(project.rung, 1, #rungs), "INVALID_PROJECT_RUNG")
		assert(#project.cost > 0, "INVALID_PROJECT_COST")
		local items: { [string]: boolean } = {}
		for _, cost in project.cost do
			assert(
				cost.item ~= "" and not items[cost.item] and integer(cost.quantity, 1, 1000000),
				"INVALID_PROJECT_COST"
			)
			items[cost.item] = true
		end
		byId[project.id] = copy(project)
	end
	local previous = 0
	local facilities: { [string]: boolean } = {}
	for index, rung in rungs do
		assert(rung.rung == index, "RUNGS_NOT_DENSE")
		assert(integer(rung.completions, previous + 1, 1000), "COMPLETIONS_NOT_INCREASING")
		assert(rung.facility ~= "" and not facilities[rung.facility], "INVALID_FACILITY")
		facilities[rung.facility] = true
		previous = rung.completions
	end
	assert(integer(leagueRung, 1, #rungs), "INVALID_LEAGUE_RUNG")
	return { projects = byId, rungs = copy(rungs), leagueRung = leagueRung }
end

function M.new(tribeId: string): State
	assert(tribeId ~= "", "identity required")
	return { tribeId = tribeId, version = 0, active = {}, completed = {}, facilities = {} }
end

local function completions(state: State): number
	local total = 0
	for _, count in state.completed do
		total += count
	end
	return total
end

-- Highest rung whose completion threshold is met (0 = none).
function M.rung(state: State, ladder: Ladder): number
	local total = completions(state)
	local reached = 0
	for _, rung in ladder.rungs do
		if total >= rung.completions then
			reached = rung.rung
		end
	end
	return reached
end

-- A project is open once every rung below its own is reached.
local function unlocked(state: State, ladder: Ladder, project: Project): boolean
	return M.rung(state, ladder) >= project.rung - 1
end

-- Members deliver materials the caller has already debited atomically from the
-- camp warehouse in the same commit; nothing is refunded on overflow.
function M.contribute(
	state: State,
	ladder: Ladder,
	settlement: Settlement.State,
	actorId: string,
	version: number,
	projectId: string,
	contribution: Contribution
): (State?, string?)
	if settlement.config.tribeId ~= state.tribeId then
		return nil, "TRIBE_MISMATCH"
	elseif settlement.roles[actorId] == nil then
		return nil, "FORBIDDEN"
	elseif version ~= state.version then
		return nil, "STALE_VERSION"
	end
	local project = ladder.projects[projectId]
	if project == nil then
		return nil, "UNKNOWN_PROJECT"
	elseif not unlocked(state, ladder, project) then
		return nil, "PROJECT_LOCKED"
	end
	local need: number? = nil
	for _, cost in project.cost do
		if cost.item == contribution.item then
			need = cost.quantity
		end
	end
	if need == nil then
		return nil, "ITEM_NOT_NEEDED"
	elseif not integer(contribution.quantity, 1, 1000000) then
		return nil, "INVALID_QUANTITY"
	end
	local progress = state.active[projectId]
	local delivered = if progress then progress.delivered[contribution.item] or 0 else 0
	if delivered + contribution.quantity > need then
		return nil, "OVER_DELIVERY"
	end
	local result = copy(state) :: State
	local next = result.active[projectId] or { delivered = {}, contributors = {} }
	next.delivered[contribution.item] = delivered + contribution.quantity
	next.contributors[actorId] = true
	result.active[projectId] = next
	result.version += 1
	return result, nil
end

-- A visiting friend is not a tribe member: stand in a one-role roster so only the
-- shared delivery rules (lock, need, overflow, version) apply. Visitors may help
-- a host project but can never complete one; the caller debits the visitor's bag.
function M.assist(
	state: State,
	ladder: Ladder,
	visitorId: string,
	version: number,
	projectId: string,
	contribution: Contribution
): (State?, string?)
	local guest = { config = { tribeId = state.tribeId }, roles = { [visitorId] = "visitor" } }
	return M.contribute(state, ladder, guest :: any, visitorId, version, projectId, contribution)
end

-- Completes a fully delivered joint project, counting it toward the ladder and
-- granting every facility whose rung is now reached.
function M.complete(
	state: State,
	ladder: Ladder,
	settlement: Settlement.State,
	actorId: string,
	version: number,
	projectId: string
): (State?, string?)
	if settlement.config.tribeId ~= state.tribeId then
		return nil, "TRIBE_MISMATCH"
	elseif settlement.roles[actorId] == nil then
		return nil, "FORBIDDEN"
	elseif version ~= state.version then
		return nil, "STALE_VERSION"
	end
	local project = ladder.projects[projectId]
	local progress = state.active[projectId]
	if project == nil then
		return nil, "UNKNOWN_PROJECT"
	elseif progress == nil then
		return nil, "NOT_STARTED"
	end
	for _, cost in project.cost do
		if (progress.delivered[cost.item] or 0) < cost.quantity then
			return nil, "INCOMPLETE"
		end
	end
	local contributors = 0
	for _ in progress.contributors do
		contributors += 1
	end
	if contributors < M.MIN_CONTRIBUTORS then
		return nil, "NOT_JOINT"
	end
	local result = copy(state) :: State
	result.active[projectId] = nil
	result.completed[projectId] = (result.completed[projectId] or 0) + 1
	local reached = M.rung(result, ladder)
	for _, rung in ladder.rungs do
		if rung.rung <= reached then
			result.facilities[rung.facility] = true
		end
	end
	result.version += 1
	return result, nil
end

-- Season siege league eligibility: the camp ladder rung AND the core
-- anti-alt floor (member account age + membership duration) must both hold.
function M.leagueEligible(
	state: State,
	ladder: Ladder,
	settlement: Settlement.State,
	now: number,
	accountAgeDays: { [string]: number }
): (boolean, string?, { Settlement.LeagueFailure }?)
	assert(integer(now, 0, MAX_CLOCK), "invalid clock")
	if settlement.config.tribeId ~= state.tribeId then
		return false, "TRIBE_MISMATCH", nil
	elseif M.rung(state, ladder) < ladder.leagueRung then
		return false, "LADDER_RUNG_REQUIRED", nil
	end
	local ok, failures = Settlement.leagueEligibility(settlement, now, accountAgeDays)
	if not ok then
		return false, "MEMBER_FLOOR", failures
	end
	return true, nil, nil
end

function M.save(state: State): any
	local saved = copy(state)
	saved.saveVersion = 1
	return saved
end

-- Restore re-derives facilities from completions so a forged save cannot grant them.
function M.fromSave(raw: any, ladder: Ladder): State
	assert(type(raw) == "table" and raw.saveVersion == 1, "UNSUPPORTED_CAMP_SAVE")
	assert(type(raw.tribeId) == "string" and raw.tribeId ~= "", "INVALID_TRIBE")
	assert(integer(raw.version, 0, MAX_CLOCK), "INVALID_VERSION")
	assert(type(raw.completed) == "table" and type(raw.active) == "table", "INVALID_CAMP_SAVE")
	local result = M.new(raw.tribeId)
	result.version = raw.version
	for id, count in raw.completed do
		assert(ladder.projects[id] ~= nil and integer(count, 1, 1000000), "INVALID_COMPLETION")
		result.completed[id] = count
	end
	for id, progress in raw.active do
		local project = ladder.projects[id]
		assert(project and type(progress) == "table", "INVALID_PROGRESS")
		assert(type(progress.delivered) == "table" and type(progress.contributors) == "table", "INVALID_PROGRESS")
		local needs: { [string]: number } = {}
		for _, cost in project.cost do
			needs[cost.item] = cost.quantity
		end
		for item, quantity in progress.delivered do
			assert(needs[item] ~= nil and integer(quantity, 1, needs[item]), "INVALID_DELIVERY")
		end
		for actor, flag in progress.contributors do
			assert(type(actor) == "string" and actor ~= "" and flag == true, "INVALID_CONTRIBUTOR")
		end
		result.active[id] = copy(progress)
	end
	local reached = M.rung(result, ladder)
	for _, rung in ladder.rungs do
		if rung.rung <= reached then
			result.facilities[rung.facility] = true
		end
	end
	return result
end

return M
