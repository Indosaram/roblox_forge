--!strict
-- Optimistic atomic update: only a confirmed CAS conflict replays the pure callback.
-- Transport ambiguity returns failure; existing durable receipts own recovery.
local M = {}
-- Loopback runs against one in-process host: serialize read/CAS cycles so this
-- server's own coroutines can never conflict with each other. A conflict storm
-- can exhaust the host's request budget in seconds and then surface to every
-- caller as LOCAL_TRANSPORT_UNAVAILABLE.
local updateLocked = false
function M.new(config: any, http: any): any
	assert(
		type(config.port) == "number" and config.port % 1 == 0 and config.port >= 1024 and config.port <= 65535,
		"INVALID_LOOPBACK_PORT"
	)
	assert(
		type(config.token) == "string" and #config.token == 64 and string.match(config.token, "^[a-f0-9]+$"),
		"OWNED_LOOPBACK_TOKEN_REQUIRED"
	)
	assert(
		type(config.namespace) == "string"
			and #config.namespace >= 1
			and #config.namespace <= 32
			and string.match(config.namespace, "^[a-z0-9%-]+$"),
		"ISOLATED_QA_NAMESPACE_REQUIRED"
	)
	local endpoint = "http://127.0.0.1:" .. tostring(config.port)
	-- The caller supplies the wait function: RuntimeBackend passes task.wait
	-- from Roblox, specs inject config.wait. With neither, a pure-Lune
	-- environment simply skips the delay (counts and outcomes stay identical).
	local function pause(seconds: number)
		local waitFn = config.wait
		if type(waitFn) == "function" then
			waitFn(seconds)
		end
	end
	local backendEpoch: string? = nil
	local correlationLost = false
	local function request(route: string, body: { [string]: any }): (any?, string?, any?)
		body.namespace = config.namespace
		local ok, response = pcall(function()
			return http:RequestAsync({
				Url = endpoint .. route,
				Method = "POST",
				Headers = { ["Content-Type"] = "application/json", Authorization = "Bearer " .. config.token },
				Body = http:JSONEncode(body),
			})
		end)
		if not ok then
			return nil, "LOCAL_TRANSPORT_UNAVAILABLE", nil
		end
		local headers = {}
		for name, value in response.Headers or {} do
			headers[string.lower(name)] = value
		end
		local epoch = headers["x-forge-backend-epoch"]
		local rawOperation = headers["x-forge-request-operation"]
		local operation = if type(rawOperation) == "string" then tonumber(rawOperation) else nil
		local correlation = {
			backendEpoch = epoch,
			hostOperation = operation,
			valid = type(epoch) == "string"
				and #epoch == 36
				and string.match(epoch, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
				and type(rawOperation) == "string"
				and string.match(rawOperation, "^[1-9][0-9]*$") ~= nil
				and operation ~= nil
				and operation <= 9007199254740991,
		}
		if response.StatusCode == 409 then
			return nil, "CAS_CONFLICT", correlation
		end
		if response.StatusCode ~= 200 then
			return nil, "LOCAL_HTTP_" .. tostring(response.StatusCode), correlation
		end
		local decoded, value = pcall(function()
			return http:JSONDecode(response.Body)
		end)
		if route == "/observation" then
			if
				decoded
				and type(value) == "table"
				and value.backend == "local-sqlite-cas"
				and value.namespace == config.namespace
			then
				return value, nil, nil
			end
			return nil, "LOCAL_PROTOCOL_INVALID", nil
		end
		if
			not decoded
			or type(value) ~= "table"
			or type(value.value) ~= "string"
			or type(value.revision) ~= "number"
		then
			return nil, "LOCAL_PROTOCOL_INVALID", correlation
		end
		return value, nil, correlation
	end
	return {
		observation = function()
			local value, reason = request("/observation", {})
			return value
				or {
					backend = "local-sqlite-cas",
					namespace = config.namespace,
					coverageComplete = false,
					error = reason,
				}
		end,
		update = function(key, transform)
			while updateLocked do
				pause(0.03)
			end
			updateLocked = true
			local ran, outcomeOk, outcomeValue, outcomeDetail = pcall(function()
				local previousOperation = 0
				local detail: any = {
					backend = "local-sqlite-cas",
					namespace = config.namespace,
					attempts = 0,
					conflicts = 0,
					requestCount = 0,
					retryLimit = 15,
					outcome = "pending",
					throttleCount = 0,
					handledThrottleCount = 0,
					classificationComplete = true,
					requests = {},
				}
				local function observedRequest(route: string, body: { [string]: any }): (any?, string?)
					detail.requestCount += 1
					local value, reason, correlation = request(route, body)
					local correlated = correlation ~= nil and correlation.valid == true
					if correlated then
						if backendEpoch == nil then
							backendEpoch = correlation.backendEpoch
						end
						correlated = correlation.backendEpoch == backendEpoch
							and correlation.hostOperation > previousOperation
						previousOperation = correlation.hostOperation
					end
					if not correlated then
						correlationLost = true
					end
					if reason == "LOCAL_HTTP_429" then
						detail.throttleCount += 1
					end
					if
						correlationLost
						or reason == "LOCAL_TRANSPORT_UNAVAILABLE"
						or reason == "LOCAL_PROTOCOL_INVALID"
					then
						detail.classificationComplete = false
					end
					table.insert(
						detail.requests,
						table.freeze({
							request = detail.requestCount,
							attempt = detail.attempts,
							route = route,
							backendEpoch = if correlation then correlation.backendEpoch else nil,
							hostOperation = if correlation then correlation.hostOperation else nil,
							correlationComplete = correlated,
							key = key,
							inputRevision = body.revision,
							acknowledgedRevision = if value then value.revision else nil,
							acknowledged = value ~= nil,
							outcome = reason or "acknowledged",
						})
					)
					return value, reason
				end
				local function finish(ok: boolean, value: any): (boolean, any, any)
					detail.outcome = if ok then "acknowledged" else tostring(value)
					detail.handledThrottleCount = if detail.classificationComplete then 0 else nil
					return ok, value, detail
				end
				for attempt = 1, 16 do
					detail.attempts = attempt
					local current, err = observedRequest("/read", { key = key })
					if not current then
						return finish(false, err)
					end
					local decoded = http:JSONDecode(current.value)
					local snapshot = if decoded == nil then nil else http:JSONEncode(decoded)
					local value = transform(decoded)
					if snapshot ~= nil and type(value) == "table" and http:JSONEncode(value) == snapshot then
						-- The transform published nothing (content unchanged): acknowledging
						-- the read is the whole contract. Skipping the CAS here is what
						-- keeps identity sweeps (empty recovery scans) off the host's
						-- request budget.
						return finish(true, decoded)
					end
					local committed, reason = observedRequest(
						"/cas",
						{ key = key, revision = current.revision, value = http:JSONEncode(value) }
					)
					if committed then
						return finish(true, http:JSONDecode(committed.value))
					end
					if reason ~= "CAS_CONFLICT" then
						return finish(false, reason)
					end
					detail.conflicts += 1
					-- Losers back off instead of hot-looping: an unbacked contention storm
					-- burns the host request budget and fails unrelated persistence calls.
					pause(math.min(0.05 * detail.conflicts, 0.25))
				end
				return finish(false, "LOCAL_CONTENTION_LIMIT")
			end)
			updateLocked = false
			if not ran then
				error(outcomeOk, 0)
			end
			return outcomeOk, outcomeValue, outcomeDetail
		end,
	}
end
return M
