--!strict
local Observed = require("./ObservedBackend")
local Memory = require("./MemoryBackend")
local serde = require("@lune/serde")
local function request(operation: number, outcome: string): any
	return table.freeze({
		request = operation,
		hostOperation = operation,
		backendEpoch = "01234567-89ab-cdef-0123-456789abcdef",
		correlationComplete = true,
		outcome = outcome,
	})
end
return {
	["local detail cannot claim complete coverage without actual correlation"] = function()
		local backend = Observed.new({
			update = function()
				return false,
					"LOCAL_HTTP_429",
					{
						backend = "local-sqlite-cas",
						namespace = "owned",
						classificationComplete = true,
						requestCount = 1,
						throttleCount = 1,
						requests = { table.freeze({ outcome = "LOCAL_HTTP_429" }) },
					}
			end,
		}, { mode = "studio-local", namespace = "owned" }, function(value)
			return serde.encode("json", value)
		end, function()
			return 1000
		end, function() end)
		backend.update("p", function()
			return nil
		end)
		local view = backend.observation()
		assert(
			not view.coverageComplete and view.handledThrottleCount == nil,
			"missing host identity rejects coverage claim"
		)
		assert(view.throttleCount == 1 and not view.outcomes[1].acknowledged, "failure is still retained")
	end,
	["complete local outcomes distinguish zero throttles from unhandled failure and overflow"] = function()
		local fail = false
		local backend = Observed.new({
			update = function(_, transform)
				local detail = {
					backend = "local-sqlite-cas",
					namespace = "owned",
					classificationComplete = true,
					attempts = 1,
					conflicts = 0,
					requestCount = if fail then 1 else 2,
					retryLimit = 15,
					throttleCount = if fail then 1 else 0,
					requests = if fail
						then { request(1, "LOCAL_HTTP_429") }
						else { request(1, "acknowledged"), request(2, "acknowledged") },
				}
				if fail then
					return false, "LOCAL_HTTP_429", detail
				end
				return true, transform(nil), detail
			end,
		}, { mode = "studio-local", namespace = "owned" }, function(value)
			return serde.encode("json", value)
		end, function()
			return 1000
		end, function() end)
		backend.update("p", function()
			return { revision = 1 }
		end)
		local view = backend.observation()
		assert(
			view.coverageComplete and view.handledThrottleCount == 0 and view.throttleCount == 0,
			"normal no-throttle trace"
		)
		fail = true
		backend.update("p", function()
			return nil
		end)
		view = backend.observation()
		assert(
			view.coverageComplete and view.throttleCount == 1 and view.handledThrottleCount == 0,
			"failed throttle remains unhandled"
		)
		for _ = 1, 4095 do
			backend.update("p", function()
				return nil
			end)
		end
		view = backend.observation()
		assert(
			view.overflow and not view.coverageComplete and view.handledThrottleCount == nil,
			"lost trace cannot classify handling"
		)
	end,
	["thrown backend preserves exception and invalidates coverage"] = function()
		local backend = Observed.new({
			update = function()
				error("owned exception")
			end,
		}, { mode = "studio-local", namespace = "owned" }, function(value)
			return serde.encode("json", value)
		end, function()
			return 1000
		end, function() end)
		assert(not pcall(backend.update, "p", function() end), "exceptions still propagate")
		local view = backend.observation()
		assert(
			view.failures == 1 and view.inFlight == 0 and #view.outcomes == 1,
			"exception counted without pending leak"
		)
		assert(not view.coverageComplete and view.handledThrottleCount == nil, "exception is not classified success")
	end,
	["only acknowledged persisted wrappers appear and observation cannot mutate history"] = function()
		local memory, fail = Memory.new(), false
		local events = {}
		local now = 0
		local backend = Observed.new({
			update = function(key, transform)
				local ok, value = memory.update(key, transform)
				if fail then
					return false, "LOST_ACK"
				end
				return ok, value
			end,
		}, { namespace = "owned" }, function(value)
			return serde.encode("json", value)
		end, function()
			now += 1
			return now
		end, function(event)
			table.insert(events, event)
		end)
		local ok = backend.update("personal:1", function()
			return { generation = 1, data = { quantity = 3 } }
		end)
		assert(ok and #events == 1 and events[1].latencyMs == 1, "ok and #events == 1 and events[1].latencyMs == 1")
		assert(
			serde.decode("json", events[1].serialized).data.quantity == 3,
			'serde.decode("json", events[1].serialized).data.quantity == 3'
		)
		fail = true
		assert(not backend.update("personal:1", function(value)
			value.data.quantity = 4
			return value
		end), 'not backend.update("personal:1", function(value) value.data.quantity = 4; return value end)')
		assert(#events == 1, "ambiguous commit cannot report acknowledged proof")
		local view = backend.observation()
		assert(
			#view.outcomes == 2 and view.outcomes[1].acknowledged and not view.outcomes[2].acknowledged,
			"failed ACK remains distinct outcome"
		)
		assert(view.outcomes[2].error == "LOST_ACK" and view.handledThrottleCount == nil, "no invented handling")
		view.identity.namespace = "forged"
		table.clear(view.records)
		assert(
			backend.observation().identity.namespace == "owned" and #backend.observation().records == 1,
			'backend.observation().identity.namespace == "owned" and #backend.observation().records == 1'
		)
	end,
}
