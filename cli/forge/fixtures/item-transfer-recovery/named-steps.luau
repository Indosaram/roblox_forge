--!strict
-- Actual owners, durable named writes and JSON subprocess reconstruction.
local serde = require("@lune/serde")
local process = require("@lune/process")
local Memory = require("../../../../core/infra/data/MemoryBackend")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Personal = require("../../../../core/infra/data/PersonalAggregate")
local Runtime = require("../../../../genres/survival-coop/module/TransferRuntime")
local SettlementRuntime = require("../../../../genres/survival-coop/module/SettlementRuntime")
local Settlement = require("../../../../core/domain/settlement/Settlement")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Catalog = require("../../../../core/domain/inventory/ItemCatalog")
local M = {}
M.catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000 } })
M.personalKey, M.tribeKey = "retirement:owner", "tribe"
function M.encode(value: any): string
	return serde.encode("json", value)
end
function M.context(direction: string, records: any?, now: number?, cap: number?): any
	local c: any = { now = now or 0, hits = 0, events = {}, armed = nil, mode = nil, replay = false }
	c.request = {
		id = "Transfer101",
		actor = "owner",
		epoch = "0",
		expiresAt = 86400,
		source = if direction == "deposit" then M.personalKey else M.tribeKey,
		destination = if direction == "deposit" then M.tribeKey else M.personalKey,
		itemId = "wood",
		outputId = "moved",
		quantity = 3,
	}
	c.direction = direction
	c.memory = Memory.new()
	if records then
		for key, value in records do
			c.memory.update(key, function()
				return value
			end)
		end
	end
	c.snapshot = function(): any
		local result = {}
		for _, key in { M.personalKey, M.tribeKey } do
			local ok, value = c.memory.update(key, function(old)
				return old
			end)
			assert(ok, "snapshot acknowledged")
			result[key] = value
		end
		return result
	end
	local function label(key: string, old: any, value: any): string?
		if not old or not value then
			return nil
		end
		local id = c.request.id
		local before = old.data.itemTransfers and old.data.itemTransfers.receipts[id]
		local after = value.data.itemTransfers and value.data.itemTransfers.receipts[id]
		local oldGrant = old.data.transferGrants and old.data.transferGrants.entries[id]
		local newGrant = value.data.transferGrants and value.data.transferGrants.entries[id]
		if not oldGrant and newGrant then
			return "GRANT_ACCEPTED"
		end
		if oldGrant and not newGrant then
			return "GRANT_REMOVED"
		end
		if before and not after then
			return if key == c.request.source then "SOURCE_REMOVED" else "DESTINATION_REMOVED"
		end
		if after and (not before or before.phase ~= after.phase) then
			if key == c.request.source then
				return "SOURCE_" .. after.phase
			end
			return if after.phase == "CREDITED" then "DESTINATION_COMMITTED" else "DESTINATION_" .. after.phase
		end
		if key == c.request.source and old.generation ~= value.generation and c.now >= c.request.expiresAt then
			return "SOURCE_FENCED"
		end
		return nil
	end
	c.backend = {
		update = function(key: string, transform: Memory.Transform): (boolean, any)
			assert(not c.stopped, "producer must stop immediately at named boundary")
			if key == M.tribeKey and c.discoveryFailure then
				local mode = c.discoveryFailure
				c.discoveryFailure = nil
				c.discoveryHits = (c.discoveryHits or 0) + 1
				if mode == "lost" then
					c.memory.update(key, transform)
				end
				return false, "DISCOVERY_ACK_FAILURE"
			end
			local hit = false
			local ok, value = c.memory.update(key, function(old)
				if c.replay then
					transform(old)
				end
				local candidate = transform(old)
				local name = label(key, old, candidate)
				if name then
					table.insert(c.events, name)
				end
				if name and name == c.armed then
					c.hits += 1
					hit = true
					return if c.mode == "failure" then old else candidate
				end
				return candidate
			end)
			if hit then
				c.stopped = true
				if c.mode == "crash" then
					error("NAMED_CRASH:" .. c.armed)
				end
				return false, "NAMED_ACK_FAILURE:" .. c.armed
			end
			return ok, value
		end,
	}
	local opts: Fenced.Options = {
		sessionId = if records then "restored" else "producer",
		leaseSeconds = 30,
		now = function()
			return c.now
		end,
		budget = { encode = M.encode },
	}
	local function bag(id: string, amount: number): Inventory.State
		local state = Inventory.new(id, { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		if amount > 0 then
			state = assert(Inventory.add(state, M.catalog, {
				itemId = "wood",
				catalogId = "wood",
				quantity = amount,
				qualityMilli = 1000,
				durabilityMilli = 0,
				attributes = { origin = "forest" },
			}, state.version))
		end
		return state
	end
	c.personal = Personal.new(c.backend, {
		namespace = "retirement",
		store = opts,
		inventoryPath = { "genres", "survival", "inventory", "bag" },
		validateEnvelope = function(data)
			return type(data) == "table" and pcall(Inventory.fromSave, data.genres.survival.inventory.bag, M.catalog)
		end,
	})
	c.profile = assert(c.personal:load("owner", function()
		return {
			version = 1,
			genres = {
				survival = {
					inventory = { bag = Inventory.save(bag("bag", if direction == "deposit" then 10 else 0)) },
					vitals = { health = 90 },
					jobs = { pinned = 1 },
				},
				other = { coins = 12 },
			},
		}
	end))
	c.tribe = assert(SettlementRuntime.new({
		key = M.tribeKey,
		catalog = M.catalog,
		definitions = {},
		now = opts.now,
		initial = {
			settlement = Settlement.new(
				{ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 },
				"owner"
			),
			warehouse = bag("warehouse", if direction == "withdraw" then 10 else 0),
		},
		verifyTransfer = function(actor, proof)
			return actor == "owner" and proof == "server-proof"
		end,
	}, Fenced.new(c.backend, opts)))
	if not records then
		assert(c.tribe.epoch("owner") == 0, "issued epoch")
	end
	c.runtime = Runtime.new({
		personal = c.personal,
		profile = function()
			return c.profile
		end,
		install = function(value)
			c.profile = value
		end,
		tribe = c.tribe.transferStore(),
		catalog = M.catalog,
		now = opts.now,
		maxReceipts = cap or 4,
	})
	c.command = function(req: any?): any
		local request = req or c.request
		return c.runtime.command(request, 0, "server-proof", "client")
	end
	return c
end
function M.conserve(c: any, final: boolean)
	local records = c.snapshot()
	local function inventory(key)
		local data = records[key].data
		return if key == M.personalKey
			then data.envelope.genres.survival.inventory.bag
			else Inventory.save(data.aggregate.warehouse)
	end
	local source, destination = inventory(c.request.source), inventory(c.request.destination)
	local owned = 0
	for _, bag in { source, destination } do
		for _, item in bag.items do
			owned += item.quantity
		end
	end
	local receipt = records[c.request.source].data.itemTransfers
	receipt = receipt and receipt.receipts[c.request.id]
	local credited = destination.items[c.request.outputId]
	local escrow = if receipt and receipt.phase == "ESCROWED" and not credited then c.request.quantity else 0
	assert(owned + escrow == 10, "owned plus uncredited escrow equals ten")
	if receipt and receipt.phase == "PREPARED" then
		local bag = Inventory.fromSave(source, M.catalog)
		assert(Inventory.available(bag, "wood") == 7, "reservation not spendable")
		assert(Inventory.consume(bag, "wood", 8, bag.version) == nil, "no dual spend")
	end
	if final then
		assert(source.items.wood.quantity == 7 and credited.quantity == 3, "final seven/three")
		assert(credited.attributes.origin == "forest", "original attribute survives")
	end
	local personal = records[M.personalKey].data
	assert(personal.inventory == nil and personal.envelope.genres.other.coins == 12, "sole personal owner")
	assert(personal.envelope.genres.survival.jobs.pinned == 1, "unrelated pinned jobs preserved")
end
function M.finish(c: any)
	for _ = 1, 8 do
		local results = c.runtime.recover(1)
		assert(#results <= 1, "one transfer work item per budget")
		M.conserve(c, false)
		local records = c.snapshot()
		local receipt = records[c.request.source].data.itemTransfers
		receipt = receipt and receipt.receipts[c.request.id]
		if receipt and receipt.phase == "FINALIZED" then
			M.conserve(c, true)
			return
		end
	end
	error("bounded recovery did not finalize")
end
if process.args[1] == "restore-named" then
	local input = serde.decode("json", process.args[2])
	local c = M.context(input.direction, input.records, input.now + 60, input.cap)
	c.replay = true
	if input.cleanup then
		for _ = 1, 8 do
			local results = c.runtime.recover(1)
			assert(#results <= 1, "bounded cleanup")
			M.conserve(c, true)
		end
		local records = c.snapshot()
		assert(next(records[M.tribeKey].data.transferGrants.entries) == nil, "expired grant reclaimed")
		for _, key in { M.personalKey, M.tribeKey } do
			assert(next(records[key].data.itemTransfers.receipts) == nil, "expired receipts reclaimed")
		end
		assert(c.command().error == "REQUEST_EXPIRED", "reclaimed request cannot remint")
	else
		if not c.snapshot()[M.tribeKey].data.transferGrants then
			assert(c.command().phase == "PREPARED", "unaccepted request retried by ingress")
		elseif not c.snapshot()[M.tribeKey].data.transferGrants.entries[c.request.id] then
			assert(c.command().phase == "PREPARED", "failed grant retried by ingress")
		end
		M.finish(c)
		local response = M.encode(c.command())
		-- Stable public outcome excludes refreshed private owner tokens.
		local first = c.command()
		for _ = 1, 3 do
			local again = c.command()
			assert(
				again.status == first.status and again.phase == first.phase and again.stateVersion == first.stateVersion,
				"terminal replay stable"
			)
		end
		assert(#response > 0, "response encoded")
	end
	print("PASS named restart " .. input.direction .. " " .. input.label)
end
return M
