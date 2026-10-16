--!strict
-- Direct real-mechanism prerequisite; this is not the Session CLI acceptance.
local Transaction = require("../../../../core/domain/settlement/Transaction")
local Settlement = require("../../../../core/domain/settlement/Settlement")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Catalog = require("../../../../core/domain/inventory/ItemCatalog")
local FencedStore = require("../../../../core/infra/data/FencedStore")
local harness = require("../../lib/qaharness")
local run = require("../../lib/run")
local serde = require("@lune/serde")
local process = require("@lune/process")
local fs = require("@lune/fs")
local scenario = require("../../lib/qascenario")
local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000 } })
local function context(state: Transaction.State, actor: string, command: string): Transaction.Context
	return {
		actorId = actor,
		commandId = command,
		settlementVersion = state.settlement.version,
		warehouseVersion = state.warehouse.version,
		membershipRevision = state.settlement.membershipRevision,
	}
end
local request: Transaction.Request = {
	definition = { id = "bench", footprintX = 2, footprintZ = 3, cost = { { item = "wood", quantity = 5 } } },
	x = 4,
	z = 4,
	rotation = 0,
}
local reservationId = Transaction.reservationId("tribe", "member-place")
local finalReservationId = Transaction.reservationId("tribe", "owner-final")
local structureId = "tribe:" .. finalReservationId
local function initialize(data: FencedStore.Data): FencedStore.Data
	if data.aggregate then
		return data
	end
	local settlement =
		Settlement.new({ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 }, "owner")
	local invited = Settlement.membership(settlement, "owner", 0, 0, "invite", "member", 0)
	assert(invited, "invite")
	local warehouse = Inventory.new("warehouse", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	local filled = Inventory.add(warehouse, catalog, {
		itemId = "wood",
		catalogId = "wood",
		quantity = 10,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = { origin = "forest" },
	}, 0)
	assert(filled, "initial stock")
	data.aggregate = { settlement = invited, warehouse = filled }
	return data
end
local decoded = serde.decode("yaml", fs.readFile("genres/survival-coop/qa-scenarios/settlement-conflict.yml"))
assert(#scenario.validate(decoded) == 0, "declared scenario validates")
if process.args[1] == "restore" then
	local gate = harness.barrier(serde.decode("json", process.args[2]))
	local store = FencedStore.new(gate.backend, {
		sessionId = "fresh-process",
		leaseSeconds = 120,
		now = function()
			return 0
		end,
	})
	local profile = assert(store:acquire("settlement", initialize))
	local state: Transaction.State = profile.data.aggregate
	state.warehouse = Inventory.fromSave(Inventory.save(state.warehouse), catalog)
	assert(Transaction.validateOwnership(state) == nil, "restored ownership")
	assert(
		state.settlement.structures[structureId] == nil and state.settlement.usedIds[finalReservationId],
		"demolition and ID retained"
	)
	assert(Inventory.weight(state.warehouse, catalog) == 7000, "saved debit and refund reconstructed")
	local duplicate, err = Transaction.demolish(state, catalog, context(state, "owner", "restart-refund"), structureId)
	assert(not duplicate and err == "NOT_BUILT", "restart cannot refund twice")
	assert(store:release(profile))
	print("PASS fresh-process serialized FencedStore reconstruction and duplicate refund refusal")
	return
end

-- Existing real-domain regressions cover rotations, protected entry, storage
-- metadata, capacity rollback, cancellation and duplicate debit/refund.
local suites: { { [string]: () -> () } } = {
	require("../../../../core/domain/settlement/Settlement.spec"),
	require("../../../../core/domain/settlement/Transaction.spec"),
}
local count = 0
for _, specs in suites do
	local names: { string } = {}
	for name in specs do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		specs[name]()
		count += 1
		print("PASS " .. name)
	end
end

local gate = harness.barrier()
local store = FencedStore.new(gate.backend, {
	sessionId = "fixture",
	leaseSeconds = 120,
	now = function()
		return 0
	end,
})
local profile = assert(store:acquire("settlement", initialize))
local captured: Transaction.State = profile.data.aggregate
local ownerContext = context(captured, "owner", "owner-place")
local memberContext = context(captured, "member", "member-place")
local function reserveMember(data: FencedStore.Data): FencedStore.Data
	local reserved, err = Transaction.reserve(data.aggregate, catalog, memberContext, request)
	assert(reserved, err)
	data.aggregate = reserved
	return data
end
gate.suspend()
local pending: FencedStore.Profile? = nil
local worker = coroutine.create(function()
	pending = assert(store:update(profile, reserveMember))
end)
local started, signal = coroutine.resume(worker)
assert(started and signal == "commit-barrier-entered" and gate.pending(), "exact member reservation barrier entered")
assert(coroutine.status(worker) == "suspended", "owned coroutine parked")
gate.resume()
assert(coroutine.resume(worker))
assert(coroutine.status(worker) == "dead" and pending, "reservation committed")
profile = assert(pending, "reservation profile returned")
profile = assert(store:update(profile, function(data)
	local competing, err = Transaction.reserve(data.aggregate, catalog, ownerContext, request)
	assert(not competing and err == "STALE_WAREHOUSE_VERSION", "concurrent snapshot loses")
	local collision, collisionError =
		Transaction.reserve(data.aggregate, catalog, context(data.aggregate, "owner", "fresh-owner"), request)
	assert(not collision and collisionError == "COLLISION", "fresh same-cell request loses")
	return data
end))
print("PASS two actors same footprint at exact backend commit barrier have one winner")

gate.suspend()
local commitResult: FencedStore.Profile? = nil
worker = coroutine.create(function()
	commitResult = assert(store:update(profile, function(data)
		local state: Transaction.State = data.aggregate
		local committed, err = Transaction.commit(state, catalog, context(state, "member", "commit"), reservationId)
		assert(not committed and err == "FORBIDDEN", "membership rechecked inside actual commit")
		assert(Inventory.weight(state.warehouse, catalog) == 10000, "revoked commit debits nothing")
		return data
	end))
end)
started, signal = coroutine.resume(worker)
assert(started and signal == "commit-barrier-entered" and gate.pending(), "exact debit barrier entered")
profile = assert(store:update(profile, function(data)
	local state: Transaction.State = data.aggregate
	local revoked = Settlement.membership(
		state.settlement,
		"owner",
		state.settlement.version,
		state.settlement.membershipRevision,
		"revoke",
		"member",
		0
	)
	assert(revoked, "revocation commits while debit suspended")
	state.settlement = revoked
	return data
end))
gate.resume()
assert(coroutine.resume(worker))
assert(coroutine.status(worker) == "dead" and commitResult, "revoked debit finishes without mutation")
profile = assert(commitResult, "refused debit profile returned")
print("PASS persisted membership revocation before commit prevents debit")

profile = assert(store:update(profile, function(data)
	local state: Transaction.State = data.aggregate
	local cancelled = assert(Transaction.cancel(state, context(state, "owner", "cancel"), reservationId))
	local reserved =
		assert(Transaction.reserve(cancelled, catalog, context(cancelled, "owner", "owner-final"), request))
	local id = Transaction.reservationId("tribe", "owner-final")
	local built = assert(Transaction.commit(reserved, catalog, context(reserved, "owner", "build"), id))
	assert(Inventory.weight(built.warehouse, catalog) == 5000, "one cost debit")
	local demolished = assert(Transaction.demolish(built, catalog, context(built, "owner", "refund"), "tribe:" .. id))
	assert(Inventory.weight(demolished.warehouse, catalog) == 7000, "floor half refund")
	data.aggregate = demolished
	return data
end))
assert(store:release(profile))
local durable = serde.encode("json", gate.snapshot())
local child = run.exec("lune", { "run", "cli/forge/fixtures/settlement-conflict/check", "restore", durable })
assert(child.ok, child.stderr .. child.stdout)
print(child.stdout)
print(
	string.format(
		"settlement prerequisite: %d domain regressions plus two commit barriers and fresh-process restore passed",
		count
	)
)
