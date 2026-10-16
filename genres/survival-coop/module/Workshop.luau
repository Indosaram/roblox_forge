--!strict
-- Pure candidates only: persist jobs and inventory together in Session's stage.
local Job = require("../../../core/domain/crafting/Job")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Content = require("../../../core/domain/survival/Content")
local M = {}

M.MAX_ACTIVE = 8
M.MAX_RETAINED = 64
export type Context = { actorId: string, sessionEpoch: number, requestId: string }
export type Entry = { epoch: number, retainedThroughEpoch: number, requestId: string, job: Job.Job }
export type State = { actorId: string, epoch: number, expiredBeforeEpoch: number, entries: { [string]: Entry } }
-- `stationTier` is the reached workbench's upgraded tier; absent means the
-- tier its structure kind declares in content.
export type Access = {
	carriedContainer: string,
	stationId: string?,
	stationKind: string?,
	stationTier: number?,
	inReach: boolean,
}
export type Candidate = { jobs: State, inventory: Inventory.State, jobId: string, reason: string? }

function M.identity(context: Context): string?
	if
		not Catalog.identity(context.actorId)
		or not Catalog.identity(context.requestId)
		or not Catalog.integer(context.sessionEpoch, 0, 2 ^ 53 - 1)
	then
		return nil
	end
	-- Length prefixes make separators inside either identity unambiguous.
	local id = string.format(
		"w%d:%s:%d:%d:%s",
		#context.actorId,
		context.actorId,
		context.sessionEpoch,
		#context.requestId,
		context.requestId
	)
	return if #id <= 100 then id else nil
end

function M.new(actorId: string): State
	assert(Catalog.identity(actorId), "INVALID_ACTOR")
	return { actorId = actorId, epoch = 0, expiredBeforeEpoch = 0, entries = {} }
end

function M.snapshot(state: State): State
	local result = M.new(state.actorId)
	result.epoch = state.epoch
	result.expiredBeforeEpoch = state.expiredBeforeEpoch
	for id, entry in state.entries do
		result.entries[id] = {
			epoch = entry.epoch,
			retainedThroughEpoch = entry.retainedThroughEpoch,
			requestId = entry.requestId,
			job = Job.snapshot(entry.job),
		}
	end
	return result
end

local function terminal(job: Job.Job): boolean
	return job.state == "Committed" or job.state == "Cancelled"
end

-- SERVER ONLY: the caller proves every acceptance window AND receipt horizon
-- below this exclusive cutoff has expired using the authoritative Session ledger.
-- Current epoch alone is not that proof. Persist this candidate before reuse.
function M.prune(state: State, expiredBeforeEpoch: number): State
	assert(Catalog.integer(expiredBeforeEpoch, state.expiredBeforeEpoch, 2 ^ 53 - 1), "INVALID_PRUNE_HORIZON")
	local result = M.snapshot(state)
	result.expiredBeforeEpoch = expiredBeforeEpoch
	result.epoch = math.max(result.epoch, expiredBeforeEpoch)
	for id, entry in result.entries do
		if terminal(entry.job) and entry.retainedThroughEpoch < expiredBeforeEpoch then
			result.entries[id] = nil
		end
	end
	return result
end

local function prepare(state: State, context: Context): (State?, string?)
	if context.actorId ~= state.actorId then
		return nil, "WRONG_ACTOR"
	end
	if not M.identity(context) then
		return nil, "INVALID_JOB_IDENTITY"
	end
	if context.sessionEpoch < state.epoch or context.sessionEpoch < state.expiredBeforeEpoch then
		return nil, "REQUEST_EXPIRED"
	end
	local result = M.snapshot(state)
	-- A newer acceptance epoch does not prove old receipt retention expired.
	-- Only explicit prune with a proven receipt horizon releases retained slots.
	if context.sessionEpoch > result.epoch then
		result.epoch = context.sessionEpoch
	end
	return result, nil
end

function M.reserve(
	state: State,
	inventory: Inventory.State,
	context: Context,
	content: Content.Document,
	revision: string,
	recipeId: string,
	nowMillis: number,
	access: Access,
	options: Job.Options?
): (Candidate?, string?)
	local jobs, err = prepare(state, context)
	if not jobs then
		return nil, err
	end
	local id = M.identity(context) :: string
	if jobs.entries[id] then
		return nil, "ALREADY_RESERVED"
	end
	local active, retained = 0, 0
	for _, entry in jobs.entries do
		retained += 1
		if not terminal(entry.job) then
			active += 1
		end
	end
	if active >= M.MAX_ACTIVE or retained >= M.MAX_RETAINED then
		return nil, "JOB_QUEUE_FULL"
	end
	if access.carriedContainer ~= inventory.id then
		return nil, "WRONG_CONTAINER"
	end
	local selected: Content.Recipe? = nil
	for _, recipe in content.recipes do
		if recipe.id == recipeId then
			selected = recipe
		end
	end
	if not selected then
		return nil, "UNKNOWN_RECIPE"
	end
	if
		selected.station
		and (not Catalog.identity(access.stationId) or access.stationKind ~= selected.station or not access.inReach)
	then
		return nil, "STATION_UNAVAILABLE"
	end
	if selected.tier and (access.stationTier or Job.stationTier(content, access.stationKind)) < selected.tier then
		return nil, "STATION_TIER"
	end
	if selected.requiredToolTag then
		local found = false
		for _, item in inventory.items do
			if
				item.durabilityMilli ~= nil
				and item.durabilityMilli > 0
				and Inventory.available(inventory, item.itemId) > 0
			then
				for _, definition in content.items do
					if definition.id == item.catalogId and table.find(definition.tags, selected.requiredToolTag) then
						found = true
					end
				end
			end
		end
		if not found then
			return nil, "TOOL_UNAVAILABLE"
		end
	end
	local job, reserved, reason = Job.reserve(inventory, content, revision, recipeId, id, nowMillis, options)
	if not job or not reserved then
		return nil, reason
	end
	jobs.entries[id] = {
		epoch = context.sessionEpoch,
		retainedThroughEpoch = context.sessionEpoch,
		requestId = context.requestId,
		job = job,
	}
	return { jobs = jobs, inventory = reserved, jobId = id }, nil
