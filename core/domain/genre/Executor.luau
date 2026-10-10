--!strict
local Contract = require("./Contract")
local Schema = require("../../infra/net/Schema")
local Clock = require("../../infra/genre/Clock")
local Construction = require("./Construction")
local SerializedData = require("./SerializedData")
local M = {}
export type LifecycleResult = Contract.Result & { notificationError: string?, released: boolean? }
export type Executor = {
	join: (string, Contract.SaveEnvelope?, boolean?) -> LifecycleResult,
	requireHydration: () -> (),
	hydrate: (string, Contract.SaveEnvelope) -> (),
	discard: (string) -> (),
	prepareLeave: (string) -> string?,
	leave: (string) -> string?,
	dispatchClient: (string, string, { any }) -> Contract.Result,
	validateClient: (string, string, { any }) -> Contract.Result,
	validateServer: (string, string, { any }) -> Contract.Result,
	admit: (string, string, { any }, "client" | "server") -> Contract.Result,
	stageClient: (
		string,
		string,
		{ any },
		Contract.CommandContext?,
		boolean?
	) -> (Contract.CommandStage?, Contract.Result?),
	stageServer: (
		string,
		string,
		{ any },
		Contract.CommandContext?,
		boolean?
	) -> (Contract.CommandStage?, Contract.Result?),
	flushCommand: () -> string?,
	dispatchServer: (string, string, { any }) -> Contract.Result,
	pendingServerEvent: (string, string) -> string?,
	advance: (number) -> (),
	snapshot: (string) -> Contract.StateData,
	save: (string) -> Contract.SaveEnvelope,
}
M.finite = SerializedData.finite
M.clone = SerializedData.clone
M.data = SerializedData.data
M.validateSave = SerializedData.validateSave
local function reject(reason: string): LifecycleResult
	return { ok = false, reason = reason }
end

