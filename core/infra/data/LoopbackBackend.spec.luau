--!strict
local Backend = require("./LoopbackBackend")
local serde = require("@lune/serde")
local epoch = "01234567-89ab-cdef-0123-456789abcdef"
local function headers(operation: number): any
	return { ["X-Forge-Backend-Epoch"] = epoch, ["X-Forge-Request-Operation"] = tostring(operation) }
end
return {
	["CAS conflict reruns transform on current value and ambiguous commit never retries"] = function()
		local revision, quantity, conflicts, writes = 0, 10, 1, 0
		local ambiguous = false
		local requests = 0
		local http: any = {}
		function http:JSONEncode(value)
			return serde.encode("json", value)
		end
		function http:JSONDecode(value)
			return serde.decode("json", value)
		end
		function http:RequestAsync(request)
			requests += 1
			assert(
				string.find(request.Url, "http://127.0.0.1:43123/", 1, true) == 1,
				'string.find(request.Url, "http://127.0.0.1:43123/", 1, true) == 1'
			)
			local body = self:JSONDecode(request.Body)
			if string.sub(request.Url, -4) == "read" then
				return {
					StatusCode = 200,
					Headers = headers(requests),
					Body = self:JSONEncode({ revision = revision, value = self:JSONEncode({ quantity = quantity }) }),
				}
			end
			writes += 1
			if conflicts > 0 then
				conflicts -= 1
				quantity, revision = 9, 1
				return { StatusCode = 409, Headers = headers(requests) }
			end
			assert(body.revision == revision, "body.revision == revision")
			quantity, revision = self:JSONDecode(body.value).quantity, revision + 1
			if ambiguous then
				error("connection lost")
			end
			return {
				StatusCode = 200,
				Headers = headers(requests),
				Body = self:JSONEncode({ revision = revision, value = body.value }),
			}
		end
		local backend = Backend.new({ port = 43123, token = string.rep("a", 64), namespace = "owned" }, http)
		local calls = 0
		local ok, value, detail = backend.update("p", function(old: any)
			calls += 1
			old.quantity -= 3
			return old
		end)
		assert(ok and value.quantity == 6 and calls == 2, "ok and value.quantity == 6 and calls == 2")
		assert(
			detail.attempts == 2 and detail.conflicts == 1 and detail.requestCount == 4 and detail.retryLimit == 15,
			"actual bounded CAS attempts"
		)
		assert(detail.throttleCount == 0 and detail.classificationComplete, "conflict is not throttle")
		assert(#detail.requests == 4 and detail.requests[2].outcome == "CAS_CONFLICT", "actual request outcome trace")
		assert(
			detail.requests[2].backendEpoch == epoch and detail.requests[2].hostOperation == 2,
			"conflict joins exact host request"
		)
		assert(
			detail.requests[4].inputRevision == 1 and detail.requests[4].acknowledgedRevision == 2,
			"CAS revision binding"
		)
		ambiguous = true
		local before = writes
		assert(not backend.update("p", function(old: any)
			old.quantity -= 1
			return old
		end), 'not backend.update("p", function(old) old.quantity -= 1; return old end)')
		assert(writes == before + 1 and quantity == 5, "writes == before + 1 and quantity == 5")
	end,
	["HTTP throttle is unhandled and never retried"] = function()
		local calls = 0
		local http: any = {}
		function http:JSONEncode(value)
			return serde.encode("json", value)
		end
		function http:RequestAsync(_request)
			calls += 1
			return { StatusCode = 429, Headers = headers(calls) }
		end
		local backend = Backend.new({ port = 43123, token = string.rep("a", 64), namespace = "owned" }, http)
		local ok, reason, detail = backend.update("p", function()
			error("throttled read must not transform")
		end)
		assert(not ok and reason == "LOCAL_HTTP_429" and calls == 1, "no retry after throttle")
		assert(detail.throttleCount == 1 and detail.handledThrottleCount == 0, "refusal is not handled success")
		assert(detail.classificationComplete and #detail.requests == 1, "complete failed outcome retained")
		http.RequestAsync = function(_self: any, _request: any)
			calls += 1
			return { StatusCode = 429 }
		end
		local refused, code, missing = backend.update("p", function()
			error("throttled read must not transform")
		end)
		assert(
			not refused and code == "LOCAL_HTTP_429" and calls == 2,
			"missing metadata preserves failure without retry"
		)
		assert(
			not missing.classificationComplete and missing.handledThrottleCount == nil,
			"uncorrelated throttle is incomplete"
		)
	end,
	["conflict exhaustion retains every bounded request without handling a throttle"] = function()
		local http: any = {}
		local requests = 0
		function http:JSONEncode(value)
			return serde.encode("json", value)
		end
		function http:JSONDecode(value)
			return serde.decode("json", value)
		end
		function http:RequestAsync(request)
			requests += 1
			if string.sub(request.Url, -4) == "read" then
				return {
					StatusCode = 200,
					Headers = headers(requests),
					Body = self:JSONEncode({ revision = 0, value = "null" }),
				}
			end
			return { StatusCode = 409, Headers = headers(requests) }
		end
		local backend = Backend.new({ port = 43123, token = string.rep("a", 64), namespace = "owned" }, http)
		local ok, reason, detail = backend.update("p", function()
			return {}
		end)
		assert(not ok and reason == "LOCAL_CONTENTION_LIMIT", "bounded contention refusal")
		assert(
			detail.attempts == 16 and detail.conflicts == 16 and #detail.requests == 32,
			"all bounded attempts retained"
		)
		assert(detail.throttleCount == 0 and detail.handledThrottleCount == 0, "conflicts not service throttles")
	end,
	["missing or inconsistent response correlation invalidates coverage without changing commits"] = function()
		for _, mode in { "missing", "epoch", "duplicate", "fractional" } do
			local calls = 0
			local http: any = {}
			function http:JSONEncode(value)
				return serde.encode("json", value)
			end
			function http:JSONDecode(value)
				return serde.decode("json", value)
			end
			function http:RequestAsync(_request)
				calls += 1
				local metadata = headers(calls)
				if calls == 2 then
					if mode == "missing" then
						metadata = {}
					elseif mode == "epoch" then
						metadata["X-Forge-Backend-Epoch"] = "ffffffff-ffff-ffff-ffff-ffffffffffff"
					elseif mode == "duplicate" then
						metadata["X-Forge-Request-Operation"] = "1"
					else
						metadata["X-Forge-Request-Operation"] = "1.5"
					end
				end
				return {
					StatusCode = 200,
					Headers = metadata,
					Body = self:JSONEncode({ revision = calls - 1, value = "null" }),
				}
			end
			local backend = Backend.new({ port = 43123, token = string.rep("a", 64), namespace = "owned" }, http)
			local ok, _, detail = backend.update("p", function()
				return nil
			end)
			assert(ok and calls == 2, "instrumentation does not retry or reject committed result")
			assert(
				not detail.classificationComplete and detail.handledThrottleCount == nil,
				"bad correlation cannot classify handling"
			)
			assert(not detail.requests[2].correlationComplete, "bad response specifically identified")
		end
	end,
}
