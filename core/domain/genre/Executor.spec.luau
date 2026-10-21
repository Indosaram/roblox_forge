--!strict
local Executor = require("./Executor")
local Contract = require("./Contract")
local Schema = require("../../infra/net/Schema")
local Clock = require("../../infra/genre/Clock")
local function fixture(): Contract.RuntimeContract
	return {
		api = 1,
		id = "counter",
		configVersion = 1,
		saveVersion = 1,
		actions = {
			{
				id = "add",
				args = { Schema.number({ min = 1, max = 2, integer = true }) },
				origin = "client",
				rate = { capacity = 5, refillPerSecond = 2 },
			},
			{ id = "reset", args = {}, origin = "server", rate = { capacity = 100, refillPerSecond = 100 } },
		},
		events = { "Changed" },
		hooks = { "Changed" },
		validateConfig = function(c)
			return if c.target == 2 then {} else { "target" }
		end,
		validateSave = function(s)
			return if type(s.count) == "number" and s.count >= 0 then {} else { "count" }
		end,
		create = function(_config, services)
			local state: { [string]: number } = {}
			return {
				join = function(id, save)
					state[id] = if save then save.count else 0
					return { ok = true }
				end,
				leave = function(id)
					state[id] = nil
				end,
				dispatch = function(id, action, args)
					state[id] = if action == "reset" then 0 else state[id] + args[1]
					services.emit({
						genre = "counter",
						name = "Changed",
						playerId = id,
						data = { count = state[id], epoch = services.now() },
					})
					return { ok = true }
				end,
				advance = function(_epoch) end,
				snapshot = function(id)
					return { count = state[id] }
				end,
				save = function(id)
					return { count = state[id] }
				end,
			}
		end,
	}
end
local function pack(): Contract.PackConfig
	return { api = 1, order = { "counter" }, configs = { counter = { target = 2 } } }
