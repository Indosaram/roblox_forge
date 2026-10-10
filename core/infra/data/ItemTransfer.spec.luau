--!strict
local Inventory = require("../../domain/inventory/Inventory")
local Catalog = require("../../domain/inventory/ItemCatalog")
local Transfer = require("./ItemTransfer")
local FencedStore = require("./FencedStore")
local MemoryBackend = require("./MemoryBackend")
local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000 } })

local function initial(id: string, quantity: number): any
	local inventory = Inventory.new(id, { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	if quantity > 0 then
		inventory = assert(Inventory.add(inventory, catalog, {
			itemId = "wood-1",
			catalogId = "wood",
			quantity = quantity,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = { origin = "forest" },
		}, inventory.version))
	end
	return { inventory = Inventory.save(inventory) }
end

local function fixture(): any
	local context: any = { now = 0, allowed = true, calls = 0, failAt = 0, lostAck = false, limit = 4096 }
	context.memory = MemoryBackend.new()
	context.backend = {
		update = function(key: string, transform: MemoryBackend.Transform): (boolean, any)
			context.calls += 1
			if context.barrier then
				local barrier = context.barrier
				context.barrier = nil
				context.memory.update(key, function(old: any): any
					transform(old)
					return old
				end)
				barrier()
			end
			if context.calls == context.failAt then
				context.memory.update(key, function(old: any): any
					local candidate = transform(old)
					return if context.lostAck then candidate else old
				end)
				return false, "INJECTED_FAILURE"
			end
			return context.memory.update(key, transform)
		end,
	}
	context.open = function(session: string)
		context.store = FencedStore.new(context.backend, {
			sessionId = session,
			leaseSeconds = 30,
			now = function(): number
				return context.now
			end,
		})
		context.source = assert(context.store:acquire("personal", function(data: any): any
			return if data.inventory then data else initial("personal", 10)
		end))
		context.destination = assert(context.store:acquire("tribe:qa-tribe", function(data: any): any
			return if data.inventory then data else initial("tribe:qa-tribe", 0)
		end))
		context.coordinator = Transfer.new(context.store, catalog, {
			maxReceipts = context.limit,
			now = function(): number
				return context.now
			end,
			authorize = function(request, proof, _data): boolean
				return context.allowed
					and request.actor == "player-1"
					and proof.actor == request.actor
					and proof.revision == 7
					and proof.epoch == request.epoch
					and proof.expiresAt == request.expiresAt
			end,
		})
	end
	context.request = {
		id = "Transfer101",
		actor = "player-1",
		epoch = "epoch-1",
		expiresAt = 86400,
		source = "personal",
		destination = "tribe:qa-tribe",
		itemId = "wood-1",
		outputId = "Transfer101-wood",
		quantity = 3,
	}
	context.proof = { actor = "player-1", epoch = "epoch-1", expiresAt = 86400, revision = 7 }
	context.step = function(): Transfer.Result
		local response =
			context.coordinator:advance(context.source, context.destination, context.request, context.proof)
		context.source, context.destination = response.source, response.destination
		return response
	end
	context.read = function(key: string): any
		local ok, record = context.memory.update(key, function(old: any): any
			return old
		end)
		assert(ok, "transfer invariant")
		return record
	end
	context.open("a")
	return context
end

local function quantities(c: any, source: number, destination: number)
	local a = c.read("personal").data.inventory
	local b = c.read("tribe:qa-tribe").data.inventory
	assert(a.items["wood-1"].quantity == source, "source quantity")
	local output = b.items["Transfer101-wood"]
	assert((if output then output.quantity else 0) == destination, "destination quantity")
end

local function finish(c: any)
	for _ = 1, 5 do
		local response = c.step()
		if response.status == "confirmed" then
			assert(response.phase == "FINALIZED", "transfer invariant")
			quantities(c, 7, 3)
			return
		end
		assert(response.error == nil, response.error)
	end
	error("transfer did not finish")
end

-- Native fixture supplies actual JSON serialization, keeping Lune dependencies
-- out of the engine-loadable spec module. The snapshots include fenced wrappers.
local function restartMatrix(roundtrip: ((any) -> any)?)
	for checkpoint = 0, 4 do
		local c = fixture()
		for _ = 1, checkpoint do
			c.step()
		end
		local snapshots = { personal = c.read("personal"), tribe = c.read("tribe:qa-tribe") }
		if roundtrip then
			snapshots = roundtrip(snapshots)
		end
		local fresh = fixture()
		fresh.memory = MemoryBackend.new()
		fresh.memory.update("personal", function(): any
			return snapshots.personal
		end)
		fresh.memory.update("tribe:qa-tribe", function(): any
			return snapshots.tribe
		end)
		fresh.now = 30
		fresh.open("new-owner")
		fresh.allowed = checkpoint < 2
		finish(fresh)
		for _ = 1, 10 do
			assert(fresh.step().status == "confirmed", "transfer invariant")
		end
		quantities(fresh, 7, 3)
	end
end

local specs: { [string]: () -> () } = {
	["Transfer101 exposes exact phases and escrow is not spendable"] = function()
		local c = fixture()
		assert(c.step().phase == "PREPARED", "transfer invariant")
		quantities(c, 10, 0)
		local reserved = Inventory.fromSave(c.read("personal").data.inventory, catalog)
		assert(Inventory.available(reserved, "wood-1") == 7, "transfer invariant")
		assert(Inventory.consume(reserved, "wood-1", 8, reserved.version) == nil, "transfer invariant")
		assert(c.step().phase == "ESCROWED", "transfer invariant")
		quantities(c, 7, 0)
		assert(c.step().phase == "CREDITED", "transfer invariant")
		quantities(c, 7, 3)
		assert(c.step().status == "confirmed", "transfer invariant")
		assert(c.read("personal").data.itemTransfers.receipts.Transfer101.item == nil, "transfer invariant")
		assert(c.step().status == "confirmed", "transfer invariant")
	end,
	["failures and lost ACK at every backend boundary recover exactly once"] = function()
		for _, lostAck in { false, true } do
			for boundary = 1, 7 do
				local c = fixture()
				c.failAt, c.lostAck = c.calls + boundary, lostAck
				local sawFailure = false
				for _ = 1, 8 do
					local response = c.step()
					if response.error then
						sawFailure = true
						assert(
							response.status == "recovering" and response.detail == "INJECTED_FAILURE",
							"transfer invariant"
						)
					end
				end
				assert(sawFailure, "boundary exercised")
				finish(c)
			end
		end
	end,
	["preacceptance revocation on callback replay rejects but escrow finishes revoked"] = function()
		for _, prepared in { false, true } do
			local c = fixture()
			if prepared then
				c.step()
			end
			c.barrier = function()
				c.allowed = false
			end
			assert(c.step().error == "UNAUTHORIZED", "transfer invariant")
			quantities(c, 10, 0)
			local inventory = Inventory.fromSave(c.read("personal").data.inventory, catalog)
			assert(Inventory.available(inventory, "wood-1") == 10, "denial releases preparation")
			if prepared then
				c.allowed = true
				assert(c.step().phase == "CANCELLED", "terminal denial cannot later debit")
			end
		end
		local c = fixture()
		c.step()
		c.step()
		c.allowed = false
		finish(c)
	end,
	["false actor membership and epoch proof reject before acceptance"] = function()
		for _, field in { "actor", "revision", "epoch", "expiresAt" } do
			local c = fixture()
			c.proof[field] = "forged"
			assert(c.step().error == "UNAUTHORIZED", "transfer invariant")
			quantities(c, 10, 0)
			assert(next(c.read("personal").data.itemTransfers.receipts) == nil, "transfer invariant")
		end
	end,
	["destination full stays recovering without refund and later finishes"] = function()
		local c = fixture()
		c.destination = assert(c.store:update(c.destination, function(data: any): any
			data.inventory = initial("tribe:qa-tribe", 90).inventory
			return data
		end))
		c.step()
		c.step()
		assert(c.step().error == "FULL_WEIGHT", "transfer invariant")
		quantities(c, 7, 0)
		c.destination = assert(c.store:update(c.destination, function(data: any): any
			local inventory = Inventory.fromSave(data.inventory, catalog)
			local consumed = assert(Inventory.consume(inventory, "wood-1", 3, inventory.version))
			data.inventory = Inventory.save(consumed)
			return data
		end))
		finish(c)
	end,
	["changed payload conflicts and expired unknown requests never mutate"] = function()
		local c = fixture()
		c.step()
		c.request.quantity = 4
		assert(c.step().error == "TRANSFER_CONFLICT", "transfer invariant")
		quantities(c, 10, 0)
		local expired = fixture()
		expired.request.expiresAt = 0
		assert(expired.step().error == "REQUEST_EXPIRED", "transfer invariant")
		quantities(expired, 10, 0)
	end,
	["bounded receipts retain active and completed entries without eviction"] = function()
		local c = fixture()
		c.limit = 1
		c.open("a")
		c.step()
		local original = c.request
		c.request = table.clone(original)
		c.request.id = "Transfer102"
		assert(c.step().error == "RECEIPT_LIMIT", "transfer invariant")
		c.request = original
		finish(c)
		c.request = table.clone(original)
		c.request.id = "Transfer102"
		assert(c.step().error == "RECEIPT_LIMIT", "transfer invariant")
		quantities(c, 7, 3)
	end,
	["new lease owner at each callback barrier prevents stale progress"] = function()
		for checkpoint = 0, 3 do
			local c = fixture()
			for _ = 1, checkpoint do
				c.step()
			end
			local oldCoordinator, oldSource, oldDestination = c.coordinator, c.source, c.destination
			c.barrier = function()
				c.now = 30
				c.open("new-owner")
			end
			local response = oldCoordinator:advance(oldSource, oldDestination, c.request, c.proof)
			assert(response.status == "recovering" and response.detail == "lease lost", "transfer invariant")
			finish(c)
		end
	end,
	["expired preparation releases once and keeps terminal denial"] = function()
		local c = fixture()
		c.request.expiresAt, c.proof.expiresAt = 10, 10
		c.step()
		c.now = 10
		local denied = c.step()
		assert(denied.phase == "CANCELLED" and denied.error == "REQUEST_EXPIRED", "expired reservation cancelled")
		local inventory = Inventory.fromSave(c.read("personal").data.inventory, catalog)
		assert(Inventory.available(inventory, "wood-1") == 10, "all units spendable again")
		assert(c.step().error == "REQUEST_EXPIRED", "denial durable")
	end,
	["cleanup rejects active receipts and cached forged finality"] = function()
		for checkpoint = 1, 3 do
			local c = fixture()
			for _ = 1, checkpoint do
				c.step()
			end
			c.now = 86400
			c.open("new-owner")
			c.source.data.itemTransfers.receipts.Transfer101.phase = "FINALIZED"
			local result = c.coordinator:cleanup(c.source, c.destination, c.request)
			assert(result.error == "TRANSFER_PENDING", "actual source consulted, not cached proof")
			local durable = c.read("personal").data.itemTransfers.receipts.Transfer101
			assert(durable.phase == (if checkpoint == 1 then "PREPARED" else "ESCROWED"), "active never pruned")
		end
	end,
	["expired finalized handshake frees capacity and rejects old requests"] = function()
		local c = fixture()
		c.limit = 1
		c.open("a")
		finish(c)
		assert(
			c.coordinator:cleanup(c.source, c.destination, c.request).error == "CLEANUP_NOT_EXPIRED",
			"horizon protected"
		)
		c.now = 86400
		c.open("new-owner")
		local oldDestination = c.destination
		local result = c.coordinator:cleanup(c.source, c.destination, c.request)
		assert(result.phase == "PRUNED" and result.status == "confirmed", "handshake complete")
		c.source, c.destination = result.source, result.destination
		assert(c.store:renew(oldDestination) == nil, "old credit writers fenced before tombstone removal")
		assert(next(c.read("personal").data.itemTransfers.receipts) == nil, "source space reclaimed")
		assert(next(c.read("tribe:qa-tribe").data.itemTransfers.receipts) == nil, "destination space reclaimed")
		assert(c.step().error == "REQUEST_EXPIRED", "old request cannot recreate credit")
		c.request.id, c.request.outputId = "Transfer102", "Transfer102-wood"
		c.request.expiresAt, c.proof.expiresAt = 172800, 172800
		assert(c.step().phase == "PREPARED", "capacity reusable")
	end,
	["cleanup loss of ACK at each handshake commit resumes without inventory mutation"] = function()
		for _, lostAck in { false, true } do
			for boundary = 1, 4 do
				local c = fixture()
				finish(c)
				c.now = 86400
				c.open("new-owner")
				c.failAt, c.lostAck = c.calls + boundary, lostAck
				local response = c.coordinator:cleanup(c.source, c.destination, c.request)
				assert(response.status == "recovering", "uncertainty is not success")
				c.source, c.destination = response.source, response.destination
				local retry = c.coordinator:cleanup(c.source, c.destination, c.request)
				assert(retry.status == "confirmed" and retry.phase == "PRUNED", "idempotent cleanup recovery")
				quantities(c, 7, 3)
			end
		end
	end,
}

specs["pure mint batches validate atomically and retain exact replay"] = function()
	local c = fixture()
	local request = table.clone(c.request)
	request.itemId, request.outputId = "minted", "minted"
	local item: Inventory.Item = {
		itemId = "minted",
		catalogId = "wood",
		quantity = 3,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = {},
	}
	local options: Transfer.Options = {
		maxReceipts = 2,
		now = function()
			return c.now
		end,
		authorize = function(_req, _proof, data)
			return data.allowed == true
		end,
	}
	local raw = { allowed = true }
	local mint = { request = request, item = item }
	local staged = assert(Transfer.stageMint(raw, catalog, request.source, "binding", { mint }, options, nil))
	assert((raw :: any).itemTransfers == nil and staged.inventory == nil, "pure and never spendable")
	c.now = 86400
	assert(
		Transfer.stageMint(staged, catalog, request.source, "binding", { mint }, options, nil),
		"expired exact replay"
	)
	local changed = table.clone(item)
	changed.qualityMilli = 2000
	local refused, err = Transfer.stageMint(
		staged,
		catalog,
		request.source,
		"binding",
		{ { request = request, item = changed } },
		options,
		nil
	)
	assert(not refused and err == "TRANSFER_CONFLICT", "item payload immutable")
	c.now = 0
	local other = table.clone(request)
	other.id, other.itemId, other.outputId = "second", "second", "second"
	local invalid = table.clone(item)
	invalid.itemId, invalid.quantity = "second", 999
	assert(
		not Transfer.stageMint(
			raw,
			catalog,
			request.source,
			"binding",
			{ mint, { request = other, item = invalid } },
			options,
			nil
		),
		"invalid batch atomic"
	)
	assert((raw :: any).itemTransfers == nil, "no first output leak")
	options.maxReceipts = 1
	invalid.quantity = 3
	assert(
		not Transfer.stageMint(
			raw,
			catalog,
			request.source,
			"binding",
			{ mint, { request = other, item = invalid } },
			options,
			nil
		),
		"whole batch cap"
	)
	assert(
		not Transfer.stageMint({ allowed = false }, catalog, request.source, "binding", { mint }, options, nil),
		"source authority required"
	)
	c.source = assert(c.store:update(c.source, function()
		return staged
	end))
	c.request = request
	c.now = 86400
	c.source = assert(c.store:acquire(c.source.key, function(data)
		return data
	end))
	c.destination = assert(c.store:acquire(c.destination.key, function(data)
		return data
	end))
	assert(c.step().phase == "CREDITED", "irrevocable after expiry")
	assert(c.step().status == "confirmed", "mint finalizes")
	assert(c.coordinator:cleanup(c.source, c.destination, request).error == "MINT_RETAINED", "mint never pruned")
	assert(
		Transfer.stageMint(c.source.data, catalog, request.source, "binding", { mint }, options, nil),
		"finalized replay retains payload"
	)
end

specs.restartMatrix = restartMatrix
return specs
