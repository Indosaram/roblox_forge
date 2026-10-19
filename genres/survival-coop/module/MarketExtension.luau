--!strict
-- Player-to-player Market runtime for survival-coop (plan 7/7.1). A pack calls `configure` once
-- (catalog ids it trades, the account-eligibility port, optional core Market overrides); with no
-- configuration the factory stays disabled.
--
-- Durability model (no in-memory book, no lost escrow):
-- * Each seller owns one Fenced aggregate `mkt:<actor>` (explicit saveVersion). It is the escrow:
--   a listing stores the full item instance it took from the bag, so the units exist in exactly
--   one place at every committed step. The aggregate is held (leased) by the server the seller
--   is in, which makes this server the single writer for that seller's listings.
-- * The buyer/seller bag and the soft-currency balance live in the personal aggregate
--   (`session.personalTransfer`). Every bag/coin change is ONE atomic personal write that also
--   records a marker receipt (`mkl:/mkb:/mkr:/mkp:<listingId>` in itemTransfers.receipts), so a
--   retried step is a no-op. Markers are pruned once the market record has moved past the step.
-- * Cross-aggregate order (crash-safe, resumed by `recover` and by the next command):
--     list:   market escrowing -> personal (take units, debit fee, marker) -> market active
--     buy:    buyer pending -> seller sold(unsettled) -> buyer personal (debit price, add units,
--             marker) -> seller settled -> buyer done; a refused payment reverts sold -> active
--     cancel/expiry: market returning -> personal (add units back, marker) -> market returned
--     proceeds: seller settled&unpaid -> seller personal (credit price, marker) -> market paid
-- * Scope: the book is every active listing held by THIS server, i.e. listings of sellers who are
--   in this server. A seller's listings survive restarts and rejoin anywhere (they reappear when
--   the seller is back); cross-server browsing is out of scope. Expired listings and unsold
--   cancellations return to the bag on the seller's next load/recovery sweep.
-- Eligibility, daily cap, throttle, fee and outlier rules come from core Market; Robux-bought
-- items are never tradeable. Time comes only from `ctx.now`; nothing here rolls dice.
local Shared = require("../../../core/domain/genre/Contract")
local Fenced = require("../../../core/infra/data/FencedStore")
local Market = require("../../../core/domain/market/Market")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")
local Ledger = require("../../../core/domain/command/Ledger")

local M = {}

M.SAVE_VERSION = 2
M.DEFAULT_LISTING_SECONDS = 3 * 86400
M.LIST = "survival-coop:market-list"
M.BUY = "survival-coop:market-buy"
M.CANCEL = "survival-coop:market-cancel"
local GENRE = "survival-coop"
local TOP = 5
local MAX_OUTCOMES = 32
local MAX_HISTORY = 64
local MAX_REQUEST_ID = 100

export type Config = {
	-- Catalog ids that appear in the snapshot (and can be listed).
	catalogIds: { string },
	-- Eligibility facts for an actor; nil means the actor is unknown.
	account: (actor: string, now: number) -> Market.Account?,
	-- Optional core Market config overrides and Robux-bought catalog ids (never tradeable).
	market: { [string]: any }?,
	paidCatalogIds: { string }?,
	-- Seconds an unsold listing stays up before it returns to the seller (genre default 3 days).
	listingSeconds: number?,
}
type Context = {
	store: () -> Fenced.Store,
	now: () -> number,
	content: any,
	personalTransfer: (string) -> any?,
	members: (() -> { string })?,
}
type Entry = { profile: Fenced.Profile, state: any }

local configured: Config? = nil

