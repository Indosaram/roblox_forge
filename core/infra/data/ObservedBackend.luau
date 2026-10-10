--!strict
-- Records only acknowledged backend returns, never tentative transform candidates.
local M = {}
function M.new(backend: any, identity: any, encode: (any) -> string, now: () -> number, emit: (any) -> ())
	local sequence = 0
	local records: { any } = {}
	local bytes = 0
	local overflow = false
	local attempts, failures, throttles = 0, 0, 0
	local errors: { [string]: number } = {}
	local outcomes: { any } = {}
	local startedAtMs = now()
	local inFlight = 0
	local classified = true
	local api = {}
	function api.update(key: string, transform: (any) -> any): (boolean, any)
		local started = now()
		attempts += 1
		inFlight += 1
		local operation = attempts
		local previous: string? = nil
		local returned, ok, value, detail = pcall(function()
			return backend.update(key, function(old)
				previous = encode(old)
				return transform(old)
			end)
		end)
		inFlight -= 1
		local thrown = if not returned then ok else nil
		if not returned then
			ok, value, detail = false, "BACKEND_EXCEPTION", nil
		end
		local finished = now()
		local localDetail = type(detail) == "table"
			and detail.backend == "local-sqlite-cas"
			and detail.namespace == identity.namespace
			and detail.classificationComplete == true
			and type(detail.requests) == "table"
			and #detail.requests == detail.requestCount
		if localDetail then
			local epoch: string? = nil
			local hostOperation = 0
			for _, request in detail.requests do
				if
					request.correlationComplete ~= true
					or type(request.backendEpoch) ~= "string"
					or #request.backendEpoch ~= 36
					or string.match(
						request.backendEpoch,
						"^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
					) == nil
					or (epoch ~= nil and request.backendEpoch ~= epoch)
					or type(request.hostOperation) ~= "number"
					or request.hostOperation % 1 ~= 0
					or request.hostOperation <= hostOperation
					or request.hostOperation > 9007199254740991
				then
					localDetail = false
					break
				end
				epoch, hostOperation = request.backendEpoch, request.hostOperation
			end
		end
		classified = classified and localDetail
		local requestOutcomes = if detail and detail.requests then table.freeze(table.clone(detail.requests)) else nil
		-- Retention bounds match the local host's configuredCaps.maxOutcomes and
		-- the genre policy maximum (4096): one measured capacity window can pass
		-- 256 attempts before workload, so a 256 view cap forced a false overflow.
		-- The 16MB byte bound below remains the explicit loss-of-coverage signal.
		if #outcomes >= 4096 then
			overflow = true
		else
			table.insert(
				outcomes,
				table.freeze({
					operation = operation,
					key = key,
					startedAtMs = started,
					endedAtMs = finished,
					acknowledged = ok,
					error = if ok then nil else tostring(value),
					attempts = if detail then detail.attempts else nil,
					conflicts = if detail then detail.conflicts else nil,
					requestCount = if detail then detail.requestCount else nil,
					retryLimit = if detail then detail.retryLimit else nil,
					throttleCount = if detail then detail.throttleCount else nil,
					handledThrottleCount = if localDetail then 0 else nil,
					classificationComplete = localDetail,
					requests = requestOutcomes,
				})
			)
		end
		if not ok then
			failures += 1
			local code = if type(value) == "string" and string.match(value, "^LOCAL_[A-Z0-9_]+$")
				then value
				else "BACKEND_FAILURE_UNCLASSIFIED"
			errors[code] = (errors[code] or 0) + 1
		end
		if detail and type(detail.throttleCount) == "number" then
			throttles += detail.throttleCount
		elseif value == "LOCAL_HTTP_429" then
			throttles += 1
		end
		if ok then
			sequence += 1
			local serialized = encode(value)
			local retainedBytes = #serialized + #(previous or "")
			local record = {
				sequence = sequence,
				operation = operation,
				key = key,
				startedAtMs = started,
				endedAtMs = finished,
				latencyMs = finished - started,
				serialized = serialized,
				previousSerialized = previous,
				byteCount = #serialized,
				durableRevision = if type(value) == "table" then value.revision else nil,
				leaseGeneration = if type(value) == "table" then value.generation else nil,
			}
			-- Hard bounds are explicit loss of coverage, never silently a complete trace.
			if #records >= 4096 or bytes + retainedBytes > 16000000 then
				overflow = true
			else
				bytes += retainedBytes
				local frozen = table.freeze(record)
				table.insert(records, frozen)
				emit(frozen)
			end
		end
		if not returned then
			error(thrown, 0)
		end
		return ok, value
	end
	function api.observation()
		local backendObservation = if backend.observation then backend.observation() else nil
		local complete = not overflow and inFlight == 0 and #outcomes == attempts and classified
		return {
			identity = table.clone(identity),
			sequence = sequence,
			overflow = overflow,
			records = table.clone(records),
			attempts = attempts,
			failures = failures,
			throttleCount = throttles,
			errors = table.clone(errors),
			throttleClassification = if classified then "local-http-outcomes" else "unavailable",
			outcomes = table.clone(outcomes),
			startedAtMs = startedAtMs,
			endedAtMs = now(),
			inFlight = inFlight,
			coverageComplete = complete,
			backendObservation = backendObservation,
			handledThrottleCount = if complete and identity.mode == "studio-local" then 0 else nil,
		}
	end
	return api
end
return M
