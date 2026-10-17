--!strict
-- Player-to-player Market runtime for survival-coop (plan 7/7.1). A pack calls `configure` once
-- (account/wallet/inventory ports, the catalog ids it trades); with no configuration the factory
-- stays disabled. Listing, fee, escrow and settlement decisions belong to core Market; this
-- extension validates every client input, checks inventory ownership through the injected
-- `item` port, rejects outlier prices before anything moves, and records each actor's ledger
-- (listings made, purchases, listing sequence) in a per-actor Fenced profile with an explicit
-- save version. Market has no cancel operation, so there is no cancel command. Time comes only
-- from `ctx.now`; nothing here rolls dice.
local Shared = require("../../../core/domain/genre/Contract")
local Fenced = require("../../../core/infra/data/FencedStore")
local Market = require("../../../core/domain/market/Market")
local Wallet = require("../../../core/domain/economy/Wallet")

local M = {}

M.SAVE_VERSION = 1
local LIST = "survival-coop:market-list"
local BUY = "survival-coop:market-buy"
local TOP = 5

export type Config = {
	-- Catalog ids that appear in the snapshot (and can be listed).
	catalogIds: { string },
	-- Eligibility facts for an actor; nil means the actor is unknown.
	account: (actor: string, now: number) -> Market.Account?,
	wallet: (actor: string) -> Wallet.Wallet,
	-- The actor's current stack of a catalog item (inventory ownership check); nil when not owned.
	item: (actor: string, catalogId: string) -> Market.Item?,
	-- Item mover (core ItemTransfer driven to FINALIZED): bag -> escrow on list, escrow -> bag on buy.
	transfer: Market.Transfer,
	-- Optional Market config overrides and Robux-bought catalog ids (never tradeable).
	market: { [string]: any }?,
	paidCatalogIds: { string }?,
}
type Context = { store: () -> Fenced.Store, now: () -> number }
type State = {
	saveVersion: number,
	version: number,
	seq: number,
	listed: { [string]: { catalogId: string, quantity: number, unitPrice: number, fee: number, status: string } },
	bought: { [string]: { catalogId: string, quantity: number, price: number } },
}
type Entry = { profile: Fenced.Profile, state: State }

local configured: Config? = nil

