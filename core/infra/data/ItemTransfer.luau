--!strict
-- Fenced, separate aggregate escrow. Tokens are server-owned capabilities.
-- inventory is Inventory.save; itemTransfers is this module's versioned envelope.
-- authorize MUST be pure and consult server-authoritative actor/epoch/membership
-- proof on EVERY callback before escrow acceptance, not a client-supplied boolean.
-- The caller reacquires both leases after restart and drives advance until confirmed.
-- No refund path exists after escrow. Cleanup requires expired durable finality.
local Inventory = require("../../domain/inventory/Inventory")
local Catalog = require("../../domain/inventory/ItemCatalog")
local FencedStore = require("./FencedStore")

export type StorePort = {
	update: (StorePort, FencedStore.Profile, FencedStore.Transform) -> (FencedStore.Profile?, string?),
	acquire: (StorePort, string, FencedStore.Transform) -> (FencedStore.Profile?, string?),
}
export type Request = {
	id: string,
	actor: string,
	epoch: string,
	expiresAt: number,
	source: string,
	destination: string,
	itemId: string,
	outputId: string,
	quantity: number,
}
export type Options = {
	maxReceipts: number,
	now: () -> number,
	authorize: (Request, any, FencedStore.Data) -> boolean,
}
export type Result = {
	version: number,
	stateVersion: number?,
	id: string,
	status: string,
	phase: string,
	error: string?,
	detail: string?,
	source: FencedStore.Profile,
	destination: FencedStore.Profile,
}
local M = {}
M.__index = M
export type Coordinator = typeof(setmetatable(
	{} :: {
		_store: StorePort,
		_catalog: Catalog.Catalog,
		_options: Options,
	},
	M
))

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in value do
		result[key] = copy(item)
	end
	return result
end

local function same(a: Request, b: Request): boolean
	return a.id == b.id
		and a.actor == b.actor
		and a.epoch == b.epoch
		and a.expiresAt == b.expiresAt
		and a.source == b.source
		and a.destination == b.destination
		and a.itemId == b.itemId
		and a.outputId == b.outputId
		and a.quantity == b.quantity
end

local function envelope(data: FencedStore.Data): any
	local value = data.itemTransfers
	if value == nil then
		value = { version = 1, receipts = {} }
		data.itemTransfers = value
	end
	assert(type(value) == "table" and value.version == 1 and type(value.receipts) == "table", "INVALID_TRANSFER_SAVE")
	return value.receipts
end

local function full(receipts: any, maximum: number, grants: any?, ownId: string?): boolean
	local count = 0
	for _ in receipts do
		count += 1
	end
	if grants then
		assert(grants.version == 1 and type(grants.entries) == "table", "INVALID_TRANSFER_GRANTS")
		for id in grants.entries do
			if id ~= ownId and receipts[id] == nil then
				count += 1
			end
		end
	end
	return count >= maximum
end

function M.new(store: StorePort, catalog: Catalog.Catalog, options: Options): Coordinator
	assert(Catalog.integer(options.maxReceipts, 1, 4096), "INVALID_RECEIPT_LIMIT")
	return setmetatable({ _store = store, _catalog = catalog, _options = table.clone(options) }, M)
end

export type Mint = { request: Request, item: Inventory.Item }
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