--- Pack wiring: enables the factory. Asserts the shape so a bad pack fails at startup.
function M.configure(config: Config?)
	if config ~= nil then
		assert(#config.catalogIds > 0, "MARKET_CATALOG_EMPTY")
		assert(type(config.account) == "function", "MARKET_PORTS")
		local seconds = config.listingSeconds
		assert(seconds == nil or (seconds % 1 == 0 and seconds >= 60), "MARKET_LISTING_SECONDS")
	end
	configured = config
end

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = clone(item)
	end
	return copy
end

local function fresh(): any
	return {
		saveVersion = M.SAVE_VERSION,
		version = 0,
		seq = 0,
		listed = {},
		bought = {},
		outcomes = {},
		order = {},
	}
end

function M.migrate(data: Fenced.Data): Fenced.Data
	if next(data) == nil then
		return fresh()
	end
	if data.saveVersion == 1 then
		-- v1 never moved units (the escrow port refused), so its listings carry no escrow.
		assert(type(data.listed) == "table" and type(data.bought) == "table", "INVALID_MARKET_SAVE")
		local listed = {}
		for id, listing in data.listed do
			listed[id] = {
				catalogId = listing.catalogId,
				quantity = listing.quantity,
				unitPrice = listing.unitPrice,
				fee = 0,
				status = "void",
				n = 0,
			}
		end
		return {
			saveVersion = M.SAVE_VERSION,
			version = data.version or 0,
			seq = data.seq or 0,
			listed = listed,
			bought = data.bought,
			outcomes = {},
			order = {},
		}
	end
	assert(data.saveVersion == M.SAVE_VERSION, "UNSUPPORTED_MARKET_SAVE")
	assert(type(data.listed) == "table" and type(data.bought) == "table", "INVALID_MARKET_SAVE")
	assert(type(data.outcomes) == "table" and type(data.order) == "table", "INVALID_MARKET_SAVE")
	return data
end

local function text(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128 and not string.find(value, "%c")
end
local function whole(value: any, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= minimum and value <= maximum
end
local function fail(reason: string, version: number?): Shared.Result
	return { ok = false, reason = reason, stateVersion = version }
end

-- Personal-view helpers (pure over a detached `{ envelope, itemTransfers }` view).
local function bagOf(envelope: any, path: { string }): any?
	local node = envelope
	for _, key in path do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	return if type(node) == "table" and type(node.items) == "table" then node else nil
end
local function setBag(envelope: any, path: { string }, bag: any)
	local node = envelope
	for index = 1, #path - 1 do
		node = node[path[index]]
	end
	node[path[#path]] = bag
end
local function sliceOf(envelope: any): any?
	local genres = if type(envelope) == "table" then envelope.genres else nil
	local slice = if type(genres) == "table" then genres[GENRE] else nil
	return if type(slice) == "table" and type(slice.data) == "table" then slice.data else nil
end
local function balanceOf(envelope: any): number?
	local data = sliceOf(envelope)
	local balance = if data then data.balance else nil
	return if whole(balance, 0, 2 ^ 53 - 1) then balance else nil
end

--- The actor's largest available stack of `catalogId` (ties: lowest item id), reservations excluded.
function M.stack(bag: any, catalogId: string): (string?, number)
	local bestId: string? = nil
	local best = 0
	for itemId, item in bag.items do
		if item.catalogId == catalogId then
			local available = item.quantity
			for _, reservation in (bag.reservations or {}) :: { [string]: { [string]: number } } do
				available -= reservation[itemId] or 0
			end
			if available > best or (available == best and available > 0 and bestId ~= nil and itemId < bestId) then
				bestId, best = itemId, available
			end
		end
	end
	return bestId, best
end

function M.factory(ctx: Context): (Shared.Extension & { close: (() -> Shared.Result)? })?
	local config = configured
	if config == nil then
		return nil
	end
	local store = ctx.store()
	local itemCatalog = Job.catalog(ctx.content)
	local listingSeconds = config.listingSeconds or M.DEFAULT_LISTING_SECONDS
	local entries: { [string]: Entry } = {}
	local closed = false
	local known: { [string]: boolean } = {}
	for _, catalogId in config.catalogIds do
		known[catalogId] = true
		assert(itemCatalog[catalogId] ~= nil, "MARKET_UNKNOWN_CATALOG: " .. catalogId)
	end
	-- Core Market supplies the rules only (eligibility, cap, throttle, fee, outlier, paid items).
	-- Its own book/transfer path is never used, so its store and transfer ports refuse.
	local market = Market.new({
		store = {
			update = function(_key: string, _transform: (any) -> any): (boolean, any)
				return false, "MARKET_BOOK_UNUSED"
			end,
		},
		transfer = function(_request)
			return false, "MARKET_TRANSFER_UNUSED"
		end,
		wallet = function(_actor)
			error("MARKET_WALLET_UNUSED")
		end,
		config = config.market,
		paidCatalogIds = config.paidCatalogIds,
	})
	local settings = market:settings()

	local function load(actor: string): Entry?
		local existing = entries[actor]
		if existing then
			-- Keep the lease alive (a no-op write while healthy); a lost lease reloads durable state.
			local renewed = store:renew(existing.profile)
			if renewed then
				existing.profile = renewed
				return existing
			end
			entries[actor] = nil
		end
		if closed or #actor > 40 then
			return nil
		end
		local profile = store:acquire("mkt:" .. actor, M.migrate)
		if not profile then
			return nil
		end
		local entry: Entry = { profile = profile, state = clone(profile.data) }
		entries[actor] = entry
		return entry
	end
	-- Commits the entry's whole state. On failure the local copy is reloaded from storage.
	local function persist(actor: string, entry: Entry): boolean
		entry.state.version += 1
		local snapshot = clone(entry.state)
		local updated = store:update(entry.profile, function(_data)
			return snapshot
		end)
		if not updated then
			entries[actor] = nil
			return false
		end
		entry.profile = updated
		entry.state = clone(updated.data)
		return true
	end
	local function remember(state: any, requestId: string, binding: string, result: any)
		state.outcomes[requestId] = { binding = binding, result = clone(result) }
		table.insert(state.order, requestId)
		while #state.order > MAX_OUTCOMES do
			state.outcomes[table.remove(state.order, 1) :: string] = nil
		end
	end
	local function trim(state: any)
		local ids: { string } = {}
		for id, listing in state.listed do
			if listing.status == "void" or listing.status == "returned" or listing.paid == true then
				table.insert(ids, id)
			end
		end
		table.sort(ids, function(a, b)
			return (state.listed[a].n or 0) < (state.listed[b].n or 0)
		end)
		for index = 1, #ids - MAX_HISTORY do
			state.listed[ids[index]] = nil
		end
		local bought: { string } = {}
		for id in state.bought do
			table.insert(bought, id)
		end
		table.sort(bought, function(a, b)
			return (state.bought[a].at or 0) < (state.bought[b].at or 0)
		end)
		for index = 1, #bought - MAX_HISTORY do
			state.bought[bought[index]] = nil
		end
	end

	-- One atomic personal write: `apply(view, bag)` mutates the detached view and returns a refusal
	-- reason (nothing is written then). Installs the committed token into the live session.
	-- Third return: true when `apply` refused (definitive), false for a storage failure (ambiguous:
	-- the write may or may not have committed, so callers resume from the marker instead).
	local function mutate(
		actor: string,
		apply: (view: any, bag: any, path: { string }) -> string?
	): (boolean, string?, boolean)
		local port = ctx.personalTransfer(actor)
		if not port then
			return false, "PERSONAL_UNAVAILABLE", false
		end
		local path = port.personal:inventoryPath()
		local reason: string? = nil
		local token, err = port.personal:update(port.profile(), function(view)
			reason = nil
			local work = clone(view)
			local bag = bagOf(work.envelope, path)
			if bag == nil then
				reason = "BAG_UNAVAILABLE"
				return view
			end
			reason = apply(work, bag, path)
			return if reason then view else work
		end)
		if not token then
			return false, err or "PERSONAL_UNAVAILABLE", false
		end
		port.install(token)
		return reason == nil, reason, reason ~= nil
	end
	-- Current committed personal aggregate (read-through), installed into the live session.
	local function current(actor: string): any?
		local port = ctx.personalTransfer(actor)
		if not port then
			return nil
		end
		local token = port.personal:refresh(port.profile())
		if not token then
			return nil
		end
		port.install(token)
		return token.data
	end
	local function receipts(view: any): any
		return view.itemTransfers.receipts
	end
	local function prune(actor: string, marker: string): boolean
		local ok = mutate(actor, function(view)
			receipts(view)[marker] = nil
			return nil
		end)
		return ok
	end
	-- Adds an escrowed instance back into `bag` (in place) under `itemId`.
	local function addItem(view: any, bag: any, path: { string }, listing: any, itemId: string): string?
		local state = Inventory.fromSave(bag, itemCatalog)
		local item = clone(listing.item)
		item.itemId = itemId
		item.quantity = listing.quantity
		local added, err = Inventory.add(state, itemCatalog, item, state.version)
		if not added then
			return if err == "FULL_SLOTS" or err == "FULL_WEIGHT" then "BAG_FULL" else err or "BAG_REFUSED"
		end
		setBag(view.envelope, path, Inventory.save(added))
		return nil
	end
	local function credit(view: any, amount: number): string?
		local data = sliceOf(view.envelope)
		local balance = balanceOf(view.envelope)
		if data == nil or balance == nil then
			return "WALLET_UNAVAILABLE"
		end
		if balance + amount > 1e9 then
			return "WALLET_FULL"
		end
		data.balance = balance + amount
		return nil
	end
	local function debit(view: any, amount: number, refusal: string): string?
		local data = sliceOf(view.envelope)
		local balance = balanceOf(view.envelope)
		if data == nil or balance == nil then
			return "WALLET_UNAVAILABLE"
		end
		if balance < amount then
			return refusal
		end
		data.balance = balance - amount
		return nil
	end

	-- Seller-side sweep: finishes interrupted listings, returns cancelled/expired units and pays
	-- settled proceeds. Needs the seller in this server (personal aggregate). Never raises.
	local function sweep(actor: string, entry: Entry): string?
		if ctx.personalTransfer(actor) == nil then
			return "PERSONAL_UNAVAILABLE"
		end
		local now = ctx.now()
		local ids: { string } = {}
		for id in entry.state.listed do
			table.insert(ids, id)
		end
		table.sort(ids)
		local problem: string? = nil
		for _, id in ids do
			local listing = entry.state.listed[id]
			if listing.status == "escrowing" then
				local data = current(actor)
				if data == nil then
					return "PERSONAL_UNAVAILABLE"
				end
				local committed = receipts(data)["mkl:" .. id] ~= nil
				listing.status = if committed then "active" else "void"
				if not persist(actor, entry) then
					return "SAVE_FAILED"
				end
				listing = entry.state.listed[id]
				if committed then
					prune(actor, "mkl:" .. id)
				end
			end
			if listing.status == "active" and now >= listing.expiresAt then
				listing.status = "returning"
				listing.reason = "expired"
				if not persist(actor, entry) then
					return "SAVE_FAILED"
				end
				listing = entry.state.listed[id]
			end
			if listing.status == "returning" then
				local returned, why = mutate(actor, function(view, bag, path)
					if receipts(view)["mkr:" .. id] ~= nil then
						return nil
					end
					local refused = addItem(view, bag, path, listing, id .. ":r")
					if refused then
						return refused
					end
					receipts(view)["mkr:" .. id] = { phase = "MARKET" }
					return nil
				end)
				if not returned then
					problem = problem or why
				else
					listing.status = "returned"
					if not persist(actor, entry) then
						return "SAVE_FAILED"
					end
					prune(actor, "mkr:" .. id)
				end
			elseif listing.status == "sold" and listing.settled == true and listing.paid ~= true then
				local price = listing.quantity * listing.unitPrice
				local paid, why = mutate(actor, function(view)
					if receipts(view)["mkp:" .. id] ~= nil then
						return nil
					end
					local refused = credit(view, price)
					if refused then
						return refused
					end
					receipts(view)["mkp:" .. id] = { phase = "MARKET" }
					return nil
				end)
				if not paid then
					problem = problem or why
				else
					listing.paid = true
					if not persist(actor, entry) then
						return "SAVE_FAILED"
					end
					prune(actor, "mkp:" .. id)
				end
			end
		end
		trim(entry.state)
		return problem
	end

	-- Buyer-side resume of `state.pending`. Returns the final result once the purchase settled or
	-- was refused, or nil + reason while it must be retried later (pending kept).
	local function resolve(buyer: string, entry: Entry): (Shared.Result?, string?)
		local pending = entry.state.pending
		if pending == nil then
			return nil, nil
		end
		local function finish(result: Shared.Result): (Shared.Result?, string?)
			local open = entry.state.pending
			if result.ok then
				entry.state.bought[pending.listingId] = {
					catalogId = pending.catalogId,
					quantity = pending.quantity,
					price = pending.price,
					seller = pending.seller,
					at = ctx.now(),
				}
			end
			entry.state.pending = nil
			local stored = clone(result)
			stored.stateVersion = entry.state.version + 1
			remember(entry.state, open.requestId, open.binding, stored)
			if not persist(buyer, entry) then
				return nil, "SAVE_FAILED"
			end
			stored.stateVersion = entry.state.version
			return stored, nil
		end
		local seller = load(pending.seller)
		if seller == nil then
			return nil, "SELLER_UNAVAILABLE"
		end
		local id = pending.listingId
		local listing = seller.state.listed[id]
		local mine = listing ~= nil
			and listing.status == "sold"
			and listing.buyer == buyer
			and listing.buyRequest == pending.requestId
		if not mine then
			if listing == nil or listing.status ~= "active" or ctx.now() >= listing.expiresAt then
				return finish({ ok = false, reason = "LISTING_UNAVAILABLE" })
			end
			listing.status, listing.buyer, listing.buyRequest, listing.settled = "sold", buyer, pending.requestId, false
			if not persist(pending.seller, seller) then
				return nil, "SAVE_FAILED"
			end
			listing = seller.state.listed[id]
		end
		if listing.settled ~= true then
			local paid, why, refused = mutate(buyer, function(view, bag, path)
				if receipts(view)["mkb:" .. id] ~= nil then
					return nil
				end
				local refusal = debit(view, pending.price, "INSUFFICIENT_FUNDS")
					or addItem(view, bag, path, listing, id)
				if refusal then
					return refusal
				end
				receipts(view)["mkb:" .. id] = { phase = "MARKET" }
				return nil
			end)
			if not paid then
				if not refused then
					return nil, why
				end
				-- Refused payment: the claim is released, the units stay in the seller's escrow.
				listing.status, listing.buyer, listing.buyRequest, listing.settled = "active", nil, nil, nil
				if not persist(pending.seller, seller) then
					return nil, "SAVE_FAILED"
				end
				return finish({ ok = false, reason = why or "BUY_FAILED" })
			end
			listing.settled = true
			if not persist(pending.seller, seller) then
				return nil, "SAVE_FAILED"
			end
		end
		if ctx.personalTransfer(buyer) ~= nil and not prune(buyer, "mkb:" .. id) then
			return nil, "PERSONAL_UNAVAILABLE"
		end
		local result, err = finish({
			ok = true,
			data = { listingId = id, price = pending.price, catalogId = pending.catalogId },
		})
		-- Pay the seller right away when they are here (otherwise their next sweep does).
		sweep(pending.seller, seller)
		return result, err
	end

	local function holdings(actor: string): { [string]: number }
		local result: { [string]: number } = {}
		local port = ctx.personalTransfer(actor)
		if port == nil then
			return result
		end
		local bag = bagOf(port.profile().data.envelope, port.personal:inventoryPath())
		if bag == nil then
			return result
		end
		for _, catalogId in config.catalogIds do
			local itemId, available = M.stack(bag, catalogId)
			if itemId ~= nil and available > 0 and market:tradeable(bag.items[itemId]) then
				result[catalogId] = available
			end
		end
		return result
	end
	local function activePrices(catalogId: string): { number }
		local now = ctx.now()
		local prices: { number } = {}
		for _, entry in entries do
			for _, listing in entry.state.listed do
				if listing.catalogId == catalogId and listing.status == "active" and now < listing.expiresAt then
					table.insert(prices, listing.unitPrice)
				end
			end
		end
		return prices
	end

	local function list(
		actor: string,
		entry: Entry,
		account: Market.Account,
		args: { any },
		now: number,
		requestId: string
	): Shared.Result
		local version = entry.state.version
		local catalogId, quantity, unitPrice = args[1], args[2], args[3]
		if not text(catalogId) or not whole(quantity, 1, 1000) or not whole(unitPrice, 1, 2 ^ 31) then
			return fail("INVALID_LISTING", version)
		end
		if not known[catalogId] then
			return fail("UNKNOWN_CATALOG", version)
		end
		local port = ctx.personalTransfer(actor)
		if port == nil then
			return fail("PERSONAL_UNAVAILABLE")
		end
		local path = port.personal:inventoryPath()
		local envelope = port.profile().data.envelope
		local bag = bagOf(envelope, path)
		if bag == nil then
			return fail("NOT_OWNED", version)
		end
		local itemId, available = M.stack(bag, catalogId)
		if itemId == nil or available < quantity then
			return fail("NOT_OWNED", version)
		end
		local source = bag.items[itemId]
		if not market:tradeable(source) then
			return fail("UNTRADEABLE_PAID", version)
		end
		-- Core Market only flags outliers; the server refuses them before anything moves.
		if market:priceOutlier(activePrices(catalogId), unitPrice) then
			return fail("PRICE_OUTLIER", version)
		end
		local fee = market:fee(quantity, unitPrice)
		local balance = balanceOf(envelope)
		if balance == nil then
			return fail("WALLET_UNAVAILABLE", version)
		end
		if balance < fee then
			return fail("INSUFFICIENT_FEE", version)
		end
		local blocked = market:admit(account, now)
		if blocked then
			return fail(blocked, version)
		end
		local seq = entry.state.seq + 1
		local id = "mk:" .. actor .. ":" .. seq
		local instance = clone(source)
		instance.itemId, instance.quantity = nil, nil
		entry.state.seq = seq
		entry.state.listed[id] = {
			n = seq,
			catalogId = catalogId,
			quantity = quantity,
			unitPrice = unitPrice,
			fee = fee,
			status = "escrowing",
			createdAt = now,
			expiresAt = now + listingSeconds,
			sourceItemId = itemId,
			item = instance,
			request = requestId,
		}
		if not persist(actor, entry) then
			return fail("SAVE_FAILED")
		end
		local taken, why, refused = mutate(actor, function(view, liveBag, livePath)
			if receipts(view)["mkl:" .. id] ~= nil then
				return nil
			end
			local state = Inventory.fromSave(liveBag, itemCatalog)
			local consumed = Inventory.consume(state, itemId, quantity, state.version)
			if not consumed then
				return "NOT_OWNED"
			end
			setBag(view.envelope, livePath, Inventory.save(consumed))
			local refusal = debit(view, fee, "INSUFFICIENT_FEE")
			if refusal then
				return refusal
			end
			receipts(view)["mkl:" .. id] = { phase = "MARKET" }
			return nil
		end)
		if not taken then
			if not refused then
				-- Ambiguous: the sweep decides from the marker whether the units moved.
				return fail(why or "PERSONAL_UNAVAILABLE")
			end
			entry.state.listed[id].status = "void"
			persist(actor, entry)
			return fail(why or "LIST_FAILED", entry.state.version)
		end
		entry.state.listed[id].status = "active"
		if not persist(actor, entry) then
			return fail("SAVE_FAILED")
		end
		prune(actor, "mkl:" .. id)
		return { ok = true, data = { listingId = id, fee = fee } }
	end

	local function cancel(actor: string, entry: Entry, args: { any }, requestId: string): Shared.Result
		local version = entry.state.version
		local id = args[1]
		if not text(id) then
			return fail("INVALID_LISTING", version)
		end
		local listing = entry.state.listed[id]
		if listing == nil or listing.status ~= "active" then
			return fail("LISTING_UNAVAILABLE", version)
		end
		listing.status, listing.reason, listing.request = "returning", "cancelled", requestId
		if not persist(actor, entry) then
			return fail("SAVE_FAILED")
		end
		listing = entry.state.listed[id]
		local returned, why, refused = mutate(actor, function(view, bag, path)
			if receipts(view)["mkr:" .. id] ~= nil then
				return nil
			end
			local full = addItem(view, bag, path, listing, id .. ":r")
			if full then
				return full
			end
			receipts(view)["mkr:" .. id] = { phase = "MARKET" }
			return nil
		end)
		if not returned then
			if not refused then
				-- Ambiguous: stays "returning"; the sweep finishes it from the marker.
				return fail(why or "PERSONAL_UNAVAILABLE")
			end
			-- Bag full: the listing goes back up; the units never left the escrow.
			listing.status, listing.reason = "active", nil
			persist(actor, entry)
			return fail(why or "CANCEL_FAILED", entry.state.version)
		end
		listing.status = "returned"
		if not persist(actor, entry) then
			return fail("SAVE_FAILED")
		end
		prune(actor, "mkr:" .. id)
		return { ok = true, data = { listingId = id, quantity = listing.quantity } }
	end

	local function row(seller: string, id: string, listing: any): { [string]: any }
		return {
			id = id,
			seller = seller,
			catalogId = listing.catalogId,
			quantity = listing.quantity,
			unitPrice = listing.unitPrice,
			expiresAt = listing.expiresAt,
		}
	end

	local extension = {
		id = "market",
		handles = function(action: string): boolean
			return action == M.LIST or action == M.BUY or action == M.CANCEL
		end,
		command = function(actor, action, args, context, _origin, admit): Shared.Result
			if #context.requestId > MAX_REQUEST_ID then
				return fail("INVALID_REQUEST")
			end
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local entry = load(actor)
			if entry == nil then
				return fail("MARKET_UNAVAILABLE")
			end
			local binding = Ledger.canonical({ action = action, args = args })
			local requestId = context.requestId
			-- An interrupted purchase of this actor resumes first (it may be this very request).
			if entry.state.pending ~= nil then
				local resumed, waiting = resolve(actor, entry)
				if resumed == nil then
					return fail(waiting or "MARKET_PENDING")
				end
			end
			local stored = entry.state.outcomes[requestId]
			if stored then
				if stored.binding ~= binding then
					return fail("REQUEST_CONFLICT")
				end
				return clone(stored.result)
			end
			sweep(actor, entry)
			local function conclude(result: Shared.Result): Shared.Result
				if not result.ok then
					return result
				end
				result.stateVersion = entry.state.version + 1
				remember(entry.state, requestId, binding, result)
				if not persist(actor, entry) then
					return fail("SAVE_FAILED")
				end
				return result
			end
			-- A retried list/cancel whose first attempt got past its first durable step resolves
			-- from the listing it already touched (the sweep above settled any half-done step).
			for id, listing in entry.state.listed do
				if listing.request == requestId then
					local status: string = listing.status
					local returned = status == "returned"
					if status == "escrowing" or status == "returning" then
						return fail("MARKET_PENDING")
					end
					if action == M.LIST and status ~= "void" then
						return conclude({ ok = true, data = { listingId = id, fee = listing.fee } })
					end
					if action == M.CANCEL and returned then
						return conclude({ ok = true, data = { listingId = id, quantity = listing.quantity } })
					end
					return fail(if action == M.LIST then "LIST_FAILED" else "CANCEL_FAILED", entry.state.version)
				end
			end
			local now = ctx.now()
			if action == M.CANCEL then
				return conclude(cancel(actor, entry, args, requestId))
			end
			local account = config.account(actor, now)
			if account == nil then
				return fail("INVALID_ACCOUNT", entry.state.version)
			end
			local eligible, why = market:eligible(account, now)
			if not eligible then
				return fail(why or "INELIGIBLE", entry.state.version)
			end
			if action == M.LIST then
				return conclude(list(actor, entry, account, args, now, requestId))
			end
			local listingId = args[1]
			if not text(listingId) then
				return fail("INVALID_LISTING", entry.state.version)
			end
			local seller: string? = nil
			local target: any = nil
			for owner, held in entries do
				local candidate = held.state.listed[listingId]
				if candidate and candidate.status == "active" and now < candidate.expiresAt then
					seller, target = owner, candidate
				end
			end
			if seller == nil or target == nil then
				return fail("LISTING_UNAVAILABLE", entry.state.version)
			end
			if seller == actor then
				return fail("SELF_TRADE", entry.state.version)
			end
			local price = target.quantity * target.unitPrice
			local port = ctx.personalTransfer(actor)
			local balance = if port then balanceOf(port.profile().data.envelope) else nil
			if balance == nil then
				return fail("WALLET_UNAVAILABLE", entry.state.version)
			end
			if balance < price then
				return fail("INSUFFICIENT_FUNDS", entry.state.version)
			end
			local blocked = market:admit(account, now)
			if blocked then
				return fail(blocked, entry.state.version)
			end
			entry.state.pending = {
				requestId = requestId,
				binding = binding,
				listingId = listingId,
				seller = seller,
				price = price,
				catalogId = target.catalogId,
				quantity = target.quantity,
			}
			if not persist(actor, entry) then
				return fail("SAVE_FAILED")
			end
			local result, waiting = resolve(actor, entry)
			if result == nil then
				return fail(waiting or "MARKET_PENDING")
			end
			return result
		end,
		snapshot = function(actor: string): (Shared.StateData?, string?)
			local entry = load(actor)
			if entry == nil then
				return nil, "MARKET_UNAVAILABLE"
			end
			local now = ctx.now()
			local catalogs: { any } = {}
			for _, catalogId in config.catalogIds do
				local rows: { any } = {}
				for seller, held in entries do
					for id, listing in held.state.listed do
						if
							listing.catalogId == catalogId
							and listing.status == "active"
							and now < listing.expiresAt
						then
							table.insert(rows, row(seller, id, listing))
						end
					end
				end
				table.sort(rows, function(a, b)
					if a.unitPrice ~= b.unitPrice then
						return a.unitPrice < b.unitPrice
					end
					return a.id < b.id
				end)
				for index = #rows, TOP + 1, -1 do
					rows[index] = nil
				end
				table.insert(catalogs, { catalogId = catalogId, listings = rows })
			end
			local listed: { [string]: any } = {}
			for id, listing in entry.state.listed do
				listed[id] = {
					catalogId = listing.catalogId,
					quantity = listing.quantity,
					unitPrice = listing.unitPrice,
					fee = listing.fee,
					status = listing.status,
					expiresAt = listing.expiresAt,
					paid = listing.paid,
					reason = listing.reason,
				}
			end
			local port = ctx.personalTransfer(actor)
			-- Same gate the list/buy commands apply (eligibility + daily cap), without spending a
			-- throttle token, so the panel can disable trading and say why before a refusal.
			local account = config.account(actor, now)
			local blocked = if account == nil then "INVALID_ACCOUNT" else market:blocked(account, now)
			local snapshot: { [string]: any } = {
				eligible = blocked == nil,
				ineligibleReason = blocked,
				saveVersion = entry.state.saveVersion,
				seq = entry.state.seq,
				listed = listed,
				bought = clone(entry.state.bought),
				pending = entry.state.pending ~= nil,
				catalogs = catalogs,
				holdings = holdings(actor),
				balance = if port then balanceOf(port.profile().data.envelope) else nil,
				feeBasisPoints = settings.feeBasisPoints,
				minFee = settings.minFee,
				listingSeconds = listingSeconds,
			}
			return snapshot :: any, nil
		end,
		recover = function(actor: string, _maximum: number): any
			-- Release leases of actors who left so another server can take their market over.
			if ctx.members then
				local members = ctx.members()
				for held, entry in entries do
					if not table.find(members, held) then
						local blocked = false
						for _, other in entries do
							if other.state.pending and other.state.pending.seller == held then
								blocked = true
							end
						end
						-- A departed buyer's pending purchase is durable: it resumes wherever they rejoin.
						if not blocked then
							store:release(entry.profile)
							entries[held] = nil
						end
					end
				end
			end
			local entry = load(actor)
			if entry == nil then
				return { status = "recovering", error = "MARKET_UNAVAILABLE" }
			end
			if entry.state.pending ~= nil then
				local resumed, waiting = resolve(actor, entry)
				if resumed == nil then
					return { status = "recovering", error = waiting }
				end
			end
			local problem = sweep(actor, entry)
			return if problem == nil or problem == "BAG_FULL"
				then { status = "confirmed", transfers = {} }
				else { status = "recovering", error = problem }
		end,
		close = function(): Shared.Result
			closed = true
			for actor, entry in entries do
				local released, err = store:release(entry.profile)
				if not released then
					return { ok = false, reason = err or "RELEASE_FAILED" }
				end
				entries[actor] = nil
			end
			return { ok = true }
		end,
	}
	return extension :: any
end

return M
