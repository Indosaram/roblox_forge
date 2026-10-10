--!strict
local Transaction = require("./Transaction")
local Settlement = require("./Settlement")
local Inventory = require("../inventory/Inventory")
local Catalog = require("../inventory/ItemCatalog")
local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000, maxDurabilityMilli = 1000 } })

local function item(id: string, quantity: number): Inventory.Item
	return {
		itemId = id,
		catalogId = "wood",
		quantity = quantity,
		qualityMilli = 1000,
		durabilityMilli = 1000,
		attributes = {},
	}
end

local function initial(slots: number?): Transaction.State
	local warehouse =
		Inventory.new("warehouse", { slots = slots or 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for _, value in { item("z", 8), item("a", 3) } do
		local added = Inventory.add(warehouse, catalog, value, warehouse.version)
		assert(added, "initial items fit")
		warehouse = added
	end
	warehouse.items.z.attributes.origin = "forest"
	return {
		settlement = Settlement.new(
			{ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 },
			"owner"
		),
		warehouse = warehouse,
	}
end

local function context(state: Transaction.State, id: string, actor: string?): Transaction.Context
	return {
		commandId = id,
		actorId = actor or "owner",
		settlementVersion = state.settlement.version,
		warehouseVersion = state.warehouse.version,
		membershipRevision = state.settlement.membershipRevision,
	}
end

local function request(quantity: number?): Transaction.Request
	return {
		definition = {
			id = "bench",
			footprintX = 2,
			footprintZ = 3,
			cost = { { item = "wood", quantity = quantity or 5 } },
		},
		x = 4,
		z = 4,
		rotation = 0,
	}
end

local function equal(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function reserve(state: Transaction.State, id: string?): (Transaction.State, string)
	local command = id or "place"
	local result, err = Transaction.reserve(state, catalog, context(state, command), request())
	assert(result, err)
	return result, Transaction.reservationId("tribe", command)
end

local function build(state: Transaction.State): (Transaction.State, string)
	local reserved, id = reserve(state)
	local built, err = Transaction.commit(reserved, catalog, context(reserved, "commit"), id)
	assert(built, err)
	return built, "tribe:" .. id
end

return {
	["occupied storage returns exact metadata before refund and snapshots detach"] = function()
		local built, id = build(initial())
		local storage = Inventory.new(id, { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		local stored = item("stored", 4)
		stored.qualityMilli = 2000
		stored.durabilityMilli = 1700
		stored.attributes = { origin = "cave", rare = true }
		local filled = Inventory.add(storage, catalog, stored, storage.version)
		assert(filled, "storage fits")
		built.structureContents = { [id] = filled }
		local before = Transaction.snapshot(built)
		local snapshot = Transaction.snapshot(built)
		assert(snapshot.structureContents, "contents copied")
		snapshot.structureContents[id].items.stored.attributes.origin = "changed"
		assert(equal(built, before), "snapshot detached")
		local demolished, err = Transaction.demolish(built, catalog, context(built, "occupied"), id)
		assert(demolished, err)
		assert(equal(demolished.warehouse.items.stored, stored), "exact stack identity and metadata")
		assert(Inventory.weight(demolished.warehouse, catalog) == 12000, "six plus four contents plus two refund")
		assert(demolished.structureContents and not demolished.structureContents[id], "ownership removed once")
		assert(not demolished.settlement.structures[id] and equal(built, before), "atomic detached demolition")
	end,
	["storage merges compatible metadata and full refund refusal rolls back returned contents"] = function()
		local built, id = build(initial(2))
		local storage = Inventory.new(id, { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		local stored = item("stored", 4)
		stored.attributes.origin = "forest"
		local filled = Inventory.add(storage, catalog, stored, 0)
		assert(filled, "storage fits")
		built.structureContents = { [id] = filled }
		local demolished = Transaction.demolish(built, catalog, context(built, "merge-storage"), id)
		assert(demolished and demolished.warehouse.items.z.quantity == 10, "compatible storage stack merges")
		assert(demolished.warehouse.items.z.attributes.origin == "forest", "merged metadata retained")
		built.warehouse.limits.slots = 1
		local before = Transaction.snapshot(built)
		local refused, err = Transaction.demolish(built, catalog, context(built, "refund-full"), id)
		assert(
			not refused and err == "FULL_SLOTS" and equal(built, before),
			"refund failure rolls back successful storage return"
		)
		built.warehouse.items.z.attributes.origin = "other"
		before = Transaction.snapshot(built)
		local full, fullError = Transaction.demolish(built, catalog, context(built, "contents-full"), id)
		assert(not full and fullError == "FULL_SLOTS" and equal(built, before), "contents cannot fit")
	end,
	["active storage reservations and inconsistent ownership reject unchanged"] = function()
		local built, id = build(initial())
		local storage = Inventory.new(id, { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		local filled = Inventory.add(storage, catalog, item("stored", 4), 0)
		assert(filled, "storage fits")
		local reserved = Inventory.reserve(filled, "job", { stored = 1 }, filled.version)
		assert(reserved, "active storage job")
		built.structureContents = { [id] = reserved }
		local before = Transaction.snapshot(built)
		local refused, err = Transaction.demolish(built, catalog, context(built, "busy"), id)
		assert(
			not refused and err == "STORAGE_RESERVED" and equal(built, before),
			"active reservations block demolition"
		)
		reserved.id = "wrong-owner"
		assert(Transaction.validateOwnership(built) == "INVALID_STORAGE_OWNER", "inventory identity bound to structure")
		local invalid, invalidError = Transaction.demolish(built, catalog, context(built, "invalid"), id)
		assert(not invalid and invalidError == "INVALID_STORAGE_OWNER", "transition enforces boundary")
		assert(not pcall(Transaction.snapshot, built), "snapshot boundary rejects inconsistent ownership")
		reserved.id = id
		local orphan = Transaction.snapshot(built)
		orphan.settlement.structures = {}
		assert(Transaction.validateOwnership(orphan) == "INVALID_STORAGE_OWNER", "orphan contents rejected")
	end,
	["sorted exact reservation conserves initial units and locks only reserved inputs"] = function()
		local state = initial()
		local before = Transaction.snapshot(state)
		local reserved, id = reserve(state)
		assert(equal(state, before), "reserve input unchanged")
		assert(Inventory.weight(reserved.warehouse, catalog) == 11000, "reservation is not consumption")
		assert(
			reserved.warehouse.reservations[id].a == 3 and reserved.warehouse.reservations[id].z == 2,
			"ascending exact inputs"
		)
		assert(reserved.warehouse.items.z.attributes.origin == "forest", "metadata retained")
		local target = Inventory.new("target", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		local moved, _, err =
			Inventory.move(reserved.warehouse, target, catalog, "a", 1, "partial", reserved.warehouse.version, 0)
		assert(not moved and err == "UNAVAILABLE", "reserved units cannot move")
		local built = Transaction.commit(reserved, catalog, context(reserved, "commit"), id)
		assert(built and not built.warehouse.items.a and built.warehouse.items.z.quantity == 6, "consume five exactly")
		assert(
			built.warehouse.items.z.attributes.origin == "forest" and not built.warehouse.reservations[id],
			"metadata and release"
		)
		local repeated, refusal = Transaction.commit(built, catalog, context(built, "again"), id)
		assert(not repeated and refusal == "NOT_RESERVED", "no double debit")
		assert(reserved.warehouse.items.a.quantity == 3, "commit detached")
	end,
	["cancel releases once and placement IDs never recycle"] = function()
		local state, id = reserve(initial())
		local cancelled = Transaction.cancel(state, context(state, "cancel"), id)
		assert(cancelled and Inventory.available(cancelled.warehouse, "a") == 3, "released")
		assert(Inventory.weight(cancelled.warehouse, catalog) == 11000, "cancel conserves total")
		local repeated, err = Transaction.cancel(cancelled, context(cancelled, "again"), id)
		assert(not repeated and err == "NOT_RESERVED", "no repeated release")
		local reused, reuseError = Transaction.reserve(cancelled, catalog, context(cancelled, "place"), request())
		assert(not reused and reuseError == "RESERVATION_ID_USED", "no ID reuse")
		assert(state.warehouse.reservations[id] ~= nil, "cancel detached")
	end,
	["competing cells stale versions missing ingredients and bounds reject both halves"] = function()
		local state = initial()
		local reserved = reserve(state)
		local before = Transaction.snapshot(reserved)
		local result, err = Transaction.reserve(reserved, catalog, context(reserved, "other"), request())
		assert(not result and err == "COLLISION", "one cell winner")
		local stale = context(reserved, "stale")
		stale.settlementVersion = 0
		local staleResult, staleError = Transaction.reserve(reserved, catalog, stale, request())
		assert(not staleResult and staleError == "STALE_VERSION", "stale placement")
		stale = context(reserved, "stale-inventory")
		stale.warehouseVersion = 0
		local staleWarehouse, warehouseError =
			Transaction.commit(reserved, catalog, stale, Transaction.reservationId("tribe", "place"))
		assert(not staleWarehouse and warehouseError == "STALE_WAREHOUSE_VERSION", "stale warehouse")
		assert(equal(reserved, before), "all failures unchanged")
		before = Transaction.snapshot(state)
		local expensive, costError = Transaction.reserve(state, catalog, context(state, "expensive"), request(12))
		assert(not expensive and costError == "UNAVAILABLE" and equal(state, before), "no partial cell reservation")
		local edge = request()
		edge.z = 0
		local outside, boundsError = Transaction.reserve(state, catalog, context(state, "edge"), edge)
		assert(not outside and boundsError == "OUT_OF_BOUNDS" and equal(state, before), "protected entry delegated")
	end,
	["revoked actor cannot debit and owner can release pinned reservation"] = function()
		local state = initial()
		local invited = Settlement.membership(state.settlement, "owner", 0, 0, "invite", "member")
		assert(invited, "invite")
		state.settlement = invited
		local reserved = Transaction.reserve(state, catalog, context(state, "member-place", "member"), request())
		assert(reserved, "member reserves")
		local revoked = Settlement.membership(reserved.settlement, "owner", 2, 1, "revoke", "member")
		assert(revoked, "revoke")
		reserved.settlement = revoked
		local before = Transaction.snapshot(reserved)
		local id = Transaction.reservationId("tribe", "member-place")
		local refused, err = Transaction.commit(reserved, catalog, context(reserved, "commit", "member"), id)
		assert(not refused and err == "FORBIDDEN" and equal(before, reserved), "revocation precedes debit")
		local reinvited = Settlement.membership(revoked, "owner", 3, 2, "invite", "member")
		assert(reinvited, "reinvite")
		reserved.settlement = reinvited
		local late, lateError = Transaction.commit(reserved, catalog, context(reserved, "late", "member"), id)
		assert(not late and lateError == "STALE_MEMBERSHIP", "old authorization cannot revive")
		local cancelled = Transaction.cancel(reserved, context(reserved, "owner-cancel"), id)
		assert(cancelled and Inventory.weight(cancelled.warehouse, catalog) == 11000, "owner recovers reservation")
	end,
	["demolition refunds floor half once with stable output and isolated snapshots"] = function()
		local built, id = build(initial())
		local before = Transaction.snapshot(built)
		local demolished, err = Transaction.demolish(built, catalog, context(built, "demolish"), id)
		assert(demolished, err)
		assert(
			not demolished.settlement.structures[id] and Inventory.weight(demolished.warehouse, catalog) == 8000,
			"six plus floor five halves"
		)
		local refund = demolished.warehouse.items["refund:8:demolish:1"]
		assert(
			refund.quantity == 2 and refund.qualityMilli == 1000 and refund.durabilityMilli == 1000,
			"catalog refund metadata"
		)
		local again = Transaction.demolish(built, catalog, context(built, "demolish"), id)
		assert(again and equal(again, demolished), "retry candidate deterministic")
		local repeated, refusal = Transaction.demolish(demolished, catalog, context(demolished, "duplicate"), id)
		assert(not repeated and refusal == "NOT_BUILT", "refund once")
		local snapshot = Transaction.snapshot(demolished)
		snapshot.warehouse.items.z.attributes.origin = "changed"
		snapshot.settlement.config.width = 1
		assert(
			demolished.warehouse.items.z.attributes.origin == "forest" and demolished.settlement.config.width == 32,
			"deep snapshot"
		)
		assert(equal(before, built), "demolish input unchanged")
	end,
	["full warehouse rejects all refund outputs and retains demolished structure"] = function()
		local built, id = build(initial(2))
		local filled = Inventory.add(built.warehouse, catalog, item("filler", 84), built.warehouse.version)
		assert(filled, "fill exact hard capacity")
		built.warehouse = filled
		local before = Transaction.snapshot(built)
		local refused, err = Transaction.demolish(built, catalog, context(built, "full"), id)
		assert(not refused and err == "FULL_WEIGHT", "full capacity refuses refund")
		assert(equal(before, built) and built.settlement.structures[id] ~= nil, "no resource loss or removal")
		built.warehouse.limits.slots = 1
		local emptied = Inventory.consume(built.warehouse, "filler", 84, built.warehouse.version)
		assert(emptied, "remove filler")
		built.warehouse = emptied
		before = Transaction.snapshot(built)
		local fullSlots, slotsError = Transaction.demolish(built, catalog, context(built, "slots"), id)
		assert(not fullSlots and slotsError == "FULL_SLOTS" and equal(before, built), "incompatible full slot rejects")
		built.warehouse.items.z.attributes = {}
		local merged = Transaction.demolish(built, catalog, context(built, "merge"), id)
		assert(merged and merged.warehouse.items.z.quantity == 8, "compatible full slot fits refund")
	end,
	["free placement is detached and missing reserved costs cannot partially commit"] = function()
		local state = initial()
		local free = request()
		free.definition.cost = {}
		local reserved = Transaction.reserve(state, catalog, context(state, "free"), free)
		assert(reserved, "free reserve")
		local id = Transaction.reservationId("tribe", "free")
		local built = Transaction.commit(reserved, catalog, context(reserved, "commit"), id)
		assert(built and Inventory.weight(built.warehouse, catalog) == 11000, "free commit")
		built.warehouse.items.z.attributes.origin = "changed"
		assert(reserved.warehouse.items.z.attributes.origin == "forest", "free commit detached")
		local paid, paidId = reserve(state)
		paid.warehouse.reservations[paidId] = nil
		local before = Transaction.snapshot(paid)
		local refused, err = Transaction.commit(paid, catalog, context(paid, "broken"), paidId)
		assert(not refused and err == "RESERVATION_NOT_FOUND" and equal(before, paid), "no partial commit")
	end,
}
