--!strict
local Runtime = require("./SettlementRuntime")
local Settlement = require("../../../core/domain/settlement/Settlement")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local FencedStore = require("../../../core/infra/data/FencedStore")
local ItemTransfer = require("../../../core/infra/data/ItemTransfer")
local harness = require("../../../cli/forge/lib/qaharness")
local Ledger = require("../../../core/domain/command/Ledger")
local Shared = require("../../../core/domain/genre/Contract")
local Content = require("../../../core/domain/survival/Content")
local Job = require("../../../core/domain/crafting/Job")
local Workshop = require("./Workshop")
local Bridge = require("./SettlementBridge")
local serde = require("@lune/serde")
local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000 } })
local function config(now: () -> number): Runtime.Config
	local warehouse = Inventory.new("warehouse", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	warehouse = assert(Inventory.add(warehouse, catalog, {
		itemId = "wood",
		catalogId = "wood",
		quantity = 10,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = {},
	}, 0))
	return {
		key = "tribe",
		now = now,
		catalog = catalog,
		windowSeconds = 10,
		maxOutcomes = 20,
		initial = {
			settlement = Settlement.new(
				{ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 },
				"owner"
			),
			warehouse = warehouse,
		},
		definitions = {
			bench = { id = "bench", footprintX = 2, footprintZ = 3, cost = { { item = "wood", quantity = 5 } } },
		},
	}
end
local function command(
	runtime: Runtime.Runtime,
	actor: string,
	id: string,
	action: string,
	args: { any },
	epoch: number?
): Shared.Result
	return runtime.command(actor, action, args, { actorId = actor, requestId = id, sessionEpoch = epoch or 0 })
end
local function setup(): (Runtime.Runtime, Runtime.Config, harness.Barrier)
	local cfg = config(function()
		return 0
	end)
	local gate = harness.barrier()
	local runtime =
		assert(Runtime.new(cfg, FencedStore.new(gate.backend, { sessionId = "a", leaseSeconds = 120, now = cfg.now })))
	assert(runtime.epoch("owner") == 0, "owner epoch")
	return runtime, cfg, gate
end
return {
	["overlapping snapshot renews never stack durable transport calls"] = function()
		local cfg = config(function()
			return 0
		end)
		local stored: any = nil
		local calls = 0
		local parkNext = false
		local backend: any = {
			update = function(_key: string, transform: (any) -> any): (boolean, any)
				calls += 1
				if parkNext then
					parkNext = false
					coroutine.yield("renew-parked")
				end
				stored = transform(stored)
				return true, stored
			end,
		}
		local runtime =
			assert(Runtime.new(cfg, FencedStore.new(backend, { sessionId = "a", leaseSeconds = 120, now = cfg.now })))
		assert(runtime.epoch("owner") == 0, "owner epoch")
		local base = calls
		-- The first snapshot performs the real post-acquire renew and parks in
		-- the backend, exactly like a slow transport during the join era.
		parkNext = true
		local firstThread = coroutine.create(function()
			return runtime.snapshot("owner")
		end)
		local ok1, parked = coroutine.resume(firstThread)
		assert(ok1 and parked == "renew-parked", "first snapshot parks inside the renew")
		assert(calls == base + 1, "exactly one durable renew in flight")
		-- A per-frame caller arriving mid-renew must not stack another renew.
		local concurrent = runtime.snapshot("owner")
		assert(concurrent ~= nil, "overlapping snapshot serves the in-memory aggregate")
		assert(calls == base + 1, "overlapping snapshot performs no durable call")
		local ok2, state = coroutine.resume(firstThread)
		assert(ok2 and state ~= nil, "parked snapshot completes")
		local after = runtime.snapshot("owner")
		assert(after ~= nil, "snapshot after renew returns state")
		assert(calls == base + 1, "healthy lease keeps the renew skip intact")
	end,
	["failed snapshot renew backs off instead of retrying per frame"] = function()
		local now = 0
		local cfg = config(function()
			return now
		end)
		local stored: any = nil
		local calls = 0
		local failNext = false
		local backend: any = {
			update = function(_key: string, transform: (any) -> any): (boolean, any)
				calls += 1
				if failNext then
					failNext = false
					return false, "renew transport failed"
				end
				stored = transform(stored)
				return true, stored
			end,
		}
		local runtime =
			assert(Runtime.new(cfg, FencedStore.new(backend, { sessionId = "a", leaseSeconds = 120, now = cfg.now })))
		assert(runtime.epoch("owner") == 0, "owner epoch")
		assert(runtime.snapshot("owner") ~= nil, "initial snapshot renews once")
		local base = calls
		-- Past half the lease the skip no longer applies, so this renew is real.
		failNext = true
		now = 70
		local failed = runtime.snapshot("owner")
		assert(failed == nil, "renew failure surfaces")
		assert(calls == base + 1, "exactly one failed attempt")
		for _ = 1, 5 do
			assert(runtime.snapshot("owner") ~= nil, "in-memory snapshot keeps serving")
		end
		assert(calls == base + 1, "cooldown absorbs per-frame retries")
		now = 71
		local recovered = runtime.snapshot("owner")
		assert(recovered ~= nil, "renew retries after the cooldown")
		assert(calls == base + 2, "exactly one retry once the cooldown lapses")
	end,
	["postcommit publisher failure recovers on snapshot without another debit"] = function()
		local cfg = config(function()
			return 0
		end)
		local fail, instances = false, {}
		local creates = 0
		cfg.publish = function(state)
			if fail then
				error("PUBLISH_FAILED")
			end
			for id in state.structures do
				if not instances[id] then
					instances[id], creates = true, creates + 1
				end
			end
		end
		local runtime = assert(
			Runtime.new(
				cfg,
				FencedStore.new(
					harness.barrier().backend,
					{ sessionId = "publication", leaseSeconds = 120, now = cfg.now }
				)
			)
		)
		assert(runtime.epoch("owner") == 0, "epoch starts at zero")
		local reserved = command(runtime, "owner", "reserve", "reserve", { "bench", 4, 4, 0, 0, 1, 0 })
		local id = assert(reserved.data).reservationId
		fail = true
		local placed = command(runtime, "owner", "place", "place", { id, 1, 2 })
		assert(
			placed.ok and assert(placed.data).notificationError and creates == 0,
			"placed.ok and assert(placed.data).notificationError and creates == 0"
		)
		assert(runtime.snapshot("owner") == nil, "missing projection not silently reported available")
		fail = false
		assert(
			assert(runtime.snapshot("owner")).warehouse.items.wood.quantity == 5,
			"warehouse wood preserved after placement"
		)
		assert(creates == 1 and instances["tribe:" .. id], 'creates == 1 and instances["tribe:" .. id]')
		assert(
			command(runtime, "owner", "place", "place", { id, 1, 2 }).ok,
			'command(runtime, "owner", "place", "place", { id, 1, 2 }).ok'
		)
		assert(
			assert(runtime.snapshot("owner")).warehouse.items.wood.quantity == 5 and creates == 1,
			'assert(runtime.snapshot("owner")).warehouse.items.wood.quantity == 5 and creates == 1'
		)
		assert(runtime.close().ok, "runtime closes cleanly")
	end,
	["accepted membership initialization survives restart without reinstating departed members"] = function()
		local cfg = config(function()
			return 0
		end)
		cfg.acceptedMembers = { "member" }
		local gate = harness.barrier()
		local function open()
			return assert(
				Runtime.new(
					cfg,
					FencedStore.new(gate.backend, { sessionId = "provision", leaseSeconds = 120, now = cfg.now })
				)
			)
		end
		local runtime = open()
		assert(
			assert(runtime.snapshot("member")).settlement.membershipRevision == 1,
			'assert(runtime.snapshot("member")).settlement.membershipRevision == 1'
		)
		assert(runtime.epoch("owner") == 0, "epoch starts at zero")
		assert(
			command(runtime, "owner", "kick", "kick", { "member", 1, 1 }).ok,
			'command(runtime, "owner", "kick", "kick", { "member", 1, 1 }).ok'
		)
		assert(runtime.close().ok, "runtime closes cleanly")
		runtime = open()
		assert(runtime.snapshot("member") == nil, "restart cannot undo kick")
		assert(
			assert(runtime.snapshot("owner")).settlement.membershipRevision == 2,
			'assert(runtime.snapshot("owner")).settlement.membershipRevision == 2'
		)
		assert(runtime.close().ok, "runtime closes cleanly")
	end,
	["lost provisioning acknowledgement and voluntary leave never grant membership twice"] = function()
		local cfg = config(function()
			return 0
		end)
		cfg.acceptedMembers = { "member" }
		local gate = harness.barrier()
		local lose = true
		local backend = {
			update = function(key, transform)
				local ok, result = gate.backend.update(key, transform)
				if lose then
					lose = false
					return false, "LOST_ACK"
				end
				return ok, result
			end,
		}
		local function open()
			return Runtime.new(
				cfg,
				FencedStore.new(backend, { sessionId = "provision", leaseSeconds = 120, now = cfg.now })
			)
		end
		assert(open() == nil, "no acknowledgement on failed acquire")
		local runtime = assert(open())
		assert(assert(runtime.snapshot("member")).settlement.membershipRevision == 1, "grant not repeated")
		assert(runtime.epoch("member") == 0, 'runtime.epoch("member") == 0')
		assert(
			command(runtime, "member", "leave", "leave", { "member", 1, 1 }).ok,
			'command(runtime, "member", "leave", "leave", { "member", 1, 1 }).ok'
		)
		assert(runtime.close().ok, "runtime closes cleanly")
		runtime = assert(open())
		assert(runtime.snapshot("member") == nil, "leave remains durable")
		assert(runtime.close().ok, "runtime closes cleanly")
	end,
	["placement checks commit geometry but replay keeps original outcome and quantity"] = function()
		local cfg = config(function()
			return 0
		end)
		local reachable = true
		local published: Settlement.State? = nil
		cfg.verifyPlacement = function(actor, placement)
			assert(
				actor == "owner" and placement.entry.x == 4 and placement.entry.z == 3,
				'actor == "owner" and placement.entry.x == 4 and placement.entry.z == 3'
			)
			return reachable
		end
		cfg.publish = function(state)
			published = state
		end
		local gate = harness.barrier()
		local runtime = assert(
			Runtime.new(
				cfg,
				FencedStore.new(gate.backend, { sessionId = "spatial", leaseSeconds = 120, now = cfg.now })
			)
		)
		assert(runtime.epoch("owner") == 0, "epoch starts at zero")
		reachable = false
		assert(
			command(runtime, "owner", "far", "reserve", { "bench", 4, 4, 0, 0, 1, 0 }).reason == "PLACEMENT_UNREACHABLE",
			'command(runtime, "owner", "far", "reserve", { "bench", 4, 4, 0, 0, 1, 0 }).reason == "PLACEMENT_UNREACHABLE"'
		)
		assert(
			next(assert(runtime.snapshot("owner")).warehouse.reservations) == nil,
			'next(assert(runtime.snapshot("owner")).warehouse.reservations) == nil'
		)
		reachable = true
		local reserved = command(runtime, "owner", "reserve", "reserve", { "bench", 4, 4, 0, 0, 1, 0 })
		local id = assert(reserved.data).reservationId
		assert(next(assert(published).structures) == nil, "reserved ghost is not built")
		gate.suspend()
		local result: Shared.Result? = nil
		local worker = coroutine.create(function()
			result = command(runtime, "owner", "moved", "place", { id, 1, 2 })
		end)
		local ok, signal = coroutine.resume(worker)
		assert(ok and signal == "commit-barrier-entered", 'ok and signal == "commit-barrier-entered"')
		reachable = false
		gate.resume()
		assert(coroutine.resume(worker))
		assert(assert(result).reason == "PLACEMENT_UNREACHABLE", 'assert(result).reason == "PLACEMENT_UNREACHABLE"')
		assert(
			assert(runtime.snapshot("owner")).warehouse.items.wood.quantity == 10,
			'assert(runtime.snapshot("owner")).warehouse.items.wood.quantity == 10'
		)
		reachable = true
		local placed = command(runtime, "owner", "place", "place", { id, 1, 2 })
		assert(
			placed.ok and assert(published).structures["tribe:" .. id],
			'placed.ok and assert(published).structures["tribe:" .. id]'
		)
		reachable = false
		assert(
			Ledger.canonical(command(runtime, "owner", "place", "place", { id, 1, 2 })) == Ledger.canonical(placed),
			'Ledger.canonical(command(runtime, "owner", "place", "place", { id, 1, 2 })) == Ledger.canonical(placed)'
		)
		assert(
			assert(runtime.snapshot("owner")).warehouse.items.wood.quantity == 5,
			"warehouse wood preserved after placement"
		)
		assert(runtime.close().ok, "runtime closes cleanly")
		published = nil
		runtime = assert(
			Runtime.new(
				cfg,
				FencedStore.new(gate.backend, { sessionId = "spatial", leaseSeconds = 120, now = cfg.now })
			)
		)
		assert(assert(published).structures["tribe:" .. id], "restart reconstructs confirmed building")
		assert(
			command(runtime, "owner", "demolish", "demolish", { "tribe:" .. id, 2, 3, 0 }).ok,
			'command(runtime, "owner", "demolish", "demolish", { "tribe:" .. id, 2, 3, 0 }).ok'
		)
		assert(next(assert(published).structures) == nil, "demolition removes projection only after commit")
		assert(runtime.close().ok, "runtime closes cleanly")
	end,
	["shared workshop owner restart replay recovery and reservation conservation"] = function()
		local now = 0
		local cfg = config(function()
			return now
		end)
		local content = assert(Content.canonicalize({
			survival_content = 1,
			rules = table.clone(Content.RULES),
			limits = table.clone(Content.DEFAULT_LIMITS),
			tags = {},
			structures = {
				{
					id = "bench",
					footprintX = 1,
					footprintZ = 1,
					station = true,
					cost = { { item = "wood", quantity = 1 } },
				},
			},
			items = {
				{ id = "wood", name = "Wood", stackMax = 100, weightMilli = 1000 },
				{ id = "cord", name = "Cord", stackMax = 100, weightMilli = 1000 },
			},
			recipes = {
				{
					id = "cord",
					craftMillis = 1000,
					inputs = { { item = "wood", quantity = 3 } },
					outputs = { { item = "cord", quantity = 1 } },
					station = "bench",
				},
			},
		}))
		cfg.catalog = Job.catalog(content)
		cfg.initial.warehouse.limits.slots = 2
		cfg.initial.warehouse = assert(Inventory.add(cfg.initial.warehouse, cfg.catalog, {
			itemId = "blocker",
			catalogId = "cord",
			quantity = 1,
			qualityMilli = 2000,
			durabilityMilli = 0,
			attributes = {},
		}, cfg.initial.warehouse.version))
		cfg.maxOutcomes = 4096
		cfg.workshop = {
			content = content,
			revision = "v1",
			verifyStation = function(_, station, state): Workshop.Access?
				if station ~= "bench-1" then
					return nil
				end
				local access: Workshop.Access = {
					carriedContainer = state.warehouse.id,
					stationId = station,
					stationKind = "bench",
					inReach = true,
				}
				return access
			end,
		}
		local gate = harness.barrier()
		local replay, lost = false, false
		local calls = 0
		local backend = {
			update = function(key: string, transform: (any) -> any): (boolean, any)
				if replay then
					replay = false
					gate.backend.update(key, function(old)
						calls += 1
						transform(old)
						return old
					end)
				end
				local ok, result = gate.backend.update(key, transform)
				if lost then
					lost = false
					return false, "lost ACK"
				end
				return ok, result
			end,
		}
		local runtime = assert(
			Runtime.new(cfg, FencedStore.new(backend, { sessionId = "craft", leaseSeconds = 120, now = cfg.now }))
		)
		local bridge = Bridge.new({
			resolve = function()
				return runtime
			end,
			authorize = function()
				return { ok = true }
			end,
		})
		assert(assert(runtime.epochWindow("owner")).expiresAt == 10, "public authoritative window")
		local function args(first: string, second: string): { any }
			local state = assert(runtime.snapshot("owner"))
			return {
				first,
				second,
				state.settlement.version,
				state.warehouse.version,
				state.settlement.membershipRevision,
			}
		end
		local function craft(id: string, action: string, values: { any }, actor: string?): Shared.Result
			local who = actor or "owner"
			return bridge.command(
				who,
				"survival-coop:settlement-workshop-" .. action,
				values,
				{ actorId = who, requestId = id, sessionEpoch = 0 },
				"server"
			)
		end
		local reservedArgs = args("cord", "bench-1")
		replay = true
		local reserved = craft("reserve", "reserve", reservedArgs)
		assert(reserved.ok and reserved.data and calls == 1, "callback retry reserves once")
		local id = reserved.data.jobId
		for _ = 1, 100 do
			assert(
				Ledger.canonical(craft("reserve", "reserve", reservedArgs)) == Ledger.canonical(reserved),
				"100 exact retries"
			)
		end
		assert(craft("reserve", "reserve", args("cord", "forged")).reason == "REQUEST_CONFLICT", "changed payload")
		assert(
			craft("station", "reserve", args("cord", "forged")).reason == "STATION_UNAVAILABLE",
			"trusted station proof"
		)
		local startArgs = args(id, "owner")
		-- Skip bridge refresh and lose the actual mutation ACK through direct owner command.
		lost = true
		assert(not command(runtime, "owner", "start", "workshop-start", startArgs).ok, "lost ACK")
		assert(command(runtime, "owner", "start", "workshop-start", startArgs).ok, "receipt recovers lost ACK")
		assert(
			assert(assert(runtime.snapshot("owner")).workshops).owner.entries[id].job.finishAt == 1000,
			"integer pinned deadline"
		)
		assert(runtime.close().ok, "close before restart")
		local durable = serde.decode("json", serde.encode("json", gate.snapshot()))
		local forged = serde.decode("json", serde.encode("json", durable))
		forged.tribe.data.aggregate.warehouse.reservations[id].wood = 1
		assert(
			not pcall(
				Runtime.new,
				cfg,
				FencedStore.new(
					harness.barrier(forged).backend,
					{ sessionId = "bad", leaseSeconds = 120, now = cfg.now }
				)
			),
			"forged reservation rejected"
		)
		gate = harness.barrier(durable)
		runtime = assert(
			Runtime.new(
				cfg,
				FencedStore.new(gate.backend, { sessionId = "restart", leaseSeconds = 120, now = cfg.now })
			)
		)
		now = 1
		local full = craft("full", "complete", args(id, "owner"))
		assert(full.ok and full.reason == "FULL_SLOTS", "Ready candidate persisted with full warehouse")
		local ready = assert(runtime.snapshot("owner"))
		assert(
			assert(ready.workshops).owner.entries[id].job.state == "Ready" and ready.warehouse.items.wood.quantity == 10,
			"Ready preserves ingredients"
		)
		local port = runtime.transferStore()
		local personalStore =
			FencedStore.new(gate.backend, { sessionId = "personal", leaseSeconds = 120, now = cfg.now })
		local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		local personal = assert(personalStore:acquire("personal", function()
			return { inventory = Inventory.save(bag) }
		end))
		local router: ItemTransfer.StorePort = {
			update = function(_, profile, transform)
				return if profile.key == "tribe"
					then port:update(profile, transform)
					else personalStore:update(profile, transform)
			end,
			acquire = function(_, key, transform)
				return if key == "tribe" then port:acquire(key, transform) else personalStore:acquire(key, transform)
			end,
		}
		local transfer = ItemTransfer.new(router, cfg.catalog, {
			maxReceipts = 20,
			now = cfg.now,
			authorize = function()
				return true
			end,
		})
		local request: ItemTransfer.Request = {
			id = "unblock",
			actor = "owner",
			epoch = "0",
			expiresAt = 10,
			source = "tribe",
			destination = "personal",
			itemId = "blocker",
			outputId = "blocker",
			quantity = 1,
		}
		local moved = transfer:advance(port.profile(), personal, request, {})
		for _, phase in { "ESCROWED", "CREDITED", "FINALIZED" } do
			moved = transfer:advance(moved.source, moved.destination, request, {})
			assert(moved.phase == phase, "actual transfer phase " .. phase .. ": " .. Ledger.canonical(moved))
		end
		assert(moved.destination.data.inventory.items.blocker.quantity == 1, "actual transfer frees output slot")
		assert(
			assert(runtime.snapshot("owner")).warehouse.reservations[id].wood == 3,
			"transfer preserves workshop reservation"
		)
		local transferReceipts = Ledger.canonical(gate.snapshot().tribe.data.itemTransfers)
		assert(craft("complete", "complete", args(id, "owner")).ok, "restart completes pinned job")
		assert(
			Ledger.canonical(gate.snapshot().tribe.data.itemTransfers) == transferReceipts,
			"workshop preserves current transfer envelope"
		)
		assert(craft("complete-new", "complete", args(id, "owner")).reason == "ALREADY_COMMITTED", "complete once")
		assert(assert(runtime.snapshot("owner")).warehouse.items.wood.quantity == 7, "one debit")
		assert(command(runtime, "owner", "invite", "invite", { "member", 0, 0 }).ok, "invite")
		assert(runtime.epoch("member") == 0, "member epoch")
		local member = craft("member-job", "reserve", args("cord", "bench-1"), "member")
		assert(member.ok and member.data, "member reservation")
		local memberId = member.data.jobId
		local pending: Shared.Result? = nil
		local memberArgs = args(memberId, "member")
		gate.suspend()
		local worker = coroutine.create(function()
			pending = command(runtime, "member", "start", "workshop-start", memberArgs)
		end)
		local ok, signal = coroutine.resume(worker)
		assert(ok and signal == "commit-barrier-entered", "member commit barrier")
		assert(command(runtime, "owner", "kick", "kick", { "member", 1, 1 }).ok, "kick")
		gate.resume()
		assert(coroutine.resume(worker))
		assert(pending and pending.reason == "FORBIDDEN", "kick wins commit")
		assert(craft("recover", "cancel", args(memberId, "member")).ok, "owner releases kicked author reservation")
		assert(craft("recover-new", "cancel", args(memberId, "member")).reason == "ALREADY_CANCELLED", "cancel once")
		local buildArgs: { any } = { "bench", 4, 4, 0, 2, assert(runtime.snapshot("owner")).warehouse.version, 2 }
		gate.suspend()
		local build: Shared.Result? = nil
		worker = coroutine.create(function()
			build = command(runtime, "owner", "build", "reserve", buildArgs)
		end)
		ok, signal = coroutine.resume(worker)
		assert(ok and signal == "commit-barrier-entered", "build commit barrier")
		assert(craft("competing", "reserve", args("cord", "bench-1")).ok, "concurrent craft")
		gate.resume()
		assert(coroutine.resume(worker))
		assert(build and build.reason == "STALE_WAREHOUSE_VERSION", "concurrent craft wins warehouse version")
		assert(
			Inventory.available(assert(runtime.snapshot("owner")).warehouse, "wood") == 4,
			"shared reservations conserve inventory"
		)
		now = 12
		assert(runtime.epoch("owner") == 1, "receipt floor advances")
		assert(runtime.epochWindow("owner", 0) == nil, "old window unavailable")
		local retained = assert(assert(runtime.snapshot("owner")).workshops).owner.entries
		assert(retained[id] == nil, "terminal pruned beyond receipt horizon")
		local activeCount = 0
		for _, entry in retained do
			assert(entry.job.state == "Reserved", "only active survives")
			activeCount += 1
		end
		assert(activeCount == 1, "active never pruned")
		local fresh = assert(
			Runtime.new(
				cfg,
				FencedStore.new(gate.backend, { sessionId = "restart", leaseSeconds = 120, now = cfg.now })
			)
		)
		assert(
			not command(runtime, "owner", "fenced", "workshop-reserve", { "cord", "bench-1", 2, 7, 2 }).ok,
			"lease fencing"
		)
		assert(fresh.close().ok, "close replacement")
	end,
	["transfer callback replay rereads current warehouse and installs only confirmed state"] = function()
		local cfg = config(function()
			return 0
		end)
		local gate = harness.barrier()
		local replay = false
		local calls = 0
		local backend = {
			update = function(key: string, transform: (any) -> any): (boolean, any)
				if replay then
					replay = false
					gate.backend.update(key, function(old)
						transform(old)
						return old
					end)
				end
				return gate.backend.update(key, transform)
			end,
		}
		local runtime =
			assert(Runtime.new(cfg, FencedStore.new(backend, { sessionId = "a", leaseSeconds = 120, now = cfg.now })))
		local port = runtime.transferStore()
		replay = true
		assert(port:update(port.profile(), function(data)
			calls += 1
			local inventory = Inventory.fromSave(data.inventory, catalog)
			local consumed = assert(Inventory.consume(inventory, "wood", 3, inventory.version))
			data.inventory = Inventory.save(consumed)
			return data
		end))
		assert(calls == 2, "actual store transform replayed")
		assert(
			assert(runtime.snapshot("owner")).warehouse.items.wood.quantity == 7,
			"discarded callback cannot double debit"
		)
		gate.fail(1)
		assert(port:update(port.profile(), function(data)
			data.inventory.items.wood.quantity = 1
			return data
		end) == nil, "failed backend cannot publish")
		assert(port.profile().data.inventory.items.wood.quantity == 7, "installed owner snapshot preserved")
	end,
	["restore rejects forged refund and ingredient ownership before acquire publishes"] = function()
		local runtime, cfg, gate = setup()
		local reserved = command(runtime, "owner", "reserved", "reserve", { "bench", 4, 4, 0, 0, 1, 0 })
		assert(reserved.ok and reserved.data, "reserved")
		local id = reserved.data.reservationId
		assert(runtime.close().ok, "release")
		for _, kind in { "cost", "quantity", "missing", "orphan" } do
			local durable = gate.snapshot()
			local aggregate = durable.tribe.data.aggregate
			if kind == "cost" then
				aggregate.settlement.reservations[id].definition.cost[1].quantity = 999
			elseif kind == "quantity" then
				aggregate.warehouse.reservations[id].wood = 4
			elseif kind == "missing" then
				aggregate.warehouse.reservations[id] = nil
			else
				aggregate.settlement.reservations[id] = nil
			end
			local invalid = harness.barrier(durable)
			local before = Ledger.canonical(invalid.snapshot())
			assert(
				not pcall(
					Runtime.new,
					cfg,
					FencedStore.new(invalid.backend, { sessionId = "restore", leaseSeconds = 120, now = cfg.now })
				),
				"forged restore refused"
			)
			assert(Ledger.canonical(invalid.snapshot()) == before, "no acquisition or forged state published")
		end
		local restored = assert(
			Runtime.new(
				cfg,
				FencedStore.new(
					harness.barrier(gate.snapshot()).backend,
					{ sessionId = "valid", leaseSeconds = 120, now = cfg.now }
				)
			)
		)
		assert(command(restored, "owner", "place", "place", { id, 1, 2 }).ok, "valid reservation restores and commits")
	end,
	["real transfer warehouse lens preserves tribe state and cleanup installs generation"] = function()
		local now = 0
		local cfg = config(function()
			return now
		end)
		local proof = {}
		cfg.verifyTransfer = function(actor, supplied)
			return actor == "owner" and supplied == proof
		end
		local gate = harness.barrier()
		local store = FencedStore.new(gate.backend, { sessionId = "transfer", leaseSeconds = 120, now = cfg.now })
		local runtime = assert(Runtime.new(cfg, store))
		assert(runtime.epoch("owner") == 0, "epoch")
		local port = runtime.transferStore()
		local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		local personal = assert(store:acquire("personal", function()
			return { inventory = Inventory.save(bag) }
		end))
		local router: ItemTransfer.StorePort = {
			update = function(_, profile, transform)
				return if profile.key == "tribe"
					then port:update(profile, transform)
					else store:update(profile, transform)
			end,
			acquire = function(_, key, transform)
				return if key == "tribe" then port:acquire(key, transform) else store:acquire(key, transform)
			end,
		}
		local transfer = ItemTransfer.new(router, catalog, {
			maxReceipts = 20,
			now = cfg.now,
			authorize = function(req, supplied, data)
				return port.authority(data, req.actor, tonumber(req.epoch) :: number, 0, supplied)
			end,
		})
		local req: ItemTransfer.Request = {
			id = "transfer",
			actor = "owner",
			epoch = "0",
			expiresAt = 10,
			source = "tribe",
			destination = "personal",
			itemId = "wood",
			outputId = "moved",
			quantity = 3,
		}
		local source = port.profile()
		local result = transfer:advance(source, personal, req, proof)
		assert(result.phase == "PREPARED", "reserve warehouse")
		for _, phase in { "ESCROWED", "CREDITED", "FINALIZED" } do
			result = transfer:advance(result.source, result.destination, req, proof)
			assert(result.phase == phase, "real transfer phase")
		end
		assert(result.status == "confirmed", "confirmed")
		local state = assert(runtime.snapshot("owner"))
		assert(
			state.warehouse.items.wood.quantity == 7 and result.destination.data.inventory.items.moved.quantity == 3,
			"ten units conserved"
		)
		assert(state.settlement.roles.owner == "owner" and state.settlement.version == 0, "grid membership preserved")
		local old = port.profile()
		local acquired = assert(port:acquire("tribe", function(data)
			data.authority.roles.owner = nil
			return data
		end))
		assert(acquired.generation == old.generation + 1, "cleanup acquisition advances generation")
		assert(port:update(old, function(data)
			return data
		end) == nil, "stale projected token refused")
		assert(
			assert(runtime.snapshot("owner")).settlement.roles.owner == "owner",
			"projection cannot mutate authority"
		)
		now = 10
		local cleaned = transfer:cleanup(port.profile(), result.destination, req)
		assert(cleaned.status == "confirmed", cleaned.error)
		assert(runtime.epoch("owner") == 1, "owner continues after transfer cleanup")
	end,
	["transfer source callback sees revocation at exact commit barrier"] = function()
		local cfg = config(function()
			return 0
		end)
		local proof = {}
		cfg.verifyTransfer = function(_, supplied)
			return supplied == proof
		end
		local gate = harness.barrier()
		local runtime = assert(
			Runtime.new(cfg, FencedStore.new(gate.backend, { sessionId = "a", leaseSeconds = 120, now = cfg.now }))
		)
		assert(runtime.epoch("owner") == 0, "owner epoch")
		assert(command(runtime, "owner", "invite", "invite", { "member", 0, 0 }).ok, "invite")
		assert(runtime.epoch("member") == 0, "member epoch")
		local port = runtime.transferStore()
		local before = port.profile()
		local allowed = true
		gate.suspend()
		local worker = coroutine.create(function()
			assert(port:update(before, function(data)
				allowed = port.authority(data, "member", 0, 1, proof)
				return data
			end))
		end)
		local ok, signal = coroutine.resume(worker)
		assert(ok and signal == "commit-barrier-entered", "exact boundary")
		assert(command(runtime, "owner", "kick", "kick", { "member", 1, 1 }).ok, "revoked durably")
		gate.resume()
		assert(coroutine.resume(worker))
		assert(coroutine.status(worker) == "dead" and not allowed, "current callback refuses old membership proof")
		assert(not port.authority(port.profile().data, "owner", 0, 2, true), "client boolean is not server proof")
		assert(assert(runtime.snapshot("owner")).warehouse.items.wood.quantity == 10, "unchanged")
	end,
	["restored 128 build demolition cycles prune only beyond receipt floor and continue"] = function()
		local now = 0
		local cfg = config(function()
			return now
		end)
		cfg.maxOutcomes = 4096
		cfg.definitions.bench.cost = {}
		local gate = harness.barrier()
		local runtime = assert(
			Runtime.new(cfg, FencedStore.new(gate.backend, { sessionId = "a", leaseSeconds = 120, now = cfg.now }))
		)
		assert(runtime.epoch("owner") == 0, "epoch")
		local function cycle(index: number, epoch: number)
			local state = assert(runtime.snapshot("owner"))
			local reserved = command(runtime, "owner", "reserve-" .. index, "reserve", {
				"bench",
				4,
				4,
				0,
				state.settlement.version,
				state.warehouse.version,
				state.settlement.membershipRevision,
			}, epoch)
			assert(reserved.ok and reserved.data, "reserve cycle")
			local id = reserved.data.reservationId
			state = assert(runtime.snapshot("owner"))
			assert(
				command(
					runtime,
					"owner",
					"place-" .. index,
					"place",
					{ id, state.settlement.version, state.warehouse.version },
					epoch
				).ok,
				"place cycle"
			)
			state = assert(runtime.snapshot("owner"))
			assert(
				command(runtime, "owner", "demolish-" .. index, "demolish", {
					"tribe:" .. id,
					state.settlement.version,
					state.warehouse.version,
					state.settlement.membershipRevision,
				}, epoch).ok,
				"demolish cycle"
			)
		end
		for index = 1, 128 do
			cycle(index, 0)
		end
		assert(runtime.close().ok, "release for restore")
		runtime = assert(
			Runtime.new(
				cfg,
				FencedStore.new(
					harness.barrier(gate.snapshot()).backend,
					{ sessionId = "b", leaseSeconds = 120, now = cfg.now }
				)
			)
		)
		local state = assert(runtime.snapshot("owner"))
		local retained = 0
		for _ in state.settlement.usedIds do
			retained += 1
		end
		assert(retained == 128, "active receipts retain all 128 identities after restore")
		local active = command(
			runtime,
			"owner",
			"active",
			"reserve",
			{ "bench", 4, 4, 0, state.settlement.version, state.warehouse.version, 0 }
		)
		assert(active.ok and active.data, "active reservation")
		now = 10
		assert(runtime.epoch("owner") == 1, "safe cutoff")
		state = assert(runtime.snapshot("owner"))
		assert(state.settlement.usedIds[active.data.reservationId], "active reservation identity retained")
		retained = 0
		for _ in state.settlement.usedIds do
			retained += 1
		end
		assert(retained == 1, "retired ids pruned after ledger floor")
		assert(
			command(
				runtime,
				"owner",
				"expired",
				"cancel",
				{ active.data.reservationId, state.settlement.version, state.warehouse.version }
			).reason == "REQUEST_EXPIRED",
			"expired unknown remains refused"
		)
		assert(
			command(
				runtime,
				"owner",
				"cancel-active",
				"cancel",
				{ active.data.reservationId, state.settlement.version, state.warehouse.version },
				1
			).ok,
			"release active"
		)
		cycle(129, 1)
	end,
	["warehouse build and refund commit with bound replay receipts across reconstruction"] = function()
		local runtime, cfg, gate = setup()
		cfg.definitions.bench.cost[1].quantity = 999
		local reserved = command(runtime, "owner", "reserve", "reserve", { "bench", 4, 4, 0, 0, 1, 0 })
		assert(reserved.ok and reserved.data, "canonical pinned definition")
		local id = reserved.data.reservationId
		local placed = command(runtime, "owner", "place", "place", { id, 1, 2 })
		assert(placed.ok, placed.reason)
		local replay = command(runtime, "owner", "place", "place", { id, 1, 2 })
		assert(Ledger.canonical(replay) == Ledger.canonical(placed), "exact receipt replay")
		assert(
			command(runtime, "owner", "place", "cancel", { id, 1, 2 }).reason == "REQUEST_CONFLICT",
			"binding conflict"
		)
		local state = assert(runtime.snapshot("owner"))
		assert(Inventory.weight(state.warehouse, catalog) == 5000, "warehouse only debit once")
		assert(command(runtime, "owner", "demolish", "demolish", { "tribe:" .. id, 2, 3, 0 }).ok, "refund")
		assert(runtime.close().ok, "release")
		local restored = assert(
			Runtime.new(
				cfg,
				FencedStore.new(
					harness.barrier(gate.snapshot()).backend,
					{ sessionId = "b", leaseSeconds = 120, now = cfg.now }
				)
			)
		)
		assert(
			command(restored, "owner", "demolish", "demolish", { "tribe:" .. id, 2, 3, 0 }).ok,
			"durable refund replay"
		)
		assert(Inventory.weight(assert(restored.snapshot("owner")).warehouse, catalog) == 7000, "no repeated refund")
		assert(
			Ledger.canonical(restored.link()) == Ledger.canonical({ tribeId = "tribe" }),
			"player link contains no aggregate"
		)
	end,
	["membership limits transfer owner and empty settlement same owner rejoin"] = function()
		local runtime = setup()
		for index, actor in { "a", "b", "c" } do
			assert(
				command(runtime, "owner", "invite-" .. actor, "invite", { actor, index - 1, index - 1 }).ok,
				"invite"
			)
		end
		assert(command(runtime, "owner", "full", "invite", { "d", 3, 3 }).reason == "TRIBE_FULL", "max four")
		assert(
			command(runtime, "owner", "leave-early", "leave", { "owner", 3, 3 }).reason == "OWNER_TRANSFER_REQUIRED",
			"owner cannot abandon members"
		)
		assert(runtime.epoch("a") == 0, "member epoch")
		assert(command(runtime, "a", "kick", "kick", { "b", 3, 3 }).reason == "FORBIDDEN", "member cannot kick")
		assert(command(runtime, "owner", "transfer", "transfer-owner", { "a", 3, 3 }).ok, "transfer")
		assert(command(runtime, "owner", "leave", "leave", { "owner", 4, 4 }).ok, "old owner leaves")
		assert(command(runtime, "a", "kick-b", "kick", { "b", 5, 5 }).ok, "kick b")
		assert(command(runtime, "a", "kick-c", "kick", { "c", 6, 6 }).ok, "kick c")
		assert(command(runtime, "a", "last-leave", "leave", { "a", 7, 7 }).ok, "empty retained")
		assert(runtime.snapshot("owner") == nil, "former owner cannot read")
		assert(
			command(runtime, "a", "read-only", "reserve", { "bench", 4, 4, 0, 8, 1, 8 }).reason == "FORBIDDEN",
			"empty read-only"
		)
		assert(command(runtime, "a", "rejoin", "rejoin", { "a", 8, 8 }).ok, "same owner rejoins")
	end,
	["revocation at backend barrier refuses debit and replay checks membership"] = function()
		local runtime, _, gate = setup()
		assert(command(runtime, "owner", "invite", "invite", { "member", 0, 0 }).ok, "invite")
		assert(runtime.epoch("member") == 0, "member epoch")
		local reserve = command(runtime, "member", "reserve", "reserve", { "bench", 4, 4, 0, 1, 1, 1 })
		assert(reserve.ok and reserve.data, "reserve")
		local result: Shared.Result? = nil
		gate.suspend()
		local worker = coroutine.create(function()
			result = command(runtime, "member", "place", "place", { reserve.data.reservationId, 2, 2 })
		end)
		local ok, signal = coroutine.resume(worker)
		assert(ok and signal == "commit-barrier-entered" and gate.pending(), "exact commit suspended")
		assert(command(runtime, "owner", "kick", "kick", { "member", 2, 1 }).ok, "durable revoke")
		gate.resume()
		assert(coroutine.resume(worker))
		assert(coroutine.status(worker) == "dead", "commit completed")
		local finished = assert(result, "commit result")
		assert(finished.reason == "FORBIDDEN", "no debit after revoke")
		assert(
			command(runtime, "member", "reserve", "reserve", { "bench", 4, 4, 0, 1, 1, 1 }).reason == "FORBIDDEN",
			"auth precedes replay"
		)
		assert(Inventory.weight(assert(runtime.snapshot("owner")).warehouse, catalog) == 10000, "quantity conserved")
	end,
	["epoch expiry receipt retention and cap reject before mutation"] = function()
		local now = 0
		local cfg = config(function()
			return now
		end)
		cfg.maxOutcomes = 1
		local runtime = assert(
			Runtime.new(
				cfg,
				FencedStore.new(harness.barrier().backend, { sessionId = "a", leaseSeconds = 120, now = cfg.now })
			)
		)
		assert(runtime.epoch("owner") == 0, "issued epoch")
		now = 9
		local first = command(runtime, "owner", "invite", "invite", { "member", 0, 0 })
		assert(first.ok, "accepted before expiry")
		assert(
			command(runtime, "owner", "full", "invite", { "other", 1, 1 }).reason == "REQUEST_CAPACITY",
			"cap refuses"
		)
		now = 10
		assert(runtime.epoch("owner") == 1, "durable epoch advances")
		assert(
			command(runtime, "owner", "invite", "invite", { "member", 0, 0 }).ok,
			"receipt outlives acceptance window"
		)
		assert(
			command(runtime, "owner", "unknown", "invite", { "other", 1, 1 }).reason == "REQUEST_EXPIRED",
			"expired unknown"
		)
		now = 19
		assert(
			command(runtime, "owner", "invite", "invite", { "member", 0, 0 }).reason == "REQUEST_EXPIRED",
			"receipt expires"
		)
		assert(command(runtime, "owner", "new", "invite", { "other", 1, 1 }, 1).ok, "new epoch accepts")
	end,
	["backend failure never ACKs or publishes and lease takeover fences runtime"] = function()
		local runtime, cfg, gate = setup()
		gate.fail(1)
		local failed = command(runtime, "owner", "invite", "invite", { "member", 0, 0 })
		assert(not failed.ok and string.find(failed.reason or "", "COMMIT_FAILED", 1, true), "failure propagated")
		assert(assert(runtime.snapshot("owner")).settlement.roles.member == nil, "no unpublished candidate")
		assert(command(runtime, "owner", "invite", "invite", { "member", 0, 0 }).ok, "retry")
		local replacement = assert(
			Runtime.new(cfg, FencedStore.new(gate.backend, { sessionId = "a", leaseSeconds = 120, now = cfg.now }))
		)
		assert(not command(runtime, "owner", "stale", "invite", { "other", 1, 1 }).ok, "stale lease")
		assert(assert(replacement.snapshot("owner")).settlement.roles.other == nil, "new owner preserved")
	end,
}