-- Pure source callback operation: commit this candidate WITH the producer's
-- debit and immutable grant binding. No minted item enters source inventory.
-- authorize consults current source authority; it must be pure/non-yielding.
-- Retained mint payloads permit exact replay after finalization and expiry.
-- Mint receipts are never eligible for ordinary transfer cleanup.
function M.stageMint(
	data: FencedStore.Data,
	catalog: Catalog.Catalog,
	sourceKey: string,
	binding: string,
	mints: { Mint },
	options: Options,
	proof: any
): (FencedStore.Data?, string?)
	if
		not Catalog.integer(options.maxReceipts, 1, 4096)
		or type(binding) ~= "string"
		or #binding == 0
		or #binding > 16384
		or #mints == 0
		or #mints > 20
	then
		return nil, "INVALID_MINT"
	end
	local candidate = copy(data)
	local receipts = envelope(candidate)
	local seen: { [string]: boolean } = {}
	for _, mint in mints do
		local req, item = mint.request, mint.item
		if
			not Catalog.identity(req.id)
			or seen[req.id]
			or not Catalog.identity(req.actor)
			or not Catalog.identity(req.epoch)
			or not Catalog.identity(req.itemId)
			or not Catalog.identity(req.outputId)
			or not Catalog.identity(req.source)
			or not Catalog.identity(req.destination)
			or #req.source > 50
			or #req.destination > 50
			or req.source ~= sourceKey
			or req.source == req.destination
			or req.itemId ~= req.outputId
			or item.itemId ~= req.itemId
			or item.quantity ~= req.quantity
			or not Catalog.integer(req.quantity, 1, 1000)
			or not Catalog.integer(req.expiresAt, 0, 2 ^ 53 - 1)
		then
			return nil, "INVALID_MINT"
		end
		seen[req.id] = true
		local validation = Inventory.new("mint", { slots = 20, softWeightMilli = 90000, hardWeightMilli = 90000 })
		local valid, validationError = Inventory.add(validation, catalog, item, 0)
		if not valid then
			return nil, validationError
		end
		local known = receipts[req.id]
		if known then
			if
				not same(known.request, req)
				or known.mintBinding ~= binding
				or not equal(known.mintItem, item)
				or (known.phase ~= "ESCROWED" and known.phase ~= "FINALIZED")
			then
				return nil, "TRANSFER_CONFLICT"
			end
		else
			local now = options.now()
			if not Catalog.integer(now, 0, 2 ^ 53 - 1) then
				return nil, "INVALID_CLOCK"
			end
			if now >= req.expiresAt or req.expiresAt - now > 86400 then
				return nil, "REQUEST_EXPIRED"
			end
			if not options.authorize(req, proof, data) then
				return nil, "UNAUTHORIZED"
			end
			if full(receipts, options.maxReceipts, candidate.transferGrants, req.id) then
				return nil, "RECEIPT_LIMIT"
			end
			receipts[req.id] = {
				request = copy(req),
				phase = "ESCROWED",
				item = copy(item),
				mintItem = copy(item),
				mintBinding = binding,
			}
		end
	end
	return candidate, nil
end