function M.new(
	pack: Contract.PackConfig,
	contracts: { Contract.RuntimeContract },
	services: Contract.Services,
	hooks: Contract.HookMap?
): Executor
	local descriptors, actions, queue, instances, clock = Construction.new(pack, contracts, services, hooks)
	local members: { [string]: boolean } = {}
	local buckets: { [string]: { [string]: { tokens: number, time: number } } } = {}
	local flushing = false
	local function flush(): string?
		if flushing then
			return
		end
		flushing = true
		local failures: { string } = {}
		local index = 1
		while index <= #queue do
			local event = queue[index]
			index += 1
			local key = event.genre .. ":" .. event.name
			local ok, err = pcall(services.emit :: any, M.clone(event))
			if not ok then
				table.insert(failures, key .. ": " .. tostring(err))
			end
			local hook = if hooks then hooks[key] else nil
			if hook then
				local hookOk, hookErr = pcall(hook :: any, M.clone(event))
				if not hookOk then
					table.insert(failures, key .. ": " .. tostring(hookErr))
				end
			end
		end
		table.clear(queue)
		flushing = false
		return if #failures > 0 then table.concat(failures, "; ") else nil
	end
	local function refresh()
		local now = services.now()
		assert(M.finite(now) and now >= clock.value, "clock moved backwards")
		clock.value = now
	end
	local executor: Executor = {} :: Executor
	function executor.requireHydration()
		for _, id in pack.order do
			assert(instances[id].hydrate ~= nil, "personal aggregate requires hydrate")
		end
	end
	function executor.hydrate(playerId, envelope)
		assert(members[playerId] and #M.validateSave(envelope, contracts) == 0, "invalid hydration")
		for _, id in pack.order do
			local hydrate = instances[id].hydrate
			assert(hydrate ~= nil and envelope.genres[id] ~= nil, "missing hydrate slice")
			local result = hydrate(playerId, M.clone(envelope.genres[id].data))
			assert(result.ok, result.reason or "hydrate refused committed data")
		end
	end
	function executor.discard(playerId)
		for _, id in pack.order do
			instances[id].leave(playerId)
		end
		members[playerId], buckets[playerId] = nil, nil
		table.clear(queue)
	end
	function executor.join(playerId, envelope, deferred)
		if #playerId == 0 or #playerId > 256 or members[playerId] then
			return reject("invalid/already joined player")
		end
		if envelope ~= nil and #M.validateSave(envelope, contracts) > 0 then
			return reject("invalid save envelope")
		end
		refresh()
		local joined: { string } = {}
		local queueStart = #queue
		for _, id in pack.order do
			local slice = if envelope then envelope.genres[id] else nil
			local result = instances[id].join(playerId, if slice then M.clone(slice.data) else nil)
			if not result.ok then
				for _, previous in joined do
					instances[previous].leave(playerId)
				end
				while #queue > queueStart do
					table.remove(queue)
				end
				return { ok = false, reason = result.reason }
			end
			table.insert(joined, id)
		end
		members[playerId] = true
		buckets[playerId] = {}
		return { ok = true, notificationError = if deferred then nil else flush() }
	end
	function executor.prepareLeave(playerId)
		if not members[playerId] then
			return
		end
		refresh()
		for _, id in pack.order do
			local prepare = instances[id].prepareLeave
			if prepare then
				prepare(playerId)
			end
		end
		return flush()
	end
	function executor.leave(playerId)
		if not members[playerId] then
			return
		end
		for _, id in pack.order do
			instances[id].leave(playerId)
		end
		members[playerId], buckets[playerId] = nil, nil
		return flush()
	end
	local function validate(playerId: string, id: string, args: { any }, origin: string): Contract.Result
		if not members[playerId] then
			return reject("player not joined")
		end
		if #id > 128 then
			return reject("action id too long")
		end
		local action = actions[id]
		if action == nil or action.origin ~= origin then
			return reject("unknown/disallowed action")
		end
		if not M.data(args) then
			return reject("invalid tuple data")
		end
		local count = 0
		for key in args do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #action.args then
				return reject("invalid tuple")
			end
			count += 1
		end
		if count ~= #action.args then
			return reject("invalid arity")
		end
		local valid, reason = Schema.check(Schema.tuple(action.args), args)
		if not valid then
			return reject(reason or "invalid args")
		end
		return { ok = true }
	end
	local function debitRate(playerId: string, id: string): Contract.Result
		local action = actions[id]
		refresh()
		local playerBuckets = buckets[playerId]
		local bucket: { tokens: number, time: number } = playerBuckets[id]
			or { tokens = action.rate.capacity, time = clock.value }
		bucket.tokens =
			math.min(action.rate.capacity, bucket.tokens + (clock.value - bucket.time) * action.rate.refillPerSecond)
		bucket.time = clock.value
		playerBuckets[id] = bucket
		if bucket.tokens < 1 then
			return reject("rate limited")
		end
		bucket.tokens -= 1
		return { ok = true }
	end
	local function dispatch(playerId: string, id: string, args: { any }, origin: string): Contract.Result
		local valid = validate(playerId, id, args, origin)
		if not valid.ok then
			return valid
		end
		local rate = debitRate(playerId, id)
		if not rate.ok then
			return rate
		end
		local action = actions[id]
		local genre = string.match(id, "^([^:]+):")
		assert(genre ~= nil, "contract assertion failed")
		local result = instances[genre].dispatch(playerId, action.id, M.clone(args))
		local notificationError = flush()
		assert(notificationError == nil, notificationError)
		return result
	end
	function executor.validateClient(playerId, id, args)
		return validate(playerId, id, args, "client")
	end
	function executor.admit(playerId, id, args, origin)
		local valid = validate(playerId, id, args, origin)
		if not valid.ok then
			return valid
		end
		return debitRate(playerId, id)
	end
	function executor.validateServer(playerId, id, args)
		return validate(playerId, id, args, "server")
	end
	local function stageCommand(
		playerId: string,
		id: string,
		args: { any },
		context: Contract.CommandContext?,
		origin: string,
		admitted: boolean?
	): (Contract.CommandStage?, Contract.Result?)
		local valid = validate(playerId, id, args, origin)
		if not valid.ok then
			return nil, valid
		end
		local genre = string.match(id, "^([^:]+):") :: string
		local stage = instances[genre].stageCommand
		if not stage then
			return nil, reject("durable action unsupported")
		end
		if not admitted then
			local rate = debitRate(playerId, id)
			if not rate.ok then
				return nil, rate
			end
		else
			refresh()
		end
		local trustedContext = M.clone(context)
		if trustedContext then
			trustedContext.nowMillis = Clock.millis(clock.value)
		end
		local candidate = stage(playerId, actions[id].id, M.clone(args), trustedContext)
		if not candidate then
			return nil, reject("durable action unsupported")
		end
		assert(M.data(candidate.data) and #descriptors[genre].validateSave(candidate.data) == 0, "invalid command save")
		return candidate, nil
	end
	function executor.stageClient(playerId, id, args, context, admitted)
		return stageCommand(playerId, id, args, context, "client", admitted)
	end
	function executor.stageServer(playerId, id, args, context, admitted)
		return stageCommand(playerId, id, args, context, "server", admitted)
	end
	executor.flushCommand = flush
	function executor.pendingServerEvent(playerId, id)
		assert(
			members[playerId] and actions[id] and actions[id].origin == "server",
			"invalid server event actor/action"
		)
		refresh()
		local genre = string.match(id, "^([^:]+):") :: string
		local query = instances[genre].pendingServerEvent
		assert(query ~= nil, "durable tick requires pendingServerEvent")
		local event = query(playerId, Clock.millis(clock.value))
		assert(event == nil or (#event > 0 and #event <= 128), "invalid server event identity")
		return event
	end
	function executor.dispatchClient(playerId, id, args)
		return dispatch(playerId, id, args, "client")
	end
	function executor.dispatchServer(playerId, id, args)
		return dispatch(playerId, id, args, "server")
	end
	function executor.advance(epoch)
		assert(M.finite(epoch) and epoch >= clock.value, "invalid advance time")
		clock.value = epoch
		for _, id in pack.order do
			instances[id].advance(epoch)
		end
		local notificationError = flush()
		assert(notificationError == nil, notificationError)
	end
	function executor.snapshot(playerId)
		assert(members[playerId], "player not joined")
		local result = {}
		for _, id in pack.order do
			local snapshot = instances[id].snapshot(playerId)
			assert(M.data(snapshot), "invalid snapshot")
			result[id] = M.clone(snapshot)
		end
		return result
	end
	function executor.save(playerId)
		assert(members[playerId], "player not joined")
		refresh()
		local result: Contract.SaveEnvelope = { version = 1, genres = {} }
		for _, id in pack.order do
			local saved = instances[id].save(playerId)
			assert(M.data(saved) and #descriptors[id].validateSave(saved) == 0, "invalid adapter save")
			result.genres[id] = { version = 1, data = M.clone(saved) }
		end
		return result
	end
	return executor
end

return M
