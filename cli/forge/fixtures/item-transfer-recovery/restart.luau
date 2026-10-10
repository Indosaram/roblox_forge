--!strict
-- Prerequisite proof only: actual coordinator/backend, not Session or qa scenario.
local serde = require("@lune/serde")
local process = require("@lune/process")
local run = require("../../lib/run")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Catalog = require("../../../../core/domain/inventory/ItemCatalog")
local Transfer = require("../../../../core/infra/data/ItemTransfer")
local FencedStore = require("../../../../core/infra/data/FencedStore")
local MemoryBackend = require("../../../../core/infra/data/MemoryBackend")
local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000 } })
local request: Transfer.Request = {
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

local function context(snapshot: any?, clock: number, session: string): any
	local c: any = { now = clock, calls = 0, failAt = 0, lostAck = false, failures = 0 }
	c.memory = MemoryBackend.new()
	if snapshot then
		for key, record in snapshot do
			c.memory.update(key, function(): any
				return record
			end)
		end
	end
	c.backend = {
		update = function(key: string, transform: MemoryBackend.Transform): (boolean, any)
			c.calls += 1
			if c.calls == c.failAt then
				c.failures += 1
				-- Evaluate the real callback, then either discard or commit its
				-- candidate through MemoryBackend before reporting failure.
				c.memory.update(key, function(old: any): any
					local candidate = transform(old)
					return if c.lostAck then candidate else old
				end)
				return false, "INJECTED_ACK_FAILURE"
			end
			return c.memory.update(key, transform)
		end,
	}
	c.store = FencedStore.new(c.backend, {
		sessionId = session,
		leaseSeconds = 30,
		now = function(): number
			return c.now
		end,
	})
	local function load(key: string, quantity: number): FencedStore.Profile
		return assert(c.store:acquire(key, function(data: any): any
			if data.inventory then
				return data
			end
			local inventory = Inventory.new(key, { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
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
			data.inventory = Inventory.save(inventory)
			return data
		end))
	end
	c.source, c.destination = load(request.source, 10), load(request.destination, 0)
	c.coordinator = Transfer.new(c.store, catalog, {
		maxReceipts = 4096,
		now = function(): number
			return c.now
		end,
		authorize = function(req, proof, _data): boolean
			return req.actor == "player-1"
				and proof.actor == req.actor
				and proof.revision == 7
				and proof.epoch == req.epoch
				and proof.expiresAt == req.expiresAt
		end,
	})
	c.step = function(cleanup: boolean): Transfer.Result
		local result = if cleanup
			then c.coordinator:cleanup(c.source, c.destination, request)
			else c.coordinator:advance(
				c.source,
				c.destination,
				request,
				{ actor = "player-1", revision = 7, epoch = "epoch-1", expiresAt = 86400 }
			)
		c.source, c.destination = result.source, result.destination
		return result
	end
	c.snapshot = function(): any
		local records = {}
		for _, key in { request.source, request.destination } do
			local ok, record = c.memory.update(key, function(old: any): any
				return old
			end)
			assert(ok, "snapshot backend confirmed")
			records[key] = record
		end
		return records
	end
	return c
end

local function conserve(c: any, final: boolean)
	local records = c.snapshot()
	local source, destination = records[request.source].data, records[request.destination].data
	local personal = source.inventory.items["wood-1"].quantity
	local output = destination.inventory.items[request.outputId]
	local tribe = if output then output.quantity else 0
	local receipt = source.itemTransfers and source.itemTransfers.receipts[request.id]
	local uncreditedEscrow = if receipt and receipt.phase == "ESCROWED" and not output then 3 else 0
	assert(personal + tribe + uncreditedEscrow == 10, "count credited ownership once, not source liability")
	if final then
		assert(
			personal == 7 and tribe == 3 and output.attributes.origin == "forest",
			"Transfer101 exact final inventory"
		)
	end
end

local function drive(c: any, cleanup: boolean)
	for _ = 1, 8 do
		local result = c.step(cleanup)
		conserve(c, cleanup)
		if result.status == "confirmed" then
			return
		end
		assert(result.status == "pending" or result.status == "recovering", result.error)
		assert(result.error == nil or result.detail == "INJECTED_ACK_FAILURE", result.error)
	end
	error("bounded deterministic recovery did not finish")
end

if process.args[1] == "restore" then
	local input = serde.decode("json", process.args[2])
	local cleanupCheckpoint = input.checkpoint == "SOURCE_FINALIZED"
	local c = context(input.records, if cleanupCheckpoint then 86460 else 60, "fresh-process")
	assert(c.source.generation > input.source.generation, "fresh process acquires new source generation")
	assert(c.destination.generation > input.destination.generation, "fresh process acquires new destination generation")
	local stale = c.coordinator:advance(input.source, input.destination, request, {})
	assert(stale.status == "recovering" and stale.detail == "invalid token", "previous process token cannot recredit")
	if input.mode ~= "normal" then
		c.failAt, c.lostAck = c.calls + 1, input.mode == "lost-ack"
	end
	if not cleanupCheckpoint then
		drive(c, false)
		conserve(c, true)
		-- Reconstruct from committed state again, without a transient coordinator cache.
		c = context(c.snapshot(), 86400, "cleanup-owner")
	end
	if input.mode ~= "normal" and not cleanupCheckpoint then
		c.failAt, c.lostAck = c.calls + 2, input.mode == "lost-ack"
	end
	drive(c, true)
	local records = c.snapshot()
	assert(next(records[request.source].data.itemTransfers.receipts) == nil, "source receipt reclaimed")
	assert(next(records[request.destination].data.itemTransfers.receipts) == nil, "destination receipt reclaimed")
	assert(c.step(false).error == "REQUEST_EXPIRED", "expired request cannot credit after pruning")
	conserve(c, true)
	if input.mode ~= "normal" then
		assert(c.failures == 1, "requested failure callback actually exercised")
	end
	print("PASS fresh-process " .. input.checkpoint .. " " .. input.mode .. " final=7/3 receipts=0")
else
	local count = 0
	for index, checkpoint in { "PREPARED", "ESCROWED", "CREDITED", "FINALIZED", "SOURCE_FINALIZED" } do
		local c = context(nil, 0, "producer")
		for _ = 1, math.min(index, 4) do
			local result = c.step(false)
			assert(result.error == nil, result.error)
			conserve(c, false)
		end
		if checkpoint == "SOURCE_FINALIZED" then
			c = context(c.snapshot(), 86400, "cleanup-producer")
			c.failAt = c.calls + 3
			local result = c.step(true)
			assert(result.status == "recovering", "stop after durable destination finality handshake")
			assert(
				c.snapshot()[request.destination].data.itemTransfers.receipts[request.id].phase == "SOURCE_FINALIZED",
				"exact cleanup checkpoint reached"
			)
		end
		for _, mode in { "normal", "failure", "lost-ack" } do
			local serialized = serde.encode("json", {
				checkpoint = checkpoint,
				mode = mode,
				records = c.snapshot(),
				source = c.source,
				destination = c.destination,
			})
			local result = run.exec("lune", {
				"run",
				"cli/forge/fixtures/item-transfer-recovery/restart",
				"restore",
				serialized,
			})
			assert(result.ok and result.code == 0, result.stderr .. result.stdout)
			print(result.stdout)
			count += 1
		end
	end
	print(string.format("item-transfer-fresh-process: %d passed, 0 failed", count))
end