end

function M.transition(
	state: State,
	inventory: Inventory.State,
	context: Context,
	jobId: string,
	action: string,
	nowMillis: number
): (Candidate?, string?)
	-- Retained terminal jobs report their final state even in a newer epoch.
	local source = state.entries[jobId]
	local jobs, err = prepare(state, context)
	if not jobs then
		return nil, err
	end
	if not source then
		return nil, "UNKNOWN_JOB"
	elseif source.job.containerId ~= inventory.id then
		return nil, "WRONG_CONTAINER"
	elseif source.job.state == "Committed" then
		return nil, "ALREADY_COMMITTED"
	elseif source.job.state == "Cancelled" then
		return nil, "ALREADY_CANCELLED"
	end
	-- Reuse the domain's saved-job agreement validation before every transition,
	-- including start (which itself has no inventory parameter).
	local job = Job.fromSave(Job.save(source.job), inventory)
	local result = Inventory.snapshot(inventory)
	local reason: string? = nil
	if action == "start" then
		job = Job.start(job, nowMillis)
	elseif action == "complete" then
		job, result, reason = Job.complete(job, inventory, nowMillis)
	elseif action == "cancel" then
		job, result, reason = Job.cancel(job, inventory)
	else
		return nil, "UNKNOWN_ACTION"
	end
	jobs.entries[jobId].job = job
	-- An old active job can finish in a newer epoch; retain it through that
	-- command's receipt horizon rather than pruning by its creation epoch.
	jobs.entries[jobId].retainedThroughEpoch = context.sessionEpoch
	-- FULL_SLOTS/FULL_WEIGHT candidates still carry Ready and must be persisted.
	return { jobs = jobs, inventory = result, jobId = jobId, reason = reason }, nil
end

function M.save(state: State): any
	local result: any = M.snapshot(state)
	result.saveVersion = 1
	for id, entry in state.entries do
		result.entries[id].job = Job.save(entry.job)
	end
	return result
end

function M.fromSave(raw: any, actorId: string, inventories: { [string]: Inventory.State }): State
	assert(type(raw) == "table" and raw.saveVersion == 1, "UNSUPPORTED_WORKSHOP_SAVE")
	assert(raw.actorId == actorId and Catalog.integer(raw.epoch, 0, 2 ^ 53 - 1), "INVALID_WORKSHOP_OWNER")
	assert(Catalog.integer(raw.expiredBeforeEpoch, 0, raw.epoch), "INVALID_PRUNE_HORIZON")
	assert(type(raw.entries) == "table", "INVALID_WORKSHOP_SAVE")
	local result = M.new(actorId)
	result.epoch = raw.epoch
	result.expiredBeforeEpoch = raw.expiredBeforeEpoch
	local active, retained = 0, 0
	for id, entry in raw.entries do
		assert(type(entry) == "table" and type(entry.job) == "table", "INVALID_WORKSHOP_ENTRY")
		assert(
			M.identity({ actorId = actorId, sessionEpoch = entry.epoch, requestId = entry.requestId }) == id
				and entry.epoch <= result.epoch
				and entry.job.id == id,
			"INVALID_WORKSHOP_IDENTITY"
		)
		local inventory = inventories[entry.job.containerId]
		assert(inventory and inventory.id == entry.job.containerId, "WRONG_CONTAINER")
		local job = Job.fromSave(entry.job, inventory)
		assert(Catalog.integer(entry.retainedThroughEpoch, entry.epoch, result.epoch), "INVALID_RETENTION_EPOCH")
		assert(not terminal(job) or entry.retainedThroughEpoch >= result.expiredBeforeEpoch, "EXPIRED_TERMINAL_JOB")
		retained += 1
		if not terminal(job) then
			active += 1
		end
		assert(active <= M.MAX_ACTIVE and retained <= M.MAX_RETAINED, "JOB_QUEUE_FULL")
		result.entries[id] = {
			epoch = entry.epoch,
			retainedThroughEpoch = entry.retainedThroughEpoch,
			requestId = entry.requestId,
			job = job,
		}
	end
	return result
end

return M