-- Each returned phase is a durable crash barrier. PREPARED reserves owned units;
-- ESCROWED removes them from inventory; CREDITED installs destination ownership;
-- FINALIZED is the only confirmed success. Once credited, source escrow is only
-- a liability/receipt and MUST NOT be counted a second time as owned quantity.
-- Output creates a fresh stack (whole moves retain itemId); merging is separate.
function M.advance(
	self: Coordinator,
	source: FencedStore.Profile,
	destination: FencedStore.Profile,
	request: Request,
	proof: any
): Result
	local req: Request = copy(request)
	local terminalVersion: number? = nil
	local function result(status: string, phase: string, err: string?, detail: string?): Result
		return {
			version = 1,
			stateVersion = terminalVersion,
			id = req.id,
			status = status,
			phase = phase,
			error = err,
			detail = detail,
			source = source,
			destination = destination,
		}
	end
	if
		not Catalog.identity(req.id)
		or not Catalog.identity(req.actor)
		or not Catalog.identity(req.epoch)
		or not Catalog.identity(req.itemId)
		or not Catalog.identity(req.outputId)
		or not Catalog.integer(req.quantity, 1, 1000)
		or not Catalog.integer(req.expiresAt, 0, 2 ^ 53 - 1)
		or req.source ~= source.key
		or req.destination ~= destination.key
		or req.source == req.destination
	then
		return result("rejected", "NONE", "INVALID_REQUEST", nil)
	end
	local phase, reason, changed = "NONE", nil :: string?, false
	local escrow: any = nil
	local updated, err = self._store:update(source, function(data)
		terminalVersion = nil
		phase, reason, changed, escrow = "NONE", nil, false, nil
		local receipts = envelope(data)
		local receipt = receipts[req.id]
		if receipt then
			if not same(receipt.request, req) then
				reason = "TRANSFER_CONFLICT"
				return data
			end
			phase = receipt.phase
			terminalVersion = receipt.stateVersion
			if phase == "CANCELLED" then
				reason = receipt.error
				return data
			end
			if phase == "FINALIZED" or phase == "ESCROWED" then
				escrow = copy(receipt.item)
				return data
			end
			if phase ~= "PREPARED" then
				reason = "INVALID_SOURCE_PHASE"
				return data
			end
		end
		local now = self._options.now()
		if not Catalog.integer(now, 0, 2 ^ 53 - 1) then
			reason = "INVALID_CLOCK"
			return data
		end
		if now >= req.expiresAt or req.expiresAt - now > 86400 then
			reason = "REQUEST_EXPIRED"
		elseif not self._options.authorize(req, proof, data) then
			reason = "UNAUTHORIZED"
		end
		if reason then
			if receipt then
				local inventory = Inventory.fromSave(data.inventory, self._catalog)
				local released = assert(Inventory.release(inventory, req.id, inventory.version))
				data.inventory = Inventory.save(released)
				receipt.phase, receipt.error, receipt.item = "CANCELLED", reason, nil
				phase = "CANCELLED"
			end
			return data
		end
		if not receipt and full(receipts, self._options.maxReceipts, data.transferGrants, req.id) then
			reason = "RECEIPT_LIMIT"
			return data
		end
		local inventory = Inventory.fromSave(data.inventory, self._catalog)
		local nextInventory: Inventory.State?
		if not receipt then
			local item = inventory.items[req.itemId]
			if
				not item
				or (req.quantity == item.quantity and req.outputId ~= req.itemId)
				or (
					req.quantity < item.quantity
					and (req.outputId == req.itemId or inventory.items[req.outputId] ~= nil)
				)
			then
				reason = "INVALID_ITEM_ID"
				return data
			end
			nextInventory, reason =
				Inventory.reserve(inventory, req.id, { [req.itemId] = req.quantity }, inventory.version)
			if nextInventory then
				local output = copy(item)
				output.itemId, output.quantity = req.outputId, req.quantity
				receipts[req.id] = { request = copy(req), phase = "PREPARED", item = output }
				phase = "PREPARED"
			end
		else
			nextInventory, reason = Inventory.exchange(inventory, self._catalog, req.id, {}, inventory.version)
			if nextInventory then
				receipt.phase = "ESCROWED"
				phase = "ESCROWED"
			end
		end
		if nextInventory then
			data.inventory = Inventory.save(nextInventory)
			changed = true
		end
		return data
	end)
	if not updated then
		return result("recovering", "SOURCE_UNKNOWN", "SOURCE_COMMIT_FAILED", err)
	end
	source = updated
	if reason then
		return result("rejected", phase, reason, nil)
	end
	if phase == "FINALIZED" then
		return result("confirmed", phase, nil, nil)
	end
	if changed then
		return result("pending", phase, nil, nil)
	end
	local credited = false
	local target, targetError = self._store:update(destination, function(data)
		reason, credited = nil, false
		local receipts = envelope(data)
		local receipt = receipts[req.id]
		if receipt then
			if not same(receipt.request, req) then
				reason = "TRANSFER_CONFLICT"
			elseif receipt.phase ~= "CREDITED" then
				reason = "INVALID_DESTINATION_PHASE"
			end
			return data
		end
		if full(receipts, self._options.maxReceipts, data.transferGrants, req.id) then
			reason = "RECEIPT_LIMIT"
			return data
		end
		local inventory = Inventory.fromSave(data.inventory, self._catalog)
		local nextInventory
		nextInventory, reason = Inventory.add(inventory, self._catalog, escrow, inventory.version)
		if nextInventory then
			data.inventory = Inventory.save(nextInventory)
			receipts[req.id] = { request = copy(req), phase = "CREDITED" }
			credited = true
		end
		return data
	end)
	if not target then
		return result("recovering", "DESTINATION_UNKNOWN", "DESTINATION_COMMIT_FAILED", targetError)
	end
	destination = target
	if reason then
		return result("recovering", "ESCROWED", reason, nil)
	end
	if credited then
		return result("pending", "CREDITED", nil, nil)
	end
	-- Only a confirmed matching destination receipt permits source finalization.
	local finalized, finalError = self._store:update(source, function(data)
		reason = nil
		terminalVersion = nil
		local receipt = envelope(data)[req.id]
		if not receipt or not same(receipt.request, req) then
			reason = "TRANSFER_CONFLICT"
		elseif receipt.phase ~= "ESCROWED" and receipt.phase ~= "FINALIZED" then
			reason = "INVALID_SOURCE_PHASE"
		else
			receipt.phase = "FINALIZED"
			receipt.item = nil
			if not receipt.stateVersion then
				local transfers = data.itemTransfers
				assert(Catalog.integer(transfers.stateVersion or 0, 0, 2 ^ 53 - 2), "TRANSFER_VERSION_EXHAUSTED")
				transfers.stateVersion = (transfers.stateVersion or 0) + 1
				receipt.stateVersion = transfers.stateVersion
			end
			terminalVersion = receipt.stateVersion
		end
		return data
	end)
	if not finalized then
		return result("recovering", "FINALIZE_UNKNOWN", "SOURCE_COMMIT_FAILED", finalError)
	end
	source = finalized
	if reason then
		return result("recovering", "CREDITED", reason, nil)
	end
	return result("confirmed", "FINALIZED", nil, nil)
