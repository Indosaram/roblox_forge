--!strict
-- Market: server-authoritative in-game listing ledger (plan §7, §7.1).
-- Every listing key has exactly one writer: the injected store's atomic
-- update (DataStore UpdateAsync semantics). Items move only through the
-- injected transfer port (core/infra/data/ItemTransfer driven to FINALIZED);
-- currency moves only through the injected wallets. Time is always a
-- parameter. Rejections never change state. Anomaly detection only flags
-- accounts for human review; it never bans.
local Ledger = require("../command/Ledger")
local RateLimiter = require("../../anticheat/RateLimiter")
local Wallet = require("../economy/Wallet")

export type Store = { update: (key: string, transform: (old: any) -> any) -> (boolean, any) }
-- Field-compatible with ItemTransfer.Request.
export type TransferRequest = {
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
export type Transfer = (TransferRequest) -> (boolean, string?)
export type Account = { id: string, createdAt: number, playSeconds: number, tutorialComplete: boolean }
export type Item = {
	itemId: string,
	catalogId: string,
	quantity: number,
	attributes: { [string]: any }?,
}
export type Config = {
	currency: string,
	feeBasisPoints: number,
	minFee: number,
	minAccountAgeSeconds: number,
	minPlaySeconds: number,
	dailyTradeCap: number,
	throttle: RateLimiter.ActionConfig,
	outlierHighMilli: number,
	outlierLowMilli: number,
	outlierMinSamples: number,
	escrowKey: string,
	transferSeconds: number,
}
export type Analytics = { emit: (name: string, fields: { [string]: any }) -> (), schema: { [string]: any } }
export type Options = {
	store: Store,
	transfer: Transfer,
	wallet: (account: string) -> Wallet.Wallet,
	config: { [string]: any }?,
	paidCatalogIds: { string }?,
	analytics: Analytics?,
}
export type Listing = {
	id: string,
	seller: string,
	sourceItemId: string,
	itemId: string,
	catalogId: string,
	quantity: number,
	unitPrice: number,
	fee: number,
	createdAt: number,
	status: string,
	buyer: string?,
	outlier: boolean,
}
export type Receipt = {
	id: string,
	kind: string,
	account: string,
	counterparty: string?,
	listingId: string,
	itemId: string,
	quantity: number,
	price: number,
	fee: number,
	at: number,
	binding: string,
	reversed: boolean,
}
export type Result = { ok: boolean, code: string?, listing: Listing?, outlier: boolean? }

local M = {}
M.__index = M

-- Item attribute set by the monetization grant path for Robux-bought items.
M.PAID_ATTRIBUTE = "robuxPurchased"
M.TRADE_ACTION = "MarketTrade"
M.DEFAULTS = table.freeze({
	currency = "coins",
	feeBasisPoints = 500,
	minFee = 1,
	minAccountAgeSeconds = 7 * 86400,
	minPlaySeconds = 2 * 3600,
	dailyTradeCap = 20,
	throttle = table.freeze({ capacity = 5, refillPerSecond = 1 / 60 }),
	outlierHighMilli = 3000,
	outlierLowMilli = 333,
	outlierMinSamples = 3,
	escrowKey = "market:escrow",
	transferSeconds = 3600,
})

export type Market = typeof(setmetatable(
	{} :: {
		_options: Options,
		_config: Config,
		_paid: { [string]: boolean },
		_limiter: RateLimiter.RateLimiter,
		_daily: { [string]: { day: number, count: number } },
		_listings: { [string]: Listing },
		_receipts: { Receipt },
	},
	M
))

local function integer(value: any, minimum: number): boolean
	return type(value) == "number" and value == value and value >= minimum and value <= 2 ^ 53 - 1 and value % 1 == 0
end
local function identity(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128 and not string.find(value, "%c")
end

function M.new(options: Options): Market
	local config: any = table.clone(M.DEFAULTS)
	for key, value in (options.config or {}) :: { [string]: any } do
		assert(M.DEFAULTS[key] ~= nil, "UNKNOWN_MARKET_CONFIG: " .. tostring(key))
		config[key] = value
	end
	assert(identity(config.currency) and identity(config.escrowKey), "INVALID_MARKET_CONFIG")
	for _, key in { "feeBasisPoints", "minFee", "minAccountAgeSeconds", "minPlaySeconds", "outlierMinSamples" } do
		assert(integer(config[key], 0), "INVALID_MARKET_CONFIG: " .. key)
	end
	assert(integer(config.dailyTradeCap, 1) and integer(config.transferSeconds, 1), "INVALID_MARKET_CONFIG")
	assert(integer(config.outlierLowMilli, 1) and config.outlierLowMilli < 1000, "INVALID_MARKET_CONFIG")
	assert(integer(config.outlierHighMilli, 1001), "INVALID_MARKET_CONFIG")
	local paid = {}
	for _, id in (options.paidCatalogIds or {}) :: { string } do
		paid[id] = true
	end
	return setmetatable({
		_options = options,
		_config = config :: Config,
		_paid = paid,
		_limiter = RateLimiter.new({ [M.TRADE_ACTION] = config.throttle }),
		_daily = {},
		_listings = {},
		_receipts = {},
	}, M)
end

local function emit(self: Market, name: string, fields: { [string]: any })
	local analytics = self._options.analytics
	if analytics and analytics.schema[name] ~= nil then
		analytics.emit(name, fields)
	end
end

-- Robux-bought items are never tradeable: one path, no policy branch.
function M.tradeable(self: Market, item: Item): boolean
	return not self._paid[item.catalogId] and not (item.attributes and item.attributes[M.PAID_ATTRIBUTE] == true)
end

-- Eligibility gate: account age, cumulative play, tutorial complete.
function M.eligible(self: Market, account: Account, now: number): (boolean, string?)
	if not identity(account.id) then
		return false, "INVALID_ACCOUNT"
	end
	if now - account.createdAt < self._config.minAccountAgeSeconds then
		return false, "INELIGIBLE_ACCOUNT_AGE"
	end
	if account.playSeconds < self._config.minPlaySeconds then
		return false, "INELIGIBLE_PLAYTIME"
	end
	if account.tutorialComplete ~= true then
		return false, "INELIGIBLE_TUTORIAL"
	end
	return true, nil
end

-- Daily cap is checked without mutation; the throttle token is only consumed
-- once every other gate has passed, so a rejected trade changes nothing else.
local function gate(self: Market, account: Account, now: number): string?
	local ok, code = self:eligible(account, now)
	if not ok then
		return code
	end
	local day = now // 86400
	local entry = self._daily[account.id]
	if entry and entry.day == day and entry.count >= self._config.dailyTradeCap then
		return "DAILY_TRADE_CAP"
	end
	return nil
end
local function consume(self: Market, account: Account, now: number): string?
	if not self._limiter:allow(account.id, M.TRADE_ACTION, now) then
		return "TRADE_THROTTLED"
	end
	local day = now // 86400
	local entry = self._daily[account.id]
	if entry == nil or entry.day ~= day then
		entry = { day = day, count = 0 }
		self._daily[account.id] = entry
	end
	entry.count += 1
	return nil
end

function M.fee(self: Market, quantity: number, unitPrice: number): number
	return math.max(self._config.minFee, (quantity * unitPrice * self._config.feeBasisPoints) // 10000)
end

local function median(values: { number }): number
	table.sort(values)
	local n = #values
	if n % 2 == 1 then
		return values[(n + 1) // 2]
	end
	return (values[n // 2] + values[n // 2 + 1]) / 2
end

-- Outlier flag against the median active unit price of the same catalog item.
-- A flag never rejects; it is stored on the listing for human review.
function M.outlier(self: Market, catalogId: string, unitPrice: number): boolean
	local prices = {}
	for _, listing in self._listings do
		if listing.catalogId == catalogId and listing.status == "active" then
			table.insert(prices, listing.unitPrice)
		end
	end
	if #prices < self._config.outlierMinSamples then
		return false
	end
	local mid = median(prices)
	return unitPrice * 1000 > mid * self._config.outlierHighMilli
		or unitPrice * 1000 < mid * self._config.outlierLowMilli
end

local function record(
	self: Market,
	kind: string,
	account: string,
	counterparty: string?,
	listing: Listing,
	price: number,
	fee: number,
	at: number
)
	local body = {
		id = listing.id .. ":" .. kind,
		kind = kind,
		account = account,
		counterparty = counterparty,
		listingId = listing.id,
		itemId = listing.itemId,
		quantity = listing.quantity,
		price = price,
		fee = fee,
		at = at,
	}
	local receipt: any = table.clone(body)
	receipt.binding = Ledger.canonical(body)
	receipt.reversed = false
	table.insert(self._receipts, receipt)
end

local function request(
	self: Market,
	id: string,
	actor: string,
	source: string,
	destination: string,
	itemId: string,
	outputId: string,
	quantity: number,
	now: number
): TransferRequest
	return {
		id = id,
		actor = actor,
		epoch = "market",
		expiresAt = now + self._config.transferSeconds,
		source = source,
		destination = destination,
		itemId = itemId,
		outputId = outputId,
		quantity = quantity,
	}
end

-- Lists `quantity` units of `item` (the seller's current stack) at a unit
-- price. Debits the soft-currency fee (a sink: credited to nobody) and moves
-- the units into market escrow. Re-listing the same id with the same terms is
-- idempotent; different terms under a taken id are rejected.
function M.list(
	self: Market,
	account: Account,
	item: Item,
	quantity: number,
	unitPrice: number,
	listingId: string,
	now: number
): Result
	if
		not identity(listingId)
		or not identity(item.itemId)
		or not identity(item.catalogId)
		or not integer(quantity, 1)
		or quantity > item.quantity
		or not integer(unitPrice, 1)
	then
		return { ok = false, code = "INVALID_LISTING" }
	end
	local known = self._listings[listingId]
	if known then
		local same = known.seller == account.id
			and known.sourceItemId == item.itemId
			and known.quantity == quantity
			and known.unitPrice == unitPrice
		return if same
			then { ok = true, listing = table.clone(known), outlier = known.outlier }
			else { ok = false, code = "LISTING_EXISTS" }
	end
	if not self:tradeable(item) then
		return { ok = false, code = "UNTRADEABLE_PAID" }
	end
	local blocked = gate(self, account, now)
	if blocked then
		return { ok = false, code = blocked }
	end
	local fee = self:fee(quantity, unitPrice)
	local wallet = self._options.wallet(account.id)
	if not wallet:canAfford(self._config.currency, fee) then
		return { ok = false, code = "INSUFFICIENT_FEE" }
	end
	blocked = consume(self, account, now)
	if blocked then
		return { ok = false, code = blocked }
	end
	local outlier = self:outlier(item.catalogId, unitPrice)
	local listing: Listing = {
		id = listingId,
		seller = account.id,
		sourceItemId = item.itemId,
		itemId = if quantity == item.quantity then item.itemId else listingId,
		catalogId = item.catalogId,
		quantity = quantity,
		unitPrice = unitPrice,
		fee = fee,
		createdAt = now,
		status = "active",
		outlier = outlier,
	}
	local conflict = false
	local committed, value = self._options.store.update("listing:" .. listingId, function(old: any): any
		conflict = old ~= nil
		return if old ~= nil then old else listing
	end)
	if not committed then
		return { ok = false, code = "LISTING_COMMIT_FAILED" }
	end
	if conflict then
		return { ok = false, code = "LISTING_EXISTS" }
	end
	local moved, err = self._options.transfer(
		request(
			self,
			listingId .. ":escrow",
			account.id,
			account.id,
			self._config.escrowKey,
			item.itemId,
			listing.itemId,
			quantity,
			now
		)
	)
	if not moved then
		self._options.store.update("listing:" .. listingId, function(_old: any): any
			return nil
		end)
		return { ok = false, code = err or "ESCROW_FAILED" }
	end
	assert(wallet:debit(self._config.currency, fee), "FEE_DEBIT")
	self._listings[listingId] = value
	record(self, "list", account.id, nil, listing, 0, fee, now)
	emit(
		self,
		"trade_list",
		{ listingId = listingId, catalogId = listing.catalogId, unitPrice = unitPrice, outlier = outlier }
	)
	return { ok = true, listing = table.clone(listing), outlier = outlier }
end

-- Active listings for one catalog item, lowest unit price first; ties by
-- creation time, then id, so the order is total and deterministic.
function M.lowest(self: Market, catalogId: string): { Listing }
	local result = {}
	for _, listing in self._listings do
		if listing.catalogId == catalogId and listing.status == "active" then
			table.insert(result, table.clone(listing))
		end
	end
	table.sort(result, function(a, b)
		if a.unitPrice ~= b.unitPrice then
			return a.unitPrice < b.unitPrice
		end
		if a.createdAt ~= b.createdAt then
			return a.createdAt < b.createdAt
		end
		return a.id < b.id
	end)
	return result
end

-- Buys a whole listing. The listing key's single writer claims it
-- (active -> sold) so concurrent buyers cannot both win.
function M.buy(self: Market, account: Account, listingId: string, now: number): Result
	local listing = self._listings[listingId]
	if not listing or listing.status ~= "active" then
		return { ok = false, code = "LISTING_UNAVAILABLE" }
	end
	if listing.seller == account.id then
		return { ok = false, code = "SELF_TRADE" }
	end
	local blocked = gate(self, account, now)
	if blocked then
		return { ok = false, code = blocked }
	end
	local price = listing.quantity * listing.unitPrice
	local wallet = self._options.wallet(account.id)
	if not wallet:canAfford(self._config.currency, price) then
		return { ok = false, code = "INSUFFICIENT_FUNDS" }
	end
	blocked = consume(self, account, now)
	if blocked then
		return { ok = false, code = blocked }
	end
	local claimed = false
	local committed, value = self._options.store.update("listing:" .. listingId, function(old: any): any
		claimed = old ~= nil and old.status == "active"
		if claimed then
			old.status, old.buyer = "sold", account.id
		end
		return old
	end)
	if not committed or not claimed then
		if committed then
			self._listings[listingId] = value
		end
		return { ok = false, code = if committed then "LISTING_UNAVAILABLE" else "LISTING_COMMIT_FAILED" }
	end
	local moved, err = self._options.transfer(
		request(
			self,
			listingId .. ":deliver",
			account.id,
			self._config.escrowKey,
			account.id,
			listing.itemId,
			listing.itemId,
			listing.quantity,
			now
		)
	)
	if not moved then
		self._options.store.update("listing:" .. listingId, function(old: any): any
			old.status, old.buyer = "active", nil
			return old
		end)
		return { ok = false, code = err or "DELIVERY_FAILED" }
	end
	assert(wallet:debit(self._config.currency, price), "PRICE_DEBIT")
	self._options.wallet(listing.seller):credit(self._config.currency, price)
	self._listings[listingId] = value
	record(self, "buy", account.id, listing.seller, value, price, 0, now)
	emit(self, "trade_buy", { listingId = listingId, buyer = account.id, seller = listing.seller, price = price })
	return { ok = true, listing = table.clone(value) }
end

function M.receipts(self: Market): { Receipt }
	local result = {}
	for _, receipt in self._receipts do
		table.insert(result, table.clone(receipt))
	end
	return result
end

local function bound(receipt: Receipt): boolean
	return receipt.binding
		== Ledger.canonical({
			id = receipt.id,
			kind = receipt.kind,
			account = receipt.account,
			counterparty = receipt.counterparty,
			listingId = receipt.listingId,
			itemId = receipt.itemId,
			quantity = receipt.quantity,
			price = receipt.price,
			fee = receipt.fee,
			at = receipt.at,
		})
end

export type Rollback = { reversed: { string }, skipped: { { id: string, code: string } } }

-- Replays this account's receipts in [from, to] newest first and applies the
-- inverse of each: purchases return the item to the seller and the price to
-- the buyer; listings cancel (escrow back to seller) and refund the fee.
-- Receipts whose binding no longer matches are skipped as TAMPERED. Already
-- reversed receipts are ignored, so a repeated rollback is a no-op.
function M.rollback(self: Market, accountId: string, from: number, to: number, now: number): Rollback
	local outcome: Rollback = { reversed = {}, skipped = {} }
	local currency = self._config.currency
	for index = #self._receipts, 1, -1 do
		local receipt = self._receipts[index]
		if receipt.account ~= accountId or receipt.at < from or receipt.at > to or receipt.reversed then
			continue
		end
		if not bound(receipt) then
			table.insert(outcome.skipped, { id = receipt.id, code = "TAMPERED" })
			continue
		end
		local listing = self._listings[receipt.listingId]
		local code: string? = nil
		if receipt.kind == "buy" then
			local seller = receipt.counterparty :: string
			if not self._options.wallet(seller):debit(currency, receipt.price) then
				code = "SELLER_FUNDS_SPENT"
			else
				local moved, err = self._options.transfer(
					request(
						self,
						receipt.id .. ":rollback",
						accountId,
						accountId,
						seller,
						receipt.itemId,
						receipt.itemId,
						receipt.quantity,
						now
					)
				)
				if moved then
					self._options.wallet(accountId):credit(currency, receipt.price)
					listing.status = "reverted"
				else
					self._options.wallet(seller):credit(currency, receipt.price)
					code = err or "ROLLBACK_TRANSFER_FAILED"
				end
			end
		elseif listing.status == "active" then
			local moved, err = self._options.transfer(
				request(
					self,
					receipt.id .. ":rollback",
					accountId,
					self._config.escrowKey,
					accountId,
					receipt.itemId,
					receipt.itemId,
					receipt.quantity,
					now
				)
			)
			if moved then
				listing.status = "cancelled"
				self._options.wallet(accountId):credit(currency, receipt.fee)
			else
				code = err or "ROLLBACK_TRANSFER_FAILED"
			end
		elseif listing.status == "reverted" then
			-- The purchase was already undone and the item returned to the seller.
			listing.status = "cancelled"
			self._options.wallet(accountId):credit(currency, receipt.fee)
		else
			code = "PURCHASE_NOT_REVERSED"
		end
		if code then
			table.insert(outcome.skipped, { id = receipt.id, code = code })
		else
			receipt.reversed = true
			self._options.store.update("listing:" .. receipt.listingId, function(_old: any): any
				return listing
			end)
			table.insert(outcome.reversed, receipt.id)
		end
	end
	return outcome
end

-- Anomaly detection (§7.1-5). Pure: activity in, flags out. A flag routes
-- the account to human review; there is no automatic suspension.
export type Activity = {
	kind: string, -- "gather" | "craft" | "move" | "transfer"
	at: number,
	x: number?,
	z: number?,
	counterparty: string?,
	direction: string?, -- transfer: "out" | "in"
	value: number?,
}
export type DetectConfig = {
	maxActionsPerMinute: number,
	minSamples: number,
	intervalCvMilli: number,
	cellSize: number,
	maxPeriod: number,
	pathMatchMilli: number,
	oneWayMilli: number,
	oneWayMinTransfers: number,
}
export type Detection = { flagged: boolean, reasons: { string }, review: string }
M.DETECT_DEFAULTS = table.freeze({
	maxActionsPerMinute = 20,
	minSamples = 12,
	intervalCvMilli = 50,
	cellSize = 4,
	maxPeriod = 12,
	pathMatchMilli = 900,
	oneWayMilli = 900,
	oneWayMinTransfers = 5,
})

local function maxRate(times: { number }): number
	local best, start = 0, 1
	for finish = 1, #times do
		while times[finish] - times[start] >= 60 do
			start += 1
		end
		best = math.max(best, finish - start + 1)
	end
	return best
end

local function regular(times: { number }, config: DetectConfig): boolean
	if #times < config.minSamples then
		return false
	end
	local sum, intervals = 0, {}
	for i = 2, #times do
		local gap = times[i] - times[i - 1]
		table.insert(intervals, gap)
		sum += gap
	end
	local mean = sum / #intervals
	if mean <= 0 then
		return true
	end
	local variance = 0
	for _, gap in intervals do
		variance += (gap - mean) ^ 2
	end
	return math.sqrt(variance / #intervals) * 1000 / mean < config.intervalCvMilli
end

local function repeating(cells: { string }, config: DetectConfig): boolean
	if #cells < config.minSamples then
		return false
	end
	for period = 2, math.min(config.maxPeriod, #cells // 2) do
		local matches = 0
		for i = period + 1, #cells do
			if cells[i] == cells[i - period] then
				matches += 1
			end
		end
		if matches * 1000 >= (#cells - period) * config.pathMatchMilli then
			return true
		end
	end
	return false
end

function M.detect(self: Market?, accountId: string, activity: { Activity }, overrides: { [string]: number }?): Detection
	local config: any = table.clone(M.DETECT_DEFAULTS)
	for key, value in (overrides or {}) :: { [string]: number } do
		assert(M.DETECT_DEFAULTS[key] ~= nil, "UNKNOWN_DETECT_CONFIG: " .. tostring(key))
		config[key] = value
	end
	local sorted = table.clone(activity)
	table.sort(sorted, function(a, b)
		return a.at < b.at
	end)
	local actions, gathers, cells = {}, {}, {}
	local flows: { [string]: { out: number, inbound: number, count: number } } = {}
	for _, event in sorted do
		if event.kind == "gather" or event.kind == "craft" then
			table.insert(actions, event.at)
			if event.kind == "gather" then
				table.insert(gathers, event.at)
			end
		end
		if (event.kind == "gather" or event.kind == "move") and event.x and event.z then
			table.insert(cells, (event.x // config.cellSize) .. ":" .. (event.z // config.cellSize))
		end
		if event.kind == "transfer" and event.counterparty then
			local flow = flows[event.counterparty] or { out = 0, inbound = 0, count = 0 }
			flows[event.counterparty] = flow
			local value = event.value or 1
			if event.direction == "out" then
				flow.out += value
			else
				flow.inbound += value
			end
			flow.count += 1
		end
	end
	local reasons = {}
	if maxRate(actions) > config.maxActionsPerMinute then
		table.insert(reasons, "ACTION_RATE")
	end
	if regular(gathers, config) then
		table.insert(reasons, "INTERVAL_REPETITION")
	end
	if repeating(cells, config) then
		table.insert(reasons, "PATH_REPETITION")
	end
	local counterparties = {}
	for counterparty in flows do
		table.insert(counterparties, counterparty)
	end
	table.sort(counterparties)
	for _, counterparty in counterparties do
		local flow = flows[counterparty]
		local total = flow.out + flow.inbound
		if flow.count >= config.oneWayMinTransfers and total > 0 and flow.out * 1000 >= total * config.oneWayMilli then
			table.insert(reasons, "ONE_WAY_TRANSFER")
			break
		end
	end
	local detection = { flagged = #reasons > 0, reasons = reasons, review = if #reasons > 0 then "human" else "none" }
	if self and detection.flagged then
		emit(self, "trade_flag", { account = accountId, reasons = table.concat(reasons, ",") })
	end
	return detection
end

return M