end
return {
	["millisecond boundaries preserve floor and agree between query and command"] = function()
		for _, sample in
			{
				{ 1.001, 1001 },
				{ 1.001 - 0.000001, 1000 },
				{ 1.001 - 2 ^ -52, 1000 },
				{ 1.0015, 1001 },
				{ 0.000999, 0 },
				{ 1790899200.001, 1790899200001 },
				{ 1790899200.001 - 0.00001, 1790899200000 },
				{ 0, 0 },
				{ -0.0001, -1 },
			}
		do
			assert(Clock.millis(sample[1]) == sample[2], "bounded millisecond floor")
			local runtime = fixture()
			local create = runtime.create
			local commandMillis, queryMillis = -1, -1
			runtime.create = function(config, services)
				local instance = create(config, services)
				instance.stageCommand = function(_, _, _, context)
					assert(context and context.nowMillis, "trusted clock")
					commandMillis = context.nowMillis
					return { result = { ok = true }, data = { count = 0 }, apply = function() end }
				end
				instance.pendingServerEvent = function(_, nowMillis)
					queryMillis = nowMillis
					return nil
				end
				return instance
			end
			local executor = Executor.new(pack(), { runtime }, {
				now = function()
					return sample[1]
				end,
				roll = function()
					return 0
				end,
				emit = function(_) end,
			})
			assert(executor.join("p").ok, "join")
			executor.pendingServerEvent("p", "counter:reset")
			local staged = executor.stageClient(
				"p",
				"counter:add",
				{ 1 },
				{ actorId = "p", sessionEpoch = 0, requestId = "clock" }
			)
			assert(staged and staged.result.ok, "stage")
			assert(commandMillis == sample[2] and queryMillis == commandMillis, "query and command use same boundary")
		end
	end,
	["event metadata and JSON nesting bounds reject invalid values"] = function()
		local servicesCaptured: Contract.Services? = nil
		local runtime = fixture()
		local original = runtime.create
		local authored = { version = 2 }
		runtime.create = function(config, services)
			servicesCaptured = services
			assert(services.survivalContent == authored, "authoritative content reaches the adapter unchanged")
			return original(config, services)
		end
		Executor.new(pack(), { runtime }, {
			survivalContent = authored,
			now = function()
				return 0
			end,
			roll = function()
				return 0
			end,
			emit = function(_e) end,
		})
		assert(servicesCaptured ~= nil, "services captured")
		local services = servicesCaptured :: Contract.Services
		for _, event in
			{
				{ genre = "unknown", name = "Changed", data = {} },
				{ genre = "counter", name = "Unknown", data = {} },
				{ genre = "counter", name = "Changed", playerId = string.rep("p", 257), data = {} },
				{ genre = "counter", name = "Changed", data = { n = math.huge } },
			}
		do
			assert(not pcall(services.emit, event :: any), "invalid event rejected")
		end
		local nested: any = {}
		for _ = 1, 17 do
			nested = { child = nested }
		end
		assert(not Executor.data(nested), "nesting limit")
		local large = {}
		for i = 1, 1025 do
			large[tostring(i)] = true
		end
		assert(not Executor.data(large), "map limit")
	end,
	["failed recipe join discards events and retains existing member"] = function()
		local first, second = fixture(), fixture()
		second.id = "partner"
		local emitted = 0
		second.recipe = {
			id = "pair-v1",
			partners = { "counter", "partner" },
			create = function(configs, services)
				local a = first.create(configs.counter, services)
				local b: Contract.Instance = {
					join = function(id, _save)
						services.emit({ genre = "partner", name = "Changed", playerId = id, data = {} })
						return { ok = id ~= "rejected" }
					end,
					leave = function(_id) end,
					dispatch = function(_id, _action, _args)
						return { ok = true }
					end,
					advance = function(_epoch) end,
					snapshot = function(_id)
						return {}
					end,
					save = function(_id)
						return { count = 0 }
					end,
				}
				return { counter = a, partner = b }
			end,
		}
		local executor = Executor.new({
			api = 1,
			order = { "counter", "partner" },
			configs = { counter = { target = 2 }, partner = { target = 2 } },
			recipe = "pair-v1",
		}, { first, second }, {
			now = function()
				return 0
			end,
			roll = function()
				return 0
			end,
			emit = function(_e)
				emitted += 1
			end,
		})
		assert(executor.join("existing").ok, "existing joins")
		assert(executor.dispatchClient("existing", "counter:add", { 2 }).ok, "existing state mutates")
		local before = emitted
		assert(not executor.join("rejected").ok, "second adapter rejects join")
		assert(emitted == before, "failed join events discarded")
		assert(executor.snapshot("existing").counter.count == 2, "existing member retained")
		assert(not executor.dispatchClient("rejected", "counter:add", { 1 }).ok, "failed join not a member")
	end,
	["ingress rejects malicious tuples without mutation and refills at exact clock"] = function()
		local now = 100
		local emitted = {}
		local executor = Executor.new(pack(), { fixture() }, {
			now = function()
				return now
			end,
			roll = function()
				return 0
			end,
			emit = function(e)
				table.insert(emitted, e)
			end,
		})
		assert(executor.join("p").ok, "contract assertion failed")
		for _, args in { {}, { 1, 2 }, { [2] = 1 }, { n = 1 }, { 0 / 0 }, { math.huge }, { 1.5 }, { 3 } } do
			assert(not executor.dispatchClient("p", "counter:add", args).ok, "contract assertion failed")
		end
		assert(not executor.dispatchClient("p", "counter:reset", {}).ok, "contract assertion failed")
		assert(not executor.dispatchClient("forged", "counter:add", { 1 }).ok, "contract assertion failed")
		assert(not executor.dispatchClient("p", string.rep("x", 129), {}).ok, "contract assertion failed")
		assert(executor.snapshot("p").counter.count == 0, "contract assertion failed")
		for _ = 1, 5 do
			assert(executor.dispatchClient("p", "counter:add", { 1 }).ok, "contract assertion failed")
		end
		assert(not executor.dispatchClient("p", "counter:add", { 1 }).ok, "contract assertion failed")
		now = 100.5
		assert(executor.dispatchClient("p", "counter:add", { 1 }).ok, "contract assertion failed")
		assert(emitted[#emitted].data.epoch == now, "contract assertion failed")
		assert(executor.dispatchServer("p", "counter:reset", {}).ok, "contract assertion failed")
	end,
	["save preflight is pure cloned and rejects future unknown and cyclic slices"] = function()
		local runtime = fixture()
		local executor = Executor.new(pack(), { runtime }, {
			now = function()
				return 0
			end,
			roll = function()
				return 0
			end,
			emit = function(_e) end,
		})
		assert(#Executor.validateSave({ version = 1, genres = {} }, { runtime }) == 0, "contract assertion failed")
		for _, envelope in
			{
				{ version = 2, genres = {} },
				{ version = 1, genres = { unknown = { version = 1, data = {} } } },
				{ version = 1, genres = { counter = { version = 2, data = { count = 1 } } } },
				{ version = 1, genres = { counter = { version = 1, data = { count = -1 } } } },
			}
		do
			assert(not executor.join("p", envelope :: any).ok, "contract assertion failed")
		end
		local saved = { version = 1, genres = { counter = { version = 1, data = { count = 2 } } } }
		assert(executor.join("p", saved).ok, "contract assertion failed")
		saved.genres.counter.data.count = 99
		local output = executor.save("p")
		output.genres.counter.data.count = 88
		assert(executor.snapshot("p").counter.count == 2, "contract assertion failed")
		assert(not executor.join("p").ok, "contract assertion failed")
		executor.leave("p")
		assert(not executor.dispatchClient("p", "counter:add", { 1 }).ok, "contract assertion failed")
		local cycle: any = {}
		cycle.self = cycle
		assert(not Executor.data(cycle), "contract assertion failed")
		assert(not Executor.data({ [1025] = true }), "contract assertion failed")
		assert(not Executor.data({ text = string.rep("x", 257) }), "contract assertion failed")
	end,
	["constructor rejects malformed runtime metadata without CLI"] = function()
		for _, mutate in
			{
				function(r: any)
					r.actions[1].origin = "evil"
				end,
				function(r: any)
					r.actions[1].args = { { kind = "function" } }
				end,
				function(r: any)
					r.id = "Bad:id"
				end,
				function(r: any)
					r.hooks = { "Unknown" }
				end,
				function(r: any)
					r.events = { "Bad:event" }
				end,
				function(r: any)
					r.actions = { [2] = r.actions[1] }
				end,
				function(r: any)
					r.actions[1].rate.capacity = math.huge
				end,
			}
		do
			local runtime = fixture()
			mutate(runtime)
			assert(not pcall(Executor.new, pack(), { runtime }, {
				now = function()
					return 0
				end,
				roll = function()
					return 0
				end,
				emit = function(_e) end,
			}), "contract assertion failed")
		end
	end,
	["hook failures surface after commit"] = function()
		local executor = Executor.new(pack(), { fixture() }, {
			now = function()
				return 0
			end,
			roll = function()
				return 0
			end,
			emit = function(_e) end,
		}, {
			["counter:Changed"] = function(_e)
				error("hook failure")
			end,
		})
		assert(executor.join("p").ok, "contract assertion failed")
		local ok, err = pcall(executor.dispatchClient, "p", "counter:add", { 1 })
		assert(not ok and string.find(tostring(err), "counter:Changed", 1, true), "contract assertion failed")
		assert(executor.snapshot("p").counter.count == 1, "contract assertion failed")
	end,
}