end

-- Finality handshake: read actual source -> acquire a NEW destination generation
-- and mark SOURCE_FINALIZED -> delete source -> delete destination tombstone.
-- The new generation is essential: a suspended older credit callback must not
-- recreate a pruned receipt. Never pass cached booleans as finalization proof.
-- Returned destination replaces the caller's old token even on partial cleanup.
function M.cleanup(
	self: Coordinator,
	source: FencedStore.Profile,
	destination: FencedStore.Profile,
	request: Request
): Result
	local req: Request = copy(request)
	local phase, reason = "CLEANUP", nil :: string?
	local function response(status: string, err: string?, detail: string?): Result
		return {
			version = 1,
			id = req.id,
			status = status,
			phase = phase,
			error = err,
			detail = detail,
			source = source,
			destination = destination,
		}
	end
	local now = self._options.now()
	if
		req.source ~= source.key
		or req.destination ~= destination.key
		or req.source == req.destination
		or not Catalog.identity(req.id)
		or not Catalog.integer(req.expiresAt, 0, 2 ^ 53 - 1)
		or not Catalog.integer(now, 0, 2 ^ 53 - 1)
		or now < req.expiresAt
	then
		return response("rejected", "CLEANUP_NOT_EXPIRED", nil)
	end
	local finalPhase: string? = nil
	local checked, err = self._store:update(source, function(data)
		reason, finalPhase = nil, nil
		local receipt = envelope(data)[req.id]
		if receipt then
			if receipt.mintBinding then
				reason = "MINT_RETAINED"
			elseif not same(receipt.request, req) then
				reason = "TRANSFER_CONFLICT"
			elseif receipt.phase ~= "FINALIZED" and receipt.phase ~= "CANCELLED" then
				reason = "TRANSFER_PENDING"
			else
				finalPhase = receipt.phase
			end
		end
		return data
	end)
	if not checked then
		return response("recovering", "SOURCE_COMMIT_FAILED", err)
	end
	source = checked
	if reason then
		return response("rejected", reason, nil)
	end
	-- FencedStore.acquire checks current lease ownership atomically; the caller's
	-- destination snapshot is never evidence. A stale same-session token cannot
	-- credit after this new generation, including after tombstone deletion.
	local marked, markError = self._store:acquire(destination.key, function(data)
		reason = nil
		local receipt = envelope(data)[req.id]
		if receipt then
			if not same(receipt.request, req) then
				reason = "TRANSFER_CONFLICT"
			elseif receipt.phase == "CREDITED" and finalPhase == "FINALIZED" then
				receipt.phase = "SOURCE_FINALIZED"
			elseif receipt.phase ~= "SOURCE_FINALIZED" then
				reason = "FINALITY_NOT_PROVEN"
			end
		elseif finalPhase == "FINALIZED" then
			reason = "DESTINATION_RECEIPT_MISSING"
		end
		return data
	end)
	if not marked then
		return response("recovering", "DESTINATION_COMMIT_FAILED", markError)
	end
	destination = marked
	if reason then
		return response("rejected", reason, nil)
	end
	local cleared, clearError = self._store:update(source, function(data)
		reason = nil
		local receipts = envelope(data)
		local receipt = receipts[req.id]
		if receipt then
			if not same(receipt.request, req) then
				reason = "TRANSFER_CONFLICT"
			elseif receipt.phase == "FINALIZED" or receipt.phase == "CANCELLED" then
				receipts[req.id] = nil
			else
				reason = "TRANSFER_PENDING"
			end
		end
		return data
	end)
	if not cleared then
		return response("recovering", "SOURCE_COMMIT_FAILED", clearError)
	end
	source = cleared
	if reason then
		return response("recovering", reason, nil)
	end
	local removed, removeError = self._store:update(destination, function(data)
		reason = nil
		local receipts = envelope(data)
		local receipt = receipts[req.id]
		if receipt then
			if not same(receipt.request, req) then
				reason = "TRANSFER_CONFLICT"
			elseif receipt.phase == "SOURCE_FINALIZED" then
				receipts[req.id] = nil
			else
				reason = "FINALITY_NOT_PROVEN"
			end
		end
		return data
	end)
	if not removed then
		return response("recovering", "DESTINATION_COMMIT_FAILED", removeError)
	end
	destination = removed
	if reason then
		return response("recovering", reason, nil)
	end
	phase = "PRUNED"
	return response("confirmed", nil, nil)
end

return M
