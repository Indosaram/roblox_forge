--!strict
-- Server-owned coordinator. Grants authorize exact requests, never own items.
local Transfer = require("../../../core/infra/data/ItemTransfer")
local Fenced = require("../../../core/infra/data/FencedStore")
local Personal = require("../../../core/infra/data/PersonalAggregate")
local Settlement = require("./SettlementRuntime")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Ledger = require("../../../core/domain/command/Ledger")
local M = {}
export type Config = {
	personal: Personal.Store,
	profile: () -> Fenced.Profile,
	install: (Fenced.Profile) -> (),
	tribe: Settlement.TransferPort,
	catalog: Catalog.Catalog,
	now: () -> number,
	maxReceipts: number,
	-- Hosts that mint a runtime per call pass one table for the process so the memo below outlives it.
	finalized: { [string]: boolean }?,
}
export type DiscoveryFailure = {
	version: number,
	status: "recovering",
	phase: "DISCOVERY",
	error: "TRANSFER_UNAVAILABLE",
	detail: string?,
}
export type RecoveryResult = Transfer.Result | DiscoveryFailure
export type Runtime = {
	resolveRequest: (RequestInput, number?) -> (Transfer.Request?, string?),
	command: (Transfer.Request, number, any, string, (() -> boolean)?, boolean?) -> Transfer.Result,
	recover: (number) -> { RecoveryResult },
	retire: (Transfer.Request) -> (boolean, string?),
}
export type RequestInput = {
	actor: string,
	epoch: number,
	requestId: string,
	direction: "deposit" | "withdraw",
	itemId: string,
	quantity: number,
	personalKey: string,
}
function M.new(config: Config): Runtime
	assert(Catalog.integer(config.maxReceipts, 1, 4096), "INVALID_RECEIPT_LIMIT")
	local lens = config.personal:inventoryLens()
	local runtime = {} :: Runtime
	local function binding(request: Transfer.Request, origin: string): string
		return Ledger.canonical({ request = request, origin = origin })
	end
	local function personalToken(): Fenced.Profile
		return config.profile()
	end
	local router: Transfer.StorePort = {
		update = function(_self, token, transform)
			if token.key ~= personalToken().key then
				return config.tribe:update(token, transform)
			end
			local updated, err = lens:update(token, transform)
			if updated then
				local current, refreshError = config.personal:refresh(updated)
				if not current then
					return nil, refreshError
				end
				config.install(current)
			end
			return updated, err
		end,
		acquire = function(_self, key, transform)
			if key ~= personalToken().key then
				return config.tribe:acquire(key, transform)
			end
			local updated, err = lens:acquire(key, transform)
			if updated then
				local current, refreshError = config.personal:refresh(updated)
				if not current then
					return nil, refreshError
				end
				config.install(current)
			end
			return updated, err
		end,
	}
	local function tokens(req: Transfer.Request): (Fenced.Profile, Fenced.Profile)
		local personal, tribe = personalToken(), config.tribe.profile()
		return if req.source == personal.key then personal else tribe,
			if req.destination == personal.key then personal else tribe
	end
	local function failed(req: Transfer.Request, err: string, status: string?): Transfer.Result
		local source, destination = tokens(req)
		return {
			version = 1,
			id = req.id,
			status = status or "rejected",
			phase = "GRANT",
			error = err,
			source = source,
			destination = destination,
		}
	end
	-- Grants this process has already driven to FINALIZED. FINALIZED is terminal: advancing it again
	-- only re-reads both records and answers "confirmed". Such a grant stays in the tribe record until
	-- its request expires and is then retired, so without this memo every heartbeat sweep re-advanced
	-- every finished transfer of the player (three personal and two tribe requests each), which in
	-- Studio exhausted the HttpService request quota within two minutes of warehouse use.
	local finalized: { [string]: boolean } = config.finalized or {}
	local function advance(req: Transfer.Request, acceptedBinding: string, origin: string): Transfer.Result
		-- This closure is the capability. It is minted only after a confirmed
		-- read/commit of the irrevocable grant; callers cannot supply it.
		local coordinator = Transfer.new(router, config.catalog, {
			maxReceipts = config.maxReceipts,
			now = config.now,
			authorize = function(candidate, _proof, _data): boolean
				return binding(candidate, origin) == acceptedBinding
			end,
		})
		local source, destination = tokens(req)
		local result = coordinator:advance(source, destination, req, nil)
		if result.status == "confirmed" and result.phase == "FINALIZED" then
			finalized[req.id] = true
		end
		return result
	end
	function runtime.resolveRequest(input, newExpiresAt)
		if
			not Catalog.identity(input.actor)
			or not Catalog.integer(input.epoch, 0, 2 ^ 53 - 2)
			or not Catalog.identity(input.requestId)
			or not Catalog.identity(input.itemId)
			or not Catalog.integer(input.quantity, 1, 1000)
			or (input.direction ~= "deposit" and input.direction ~= "withdraw")
			or input.personalKey ~= personalToken().key
		then
			return nil, "INVALID_TRANSFER_REQUEST"
		end
		local id = "transfer:" .. input.actor .. ":" .. input.epoch .. ":" .. input.requestId
		if not Catalog.identity(id) then
			return nil, "INVALID_TRANSFER_REQUEST"
		end
		local current, err = config.tribe:update(config.tribe.profile(), function(data)
			return data
		end)
		if not current then
			return nil, err
		end
		local source = if input.direction == "deposit" then input.personalKey else current.key
		local destination = if input.direction == "deposit" then current.key else input.personalKey
		local known = current.data.transferGrants.entries[id]
		if known then
			local request = known.request
			if
				request.actor ~= input.actor
				or request.epoch ~= tostring(input.epoch)
				or request.source ~= source
				or request.destination ~= destination
				or request.itemId ~= input.itemId
				or request.quantity ~= input.quantity
			then
				return nil, "TRANSFER_CONFLICT"
			end
			return table.clone(request), nil
		end
		local issued = current.data.authority.epochs[input.actor]
		if
			not issued
			or issued.epoch ~= input.epoch
			or newExpiresAt ~= issued.expiresAt
			or config.now() >= issued.expiresAt
		then
			return nil, "REQUEST_EXPIRED"
		end
		local inventory = current.data.inventory
		if input.direction == "deposit" then
			local projected, reason = router:update(personalToken(), function(data)
				return data
			end)
			if not projected then
				return nil, reason
			end
			inventory = projected.data.inventory
		end
		local item = inventory.items[input.itemId]
		local outputId = if item and item.quantity == input.quantity then input.itemId else id .. ":output"
		if not Catalog.identity(outputId) then
			return nil, "INVALID_TRANSFER_REQUEST"
		end
		return {
			id = id,
			actor = input.actor,
			epoch = tostring(input.epoch),
			expiresAt = issued.expiresAt,
			source = source,
			destination = destination,
			itemId = input.itemId,
			outputId = outputId,
			quantity = input.quantity,
		},
			nil
	end
	-- settle drives the accepted grant through every durable phase in this call
	-- (each phase stays its own crash barrier); without it one phase is taken and
	-- recover() finishes the rest. A failed phase stops the loop for recover().
	function runtime.command(req, revision, proof, origin, admit, settle)
		local personal, tribe = personalToken(), config.tribe.profile()
		if
			not Catalog.identity(req.id)
			or not Catalog.identity(req.actor)
			or not Catalog.identity(req.epoch)
			or not Catalog.identity(req.itemId)
			or not Catalog.identity(req.outputId)
			or not Catalog.integer(req.quantity, 1, 1000)
			or not Catalog.integer(req.expiresAt, 0, 2 ^ 53 - 1)
		then
			return failed(req, "INVALID_TRANSFER_REQUEST")
		end
		if origin ~= "client" and origin ~= "server" then
			return failed(req, "INVALID_ORIGIN")
		end
		if
			not (
				(req.source == personal.key and req.destination == tribe.key)
				or (req.source == tribe.key and req.destination == personal.key)
			)
		then
			return failed(req, "INVALID_TRANSFER_KEYS")
		end
		local canonical = binding(req, origin)
		local reason: string? = nil
		-- Admission once outside backend callback, after confirmed replay lookup.
		local existing, readError = config.tribe:update(tribe, function(data)
			return data
		end)
		if not existing then
			return failed(req, readError or "GRANT_READ_FAILED", "recovering")
		end
		local known = existing.data.transferGrants.entries[req.id]
		if not known and admit and not admit() then
			return failed(req, "RATE_LIMITED")
		end
		local accepted, err = config.tribe:update(existing, function(data)
			reason = nil
			local grants = data.transferGrants.entries
			local grant = grants[req.id]
			if grant then
				if grant.binding ~= canonical then
					reason = "TRANSFER_CONFLICT"
				end
				return data
			end
			if config.now() >= req.expiresAt or req.expiresAt - config.now() > 86400 then
				reason = "REQUEST_EXPIRED"
				return data
			end
			local epoch = tonumber(req.epoch)
			if not epoch or not config.tribe.authority(data, req.actor, epoch, revision, proof) then
				reason = "UNAUTHORIZED"
				return data
			end
			local issued = data.authority.epochs[req.actor]
			if req.expiresAt ~= issued.expiresAt then
				reason = "REQUEST_EXPIRED"
				return data
			end
			local count = 0
			local receipts = if data.itemTransfers then data.itemTransfers.receipts else {}
			for _ in receipts do
				count += 1
			end
			for id in grants do
				if not receipts[id] then
					count += 1
				end
			end
			if count >= config.maxReceipts then
				reason = "RECEIPT_LIMIT"
				return data
			end
			grants[req.id] = { phase = "ACCEPTED", binding = canonical, request = table.clone(req), origin = origin }
			return data
		end)
		if not accepted then
			return failed(req, err or "GRANT_COMMIT_FAILED", "recovering")
		end
		if reason then
			return failed(req, reason)
		end
		local result = advance(req, canonical, origin)
		-- PREPARED -> ESCROWED -> CREDITED -> FINALIZED: at most three more steps.
		local steps = 0
		while settle and result.status == "pending" and result.error == nil and steps < 3 do
			steps += 1
			result = advance(req, canonical, origin)
		end
		return result
	end
	function runtime.recover(maximum)
		assert(Catalog.integer(maximum, 1, 64), "INVALID_RECOVERY_BOUND")
		local results: { RecoveryResult } = {}
		local selected: { string } = {}
		-- Session-scoped tribe key: the projected profile below is this
		-- process's complete, current view. Scan it first; a quiet queue must
		-- cost zero requests instead of one read per sweep.
		local profileOk, projected = pcall(function()
			return config.tribe.profile()
		end)
		if
			profileOk
			and projected
			and type(projected.data) == "table"
			and type(projected.data.transferGrants) == "table"
		then
			local grants = projected.data.transferGrants
			local key = personalToken().key
			local mine = false
			local now = config.now()
			for id, grant in grants.entries do
				if
					(grant.request.source == key or grant.request.destination == key)
					and (not finalized[id] or now >= grant.request.expiresAt)
				then
					mine = true
					break
				end
			end
			if not mine then
				-- Nothing of ours is unfinished or due for retirement: the durable scan
				-- could only reproduce this result. A leftover cursor only orders the next real sweep.
				return {}
			end
		end
		local current, discoveryError = config.tribe:update(config.tribe.profile(), function(data)
			selected = {}
			local grants = data.transferGrants
			local ids: { string } = {}
			local key = personalToken().key
			for id, grant in grants.entries do
				if grant.request.source == key or grant.request.destination == key then
					table.insert(ids, id)
				end
			end
			table.sort(ids)
			grants.cursors = grants.cursors or {}
			local cursor = grants.cursors[key]
			local start = 1
			if cursor then
				for index, id in ids do
					if id > cursor then
						start = index
						break
					end
				end
			end
			for offset = 0, math.min(maximum, #ids) - 1 do
				table.insert(selected, ids[(start + offset - 1) % #ids + 1])
			end
			if #selected > 0 then
				grants.cursors[key] = selected[#selected]
			else
				grants.cursors[key] = nil
			end
			return data
		end)
		if not current then
			-- No authoritative request was discovered; do not invent its identity
			-- or confuse unavailable ownership with an empty recovery queue.
			return {
				{
					version = 1,
					status = "recovering",
					phase = "DISCOVERY",
					error = "TRANSFER_UNAVAILABLE",
					detail = discoveryError,
				},
			}
		end
		for _, id in selected do
			local grant = current.data.transferGrants.entries[id]
			-- Retirement consumes the same selected work item, never an extra sweep.
			-- A pending source is inspected/fenced but never passed to cleanup.
			if config.now() >= grant.request.expiresAt then
				local retired, reason = runtime.retire(grant.request)
				if retired then
					local source, destination = tokens(grant.request)
					local result: Transfer.Result = {
						version = 1,
						id = id,
						status = "confirmed",
						phase = "PRUNED",
						source = source,
						destination = destination,
					}
					table.insert(results, result)
				elseif reason == "TRANSFER_PENDING" then
					table.insert(results, advance(grant.request, grant.binding, grant.origin))
				else
					table.insert(results, failed(grant.request, reason or "RETIRE_FAILED", "recovering"))
				end
			else
				table.insert(results, advance(grant.request, grant.binding, grant.origin))
			end
		end
		return results
	end
	function runtime.retire(req)
		if config.now() < req.expiresAt then
			return false, "REQUEST_ACTIVE"
		end
		local source, destination = tokens(req)
		local phase: string? = nil
		local fenced, err = router:acquire(source.key, function(data)
			local receipt = if data.itemTransfers then data.itemTransfers.receipts[req.id] else nil
			phase = if receipt then receipt.phase else "ABSENT"
			if receipt and Ledger.canonical(receipt.request) ~= Ledger.canonical(req) then
				phase = "CONFLICT"
			end
			return data
		end)
		if not fenced then
			return false, err
		end
		if phase == "CONFLICT" then
			return false, "TRANSFER_CONFLICT"
		end
		if phase ~= "ABSENT" and phase ~= "CANCELLED" and phase ~= "FINALIZED" then
			return false, "TRANSFER_PENDING"
		end
		local coordinator = Transfer.new(router, config.catalog, {
			maxReceipts = config.maxReceipts,
			now = config.now,
			authorize = function()
				return false
			end,
		})
		local cleaned = coordinator:cleanup(fenced, destination, req)
		if cleaned.status ~= "confirmed" then
			return false, cleaned.error
		end
		local cleared, clearError = config.tribe:update(config.tribe.profile(), function(data)
			local grant = data.transferGrants.entries[req.id]
			if grant and Ledger.canonical(grant.request) == Ledger.canonical(req) then
				data.transferGrants.entries[req.id] = nil
			end
			return data
		end)
		return cleared ~= nil, clearError
	end
	return runtime
end
return M
