--!strict
local Transport = require("../../../core/infra/genre/CommandTransport")
local Options = require("../../../core/infra/genre/Options")
local Session = require("../../../core/infra/genre/Session")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local Survival = require("../../../genres/survival-coop/module/Contract")
local Fixture = require("../../../genres/survival-coop/module/Adapter.fixture")
local Executor = require("../../../core/domain/genre/Executor")
local function options(): any
	local config = table.clone(Fixture.config)
	config.startingBalance = 100
	return {
		packConfig = { api = 1, order = { Survival.id }, configs = { [Survival.id] = config } },
		contracts = { Survival },
		controls = {},
		storeName = "TransportSpec",
		durable = { actions = { "survival-coop:buy-defense" } },
	}
end
return {
	["runtime trusted services reject clock encoder and fabricated callback overrides"] = function()
		local ports: { any } = {
			{
				now = function()
					return 0
				end,
			},
			{
				encode = function()
					return ""
				end,
			},
			{ survivalSpatial = { campfire = true } },
			{ survivalDeath = {
				worldRevision = "world",
				equipment = function()
					return {}
				end,
			} },
		}
		for _, services in ports do
			local input = options()
			input.services = services
			assert(not pcall(Options.validate, input), "untrusted services shape refused")
		end
		local input = options()
		input.services = { survivalSpatial = {
			campfire = function()
				return nil
			end,
		} }
		Options.validate(input)
	end,
	["Construction forwards trusted station port through actual server dispatch only"] = function()
		local input = options()
		local descriptor = table.clone(Survival)
		descriptor.actions = table.clone(Survival.actions)
		for index, action in descriptor.actions do
			if action.id == "buy-defense" then
				descriptor.actions[index] = table.clone(action)
				descriptor.actions[index].origin = "server"
			end
		end
		local calls = 0
		local station = { kind = "workbench", reachable = false }
		local port = {
			campfire = function(_id: string, _stationId: string)
				return nil
			end,
			station = function(id: string, stationId: string)
				assert(id == "1" and stationId == "bench", "server-owned spatial identity")
				calls += 1
				return station
			end,
		}
		local create = descriptor.create
		descriptor.create = function(config, services)
			assert(services.survivalSpatial == port, "Construction forwards complete trusted port")
			local instance = create(config, services)
			local dispatch = instance.dispatch
			instance.dispatch = function(id, action, args)
				local spatial = services.survivalSpatial
				assert(spatial and spatial.station, "station port available")
				assert(spatial.station(id, "bench") == station, "station result not fabricated or replaced")
				return dispatch(id, action, args)
			end
			return instance
		end
		local executor = Executor.new(input.packConfig, { descriptor }, {
			now = function()
				return 0
			end,
			roll = function()
				return 0
			end,
			emit = function() end,
			survivalSpatial = port,
		})
		assert(executor.join("1").ok, "join")
		assert(
			not executor.dispatchClient("1", "survival-coop:buy-defense", {}).ok and calls == 0,
			"client origin cannot invoke trusted action"
		)
		assert(
			executor.dispatchServer("1", "survival-coop:buy-defense", {}).ok and calls == 1,
			"actual server dispatch invokes forwarded port"
		)
		executor.leave("1")
	end,
	["runtime helper binds real actor and denies legacy durable bypass"] = function()
		local input = options()
		Options.validate(input)
		local session = Session.new(input, MemoryBackend.new(), {
			sessionId = "transport",
			lockTimeout = 120,
			retries = 0,
			now = function()
				return 0
			end,
		}, {
			now = function()
				return 0
			end,
			roll = function()
				return 0
			end,
			emit = function() end,
		}, input.durable)
		assert(session.join("1").ok, "join")
		assert(
			Transport.invoke(session, input.durable, "1", "survival-coop:buy-defense", {}).reason
				== "DURABLE_COMMAND_REQUIRED",
			"legacy bypass denied"
		)
		local request = Transport.request(
			nil,
			"survival-coop:buy-defense",
			{},
			session.commandEpoch("1") :: number,
			function()
				return "request"
			end
		)
		request.actorId = "2"
		assert(not Transport.invoke(session, input.durable, "1", "command", request).ok, "forged actor denied")
		request.actorId = nil
		local result = Transport.invoke(session, input.durable, "1", "command", request)
		assert(result.ok and result.stateVersion == 1, "actual durable Session called")
		assert(
			Transport.invoke(session, input.durable, "1", "command", request).stateVersion == 1,
			"same request replay"
		)
		assert(session.snapshot("1")[Survival.id].balance == 90, "one debit")
		assert(session.close("1").ok, "release")
	end,
	["client request owner retains ID across failures and retires only terminal outcome"] = function()
		local ids = 0
		local function nextId()
			ids += 1
			return tostring(ids)
		end
		local first = Transport.request(nil, "a", {}, 0, nextId)
		assert(Transport.request(first, "b", {}, 1, nextId) == first and ids == 1, "pending identity preserved")
		assert(Transport.settle(first, { ok = false, reason = "COMMIT_FAILED" }) == first, "failed save retained")
		assert(
			Transport.settle(first, { ok = false, reason = "COMMAND_PENDING" }) == first,
			"concurrent retry retained"
		)
		assert(Transport.settle(first, { ok = true, stateVersion = 1 }) == nil, "committed terminal")
		assert(Transport.settle(first, { ok = false, stateVersion = 2 }) == nil, "committed refusal terminal")
		assert(Transport.settle(first, { ok = false, reason = "REQUEST_EXPIRED" }) == nil, "explicit refresh terminal")
	end,
	["durable options closed boundary rejects malformed policy"] = function()
		local policies: { any } = {
			{ actions = { "survival-coop:buy-defense" }, extra = true },
			{ actions = { "missing:action" } },
			{ actions = { "survival-coop:buy-defense", "survival-coop:buy-defense" } },
			{ actions = {} },
			{ actions = { "survival-coop:buy-defense" }, windowSeconds = math.huge },
			{ actions = { "survival-coop:buy-defense" }, maxOutcomes = 4097 },
			{ actions = { "survival-coop:buy-defense" }, maxOutcomes = 1.5 },
		}
		for _, policy in policies do
			local input = options()
			input.durable = policy
			assert(not pcall(Options.validate, input), "invalid policy refused")
		end
	end,
}