--- Pack wiring: enables the factory. Asserts the shape so a bad pack fails at startup.
function M.configure(config: Config?)
	if config ~= nil then
		assert(#config.catalogIds > 0, "MARKET_CATALOG_EMPTY")
		assert(type(config.account) == "function" and type(config.wallet) == "function", "MARKET_PORTS")
		assert(type(config.item) == "function" and type(config.transfer) == "function", "MARKET_PORTS")
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

local function fresh(): State
	return { saveVersion = M.SAVE_VERSION, version = 0, seq = 0, listed = {}, bought = {} }
end

function M.migrate(data: Fenced.Data): Fenced.Data
	if next(data) == nil then
		return fresh() :: any
	end
	assert(data.saveVersion == M.SAVE_VERSION, "UNSUPPORTED_MARKET_SAVE")
	assert(type(data.listed) == "table" and type(data.bought) == "table", "INVALID_MARKET_SAVE")
	return data
end

local function text(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128 and not string.find(value, "%c")
end
local function whole(value: any, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= minimum and value <= maximum
end

function M.factory(ctx: Context): (Shared.Extension & { close: (() -> Shared.Result)? })?
	local config = configured
	if config == nil then
		return nil
	end
	local store = ctx.store()
	local entries: { [string]: Entry } = {}
	local closed = false
	local known: { [string]: boolean } = {}
	for _, catalogId in config.catalogIds do
		known[catalogId] = true
	end
	-- Market's single-writer listing store: one process, atomic by construction.
	local book: { [string]: any } = {}
	local market = Market.new({
		store = {
			update = function(key: string, transform: (any) -> any): (boolean, any)
				local value = transform(book[key])
				book[key] = value
				return true, value
			end,
		},
		transfer = config.transfer,
		wallet = config.wallet,
		config = config.market,
		paidCatalogIds = config.paidCatalogIds,
	})

	local function load(actor: string): Entry?
		local existing = entries[actor]
		if existing then
			return existing
		end
		if closed then
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
	local function persist(entry: Entry): boolean
		entry.state.version += 1
		local snapshot = clone(entry.state)
		local updated = store:update(entry.profile, function(_data)
			return snapshot
		end)
		if not updated then
			return false
		end
		entry.profile = updated
		return true
	end
	local function row(listing: Market.Listing): { [string]: any }
		return {
			id = listing.id,
			seller = listing.seller,
			catalogId = listing.catalogId,
			quantity = listing.quantity,
			unitPrice = listing.unitPrice,
			outlier = listing.outlier,
		}
	end

	local extension = {
		id = "market",
		handles = function(action: string): boolean
			return action == LIST or action == BUY
		end,
		command = function(actor, action, args, _context, _origin, admit): Shared.Result
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local entry = load(actor)
			if entry == nil then
				return { ok = false, reason = "MARKET_UNAVAILABLE" }
			end
			local now = ctx.now()
			local account = config.account(actor, now)
			if account == nil then
				return { ok = false, reason = "INVALID_ACCOUNT" }
			end
			local eligible, why = market:eligible(account, now)
			if not eligible then
				return { ok = false, reason = why or "INELIGIBLE" }
			end
			if action == LIST then
				local catalogId, quantity, unitPrice = args[1], args[2], args[3]
				if not text(catalogId) or not whole(quantity, 1, 1000) or not whole(unitPrice, 1, 2 ^ 31) then
					return { ok = false, reason = "INVALID_LISTING" }
				end
				if not known[catalogId] then
					return { ok = false, reason = "UNKNOWN_CATALOG" }
				end
				local item = config.item(actor, catalogId)
				if item == nil or item.catalogId ~= catalogId or item.quantity < quantity then
					return { ok = false, reason = "NOT_OWNED" }
				end
				-- Market only flags outliers; the server refuses them before the item moves.
				if market:outlier(catalogId, unitPrice) then
					return { ok = false, reason = "PRICE_OUTLIER" }
				end
				local listingId = "mk:" .. actor .. ":" .. (entry.state.seq + 1)
				local result = market:list(account, item, quantity, unitPrice, listingId, now)
				if not result.ok or result.listing == nil then
					return { ok = false, reason = result.code or "LIST_FAILED" }
				end
				local listing = result.listing
				entry.state.seq += 1
				entry.state.listed[listingId] = {
					catalogId = catalogId,
					quantity = quantity,
					unitPrice = unitPrice,
					fee = listing.fee,
					status = "active",
				}
				if not persist(entry) then
					return { ok = false, reason = "SAVE_FAILED" }
				end
				return {
					ok = true,
					stateVersion = entry.state.version,
					data = { listingId = listingId, fee = listing.fee },
				}
			end
			local listingId = args[1]
			if not text(listingId) then
				return { ok = false, reason = "INVALID_LISTING" }
			end
			local result = market:buy(account, listingId, now)
			if not result.ok or result.listing == nil then
				return { ok = false, reason = result.code or "BUY_FAILED" }
			end
			local listing = result.listing
			local price = listing.quantity * listing.unitPrice
			entry.state.bought[listingId] =
				{ catalogId = listing.catalogId, quantity = listing.quantity, price = price }
			local seller = load(listing.seller)
			if seller and seller.state.listed[listingId] then
				seller.state.listed[listingId].status = "sold"
				persist(seller)
			end
			if not persist(entry) then
				return { ok = false, reason = "SAVE_FAILED" }
			end
			return { ok = true, stateVersion = entry.state.version, data = { listingId = listingId, price = price } }
		end,
		snapshot = function(actor: string): (Shared.StateData?, string?)
			local entry = load(actor)
			if entry == nil then
				return nil, "MARKET_UNAVAILABLE"
			end
			local catalogs: { any } = {}
			for _, catalogId in config.catalogIds do
				local rows: { any } = {}
				for index, listing in market:lowest(catalogId) do
					if index > TOP then
						break
					end
					table.insert(rows, row(listing))
				end
				table.insert(catalogs, { catalogId = catalogId, listings = rows })
			end
			local snapshot: { [string]: any } = {
				saveVersion = entry.state.saveVersion,
				seq = entry.state.seq,
				listed = clone(entry.state.listed),
				bought = clone(entry.state.bought),
				catalogs = catalogs,
			}
			return snapshot :: any, nil
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
