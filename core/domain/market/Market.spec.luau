--!strict
-- Specs for Market: listing ledger, fee sink, ordering, outliers, paid-item
-- exclusion, eligibility and throttle gates (QA-ECON-02), anomaly detection
-- (QA-ECON-03) and Ledger receipt rollback. Items move through a real
-- ItemTransfer coordinator over FencedStore + MemoryBackend.
local Market = require("./Market")
local Wallet = require("../economy/Wallet")
local Rng = require("../random/Rng")
local Inventory = require("../inventory/Inventory")
local Catalog = require("../inventory/ItemCatalog")
local Transfer = require("../../infra/data/ItemTransfer")
local FencedStore = require("../../infra/data/FencedStore")
local MemoryBackend = require("../../infra/data/MemoryBackend")

local DAY = 86400
local NOW = 30 * DAY
local catalog = Catalog.new({
	{ id = "wood", stackMax = 100, weightMilli = 1000 },
	{ id = "gem", stackMax = 100, weightMilli = 100 },
})

local function account(id: string, overrides: { [string]: any }?): Market.Account
	local value: any = { id = id, createdAt = 0, playSeconds = 10 * 3600, tutorialComplete = true }
	for key, item in (overrides or {}) :: { [string]: any } do
		value[key] = item
	end
	return value
end

local function stack(itemId: string, catalogId: string, quantity: number, attributes: { [string]: any }?): any
	return {
		itemId = itemId,
		catalogId = catalogId,
		quantity = quantity,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = attributes or {},
	}
end

local function fixture(config: { [string]: any }?): any
	local c: any = { now = NOW, wallets = {}, profiles = {}, transfers = 0 }
	c.memory = MemoryBackend.new()
	c.listings = MemoryBackend.new()
	c.store = FencedStore.new(c.memory, {
		sessionId = "server-1",
		leaseSeconds = 3600,
		now = function(): number
			return c.now
		end,
	})
	c.coordinator = Transfer.new(c.store, catalog, {
		maxReceipts = 4096,
		now = function(): number
			return c.now
		end,
		authorize = function(request, proof, _data): boolean
			return proof == "market-server" and c.profiles[request.actor] ~= nil
		end,
	})
	c.profile = function(key: string, items: { any }?)
		c.profiles[key] = assert(c.store:acquire(key, function(data: any): any
			if data.inventory then
				return data
			end
			local inventory = Inventory.new(key, { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
			for _, item in (items or {}) :: { any } do
				inventory = assert(Inventory.add(inventory, catalog, item, inventory.version))
			end
			return { inventory = Inventory.save(inventory) }
		end))
	end
	c.transfer = function(request: Market.TransferRequest): (boolean, string?)
		c.transfers += 1
		if c.failTransfer then
			return false, "INJECTED_TRANSFER_FAILURE"
		end
		for _ = 1, 6 do
			local response = c.coordinator:advance(
				c.profiles[request.source],
				c.profiles[request.destination],
				request,
				"market-server"
			)
			c.profiles[request.source], c.profiles[request.destination] = response.source, response.destination
			if response.status == "confirmed" then
				return true, nil
			elseif response.status ~= "pending" then
				return false, response.error
			end
		end
		return false, "TRANSFER_STUCK"
	end
	c.wallet = function(id: string): Wallet.Wallet
		local wallet = c.wallets[id]
		if not wallet then
			wallet = Wallet.new({ coins = 1000 })
			c.wallets[id] = wallet
		end
		return wallet
	end
	c.events = {}
	c.market = Market.new({
		store = c.listings,
		transfer = c.transfer,
		wallet = c.wallet,
		config = config,
		paidCatalogIds = { "gem" },
		analytics = {
			schema = { trade_list = {}, trade_buy = {}, trade_flag = {} },
			emit = function(name: string, fields: { [string]: any })
				table.insert(c.events, { name = name, fields = fields })
			end,
		},
	})
	c.items = function(key: string): { [string]: any }
		return c.profiles[key].data.inventory.items
	end
	c.stored = function(listingId: string): any
		local _, value = c.listings.update("listing:" .. listingId, function(old: any): any
			return old
		end)
		return value
	end
	c.profile("seller", { stack("wood-1", "wood", 10), stack("gem-1", "gem", 5) })
	c.profile("buyer")
	c.profile("market:escrow")
	return c
end

local function totalCoins(c: any): number
	local sum = 0
	for _, wallet in c.wallets do
		sum += wallet:balance("coins")
	end
	return sum
end

local function botActivity(): { Market.Activity }
	local path = { { 0, 0 }, { 8, 0 }, { 8, 8 }, { 0, 8 } }
	local activity: { Market.Activity } = {}
	for i = 0, 59 do
		local point = path[i % #path + 1]
		table.insert(activity, { kind = "gather", at = i * 6, x = point[1], z = point[2] })
	end
	return activity
end

local function normalActivity(seed: number): { Market.Activity }
	local rng = Rng.new(seed):fork("normal-play")
	local activity: { Market.Activity } = {}
	local at, x, z = 0, 0, 0
	for _ = 1, 60 do
		at += rng:nextInteger(3, 40)
		x += rng:nextInteger(-12, 12)
		z += rng:nextInteger(-12, 12)
		local roll = rng:nextInteger(1, 10)
		table.insert(
			activity,
			{ kind = if roll <= 6 then "gather" elseif roll <= 8 then "craft" else "move", at = at, x = x, z = z }
		)
		if rng:nextInteger(1, 8) == 1 then
			-- Normal trades are exchanges: something goes out, something comes back.
			local friend = "friend-" .. rng:nextInteger(1, 3)
			table.insert(activity, {
				kind = "transfer",
				at = at,
				counterparty = friend,
				direction = "out",
				value = rng:nextInteger(10, 50),
			})
			table.insert(activity, {
				kind = "transfer",
				at = at + 1,
				counterparty = friend,
				direction = "in",
				value = rng:nextInteger(10, 50),
			})
		end
	end
	return activity
end

return {
	["listing escrows units, sinks the fee and writes one receipt"] = function()
		local c = fixture()
		local result = c.market:list(account("seller"), stack("wood-1", "wood", 10), 4, 50, "L1", NOW)
		assert(result.ok, "listing should succeed: " .. tostring(result.code))
		-- fee = max(1, 4*50*500/10000) = 10, credited to nobody.
		assert(c.wallet("seller"):balance("coins") == 990, "fee debited")
		assert(totalCoins(c) == 990, "fee is credited to no wallet")
		assert(c.items("seller")["wood-1"].quantity == 6, "units left the seller")
		assert(c.items("market:escrow")["L1"].quantity == 4, "units sit in escrow")
		assert(c.stored("L1").status == "active", "listing key committed through the store")
		assert(#c.market:receipts() == 1 and c.market:receipts()[1].kind == "list", "one list receipt")
		assert(c.events[1].name == "trade_list", "analytics event emitted")
	end,

	["a taken listing key is never overwritten"] = function()
		local c = fixture()
		assert(c.market:list(account("seller"), stack("wood-1", "wood", 10), 2, 50, "L1", NOW).ok, "first")
		local again = c.market:list(account("seller"), stack("wood-1", "wood", 8), 2, 50, "L1", NOW)
		assert(again.ok, "same terms are idempotent")
		local other = c.market:list(account("seller"), stack("wood-1", "wood", 8), 3, 99, "L1", NOW)
		assert(not other.ok and other.code == "LISTING_EXISTS", "different terms rejected")
		assert(c.stored("L1").unitPrice == 50, "store keeps the first writer's value")
		assert(c.items("seller")["wood-1"].quantity == 8, "no second escrow")
	end,

	["buy claims the key once, moves item and price"] = function()
		local c = fixture()
		assert(c.market:list(account("seller"), stack("wood-1", "wood", 10), 4, 50, "L1", NOW).ok, "list")
		local bought = c.market:buy(account("buyer"), "L1", NOW + 10)
		assert(bought.ok, "buy: " .. tostring(bought.code))
		assert(c.items("buyer")["L1"].quantity == 4, "buyer holds units")
		assert(c.wallet("buyer"):balance("coins") == 800, "buyer paid 200")
		assert(c.wallet("seller"):balance("coins") == 1190, "seller got 200 minus earlier fee")
		local second = c.market:buy(account("third"), "L1", NOW + 11)
		assert(not second.ok and second.code == "LISTING_UNAVAILABLE", "sold listing cannot be bought twice")
		assert(c.stored("L1").status == "sold" and c.stored("L1").buyer == "buyer", "store records the winner")
	end,

	["lowest-price ordering is total and deterministic"] = function()
		local c = fixture()
		local seller = account("seller")
		assert(c.market:list(seller, stack("wood-1", "wood", 10), 1, 30, "Lc", NOW).ok, "c")
		assert(c.market:list(seller, stack("wood-1", "wood", 9), 1, 10, "Lb", NOW + 1).ok, "b")
		assert(c.market:list(seller, stack("wood-1", "wood", 8), 1, 10, "La", NOW + 1).ok, "a")
		assert(c.market:list(seller, stack("wood-1", "wood", 7), 1, 20, "Ld", NOW).ok, "d")
		local order = {}
		for _, listing in c.market:lowest("wood") do
			table.insert(order, listing.id)
		end
		assert(table.concat(order, ",") == "La,Lb,Ld,Lc", "unexpected order: " .. table.concat(order, ","))
	end,

	["price outlier is flagged but not rejected"] = function()
		local c = fixture({ throttle = { capacity = 10, refillPerSecond = 0 } })
		local seller = account("seller")
		for i, price in { 10, 11, 12 } do
			local r = c.market:list(seller, stack("wood-1", "wood", 11 - i), 1, price, "N" .. i, NOW + i)
			assert(r.ok and not r.outlier, "normal price is not an outlier")
		end
		local high = c.market:list(seller, stack("wood-1", "wood", 7), 1, 500, "High", NOW + 10)
		assert(high.ok and high.outlier == true, "500 vs median 11 is flagged")
		local low = c.market:list(seller, stack("wood-1", "wood", 6), 1, 2, "Low", NOW + 11)
		assert(low.ok and low.outlier == true, "2 vs median 11.5 is flagged")
		local fair = c.market:list(seller, stack("wood-1", "wood", 5), 1, 13, "Fair", NOW + 12)
		assert(fair.ok and fair.outlier == false, "13 is within band")
	end,

	["Robux-bought items are untradeable and state is unchanged"] = function()
		local c = fixture()
		local byCatalog = c.market:list(account("seller"), stack("gem-1", "gem", 5), 1, 10, "G1", NOW)
		assert(not byCatalog.ok and byCatalog.code == "UNTRADEABLE_PAID", "paid catalog id rejected")
		local tagged = stack("wood-1", "wood", 10, { [Market.PAID_ATTRIBUTE] = true })
		local byTag = c.market:list(account("seller"), tagged, 1, 10, "W1", NOW)
		assert(not byTag.ok and byTag.code == "UNTRADEABLE_PAID", "paid attribute rejected")
		assert(c.transfers == 0 and c.wallet("seller"):balance("coins") == 1000, "no transfer, no fee")
		assert(c.stored("G1") == nil and c.stored("W1") == nil, "no listing key written")
	end,

	["QA-ECON-02: ineligible accounts are rejected with codes and no state change"] = function()
		local c = fixture()
		local item = stack("wood-1", "wood", 10)
		local cases: { { who: Market.Account, code: string } } = {
			{ who = account("seller", { createdAt = NOW - 6 * DAY }), code = "INELIGIBLE_ACCOUNT_AGE" },
			{ who = account("seller", { playSeconds = 60 }), code = "INELIGIBLE_PLAYTIME" },
			{ who = account("seller", { tutorialComplete = false }), code = "INELIGIBLE_TUTORIAL" },
		}
		for _, case in cases do
			local r = c.market:list(case.who, item, 1, 10, "X", NOW)
			assert(not r.ok and r.code == case.code, "expected " .. case.code .. " got " .. tostring(r.code))
		end
		assert(c.transfers == 0 and c.stored("X") == nil, "state unchanged")
		assert(c.wallet("seller"):balance("coins") == 1000, "no fee")
		-- Exactly at the configured age the gate opens; the age is configurable.
		assert(c.market:eligible(account("seller", { createdAt = NOW - 7 * DAY }), NOW), "7 days is eligible")
		local strict = fixture({ minAccountAgeSeconds = 14 * DAY })
		local ok, code = strict.market:eligible(account("seller", { createdAt = NOW - 10 * DAY }), NOW)
		assert(not ok and code == "INELIGIBLE_ACCOUNT_AGE", "configured 14-day gate")
	end,

	["QA-ECON-02: daily cap + 1 and the count throttle reject without state change"] = function()
		local c = fixture({ dailyTradeCap = 3, throttle = { capacity = 100, refillPerSecond = 1 } })
		local seller = account("seller")
		for i = 1, 3 do
			assert(c.market:list(seller, stack("wood-1", "wood", 11 - i), 1, 10, "C" .. i, NOW + i).ok, "within cap")
		end
		local before = c.transfers
		local over = c.market:list(seller, stack("wood-1", "wood", 7), 1, 10, "C4", NOW + 4)
		assert(not over.ok and over.code == "DAILY_TRADE_CAP", "cap+1 rejected: " .. tostring(over.code))
		assert(
			c.transfers == before and c.stored("C4") == nil and c.items("seller")["wood-1"].quantity == 7,
			"unchanged"
		)
		c.now = NOW + DAY
		for _, key in { "seller", "buyer", "market:escrow" } do
			c.profile(key) -- the server re-acquires leases after a long gap
		end
		local nextDay = c.market:list(seller, stack("wood-1", "wood", 7), 1, 10, "C5", NOW + DAY)
		assert(nextDay.ok, "next day resets the cap: " .. tostring(nextDay.code))

		local t = fixture({ throttle = { capacity = 2, refillPerSecond = 0 } })
		assert(t.market:list(seller, stack("wood-1", "wood", 10), 1, 10, "T1", NOW).ok, "token 1")
		assert(t.market:list(seller, stack("wood-1", "wood", 9), 1, 10, "T2", NOW).ok, "token 2")
		local throttled = t.market:list(seller, stack("wood-1", "wood", 8), 1, 10, "T3", NOW)
		assert(not throttled.ok and throttled.code == "TRADE_THROTTLED", "throttled")
		assert(t.stored("T3") == nil and t.wallet("seller"):balance("coins") == 998, "only two fees paid")
	end,

	["failed escrow releases the listing key and charges nothing"] = function()
		local c = fixture()
		c.failTransfer = true
		local r = c.market:list(account("seller"), stack("wood-1", "wood", 10), 2, 10, "F1", NOW)
		assert(not r.ok and r.code == "INJECTED_TRANSFER_FAILURE", "transfer failure surfaces")
		assert(c.stored("F1") == nil and c.wallet("seller"):balance("coins") == 1000, "no key, no fee")
	end,

	["QA-ECON-03: same-path same-interval bot loop is flagged for human review"] = function()
		local c = fixture()
		local detection = c.market:detect("bot-1", botActivity())
		assert(detection.flagged and detection.review == "human", "bot loop must be flagged")
		local reasons = table.concat(detection.reasons, ",")
		assert(string.find(reasons, "INTERVAL_REPETITION", 1, true), "interval repetition: " .. reasons)
		assert(string.find(reasons, "PATH_REPETITION", 1, true), "path repetition: " .. reasons)
		assert(c.events[#c.events].name == "trade_flag", "flag emitted as analytics")
	end,

	["QA-ECON-03: normal-play seeds produce zero false positives"] = function()
		for seed = 1, 50 do
			local detection = Market.detect(nil, "player", normalActivity(seed))
			assert(
				not detection.flagged,
				"seed " .. seed .. " falsely flagged: " .. table.concat(detection.reasons, ",")
			)
		end
	end,

	["anomaly: gather rate and one-way transfers are flagged"] = function()
		local fast = {}
		for i = 1, 30 do
			table.insert(fast, { kind = "craft", at = i * 2 })
		end
		local rate = Market.detect(nil, "p", fast)
		assert(rate.flagged and rate.reasons[1] == "ACTION_RATE", "30 crafts per minute")
		local funnel = {}
		for i = 1, 6 do
			table.insert(
				funnel,
				{ kind = "transfer", at = i * 100, counterparty = "main", direction = "out", value = 100 }
			)
		end
		local oneWay = Market.detect(nil, "alt", funnel)
		assert(oneWay.flagged and oneWay.reasons[1] == "ONE_WAY_TRANSFER", "alt funnels to main")
		table.insert(funnel, { kind = "transfer", at = 800, counterparty = "main", direction = "in", value = 300 })
		assert(not Market.detect(nil, "alt", funnel).flagged, "balanced exchange is not one-way")
	end,

	["rollback replays receipts for one account and window only"] = function()
		local c = fixture()
		local seller, buyer = account("seller"), account("buyer")
		assert(c.market:list(seller, stack("wood-1", "wood", 10), 4, 50, "L1", NOW).ok, "list L1")
		assert(c.market:list(seller, stack("wood-1", "wood", 6), 2, 10, "L2", NOW + 500).ok, "list L2")
		assert(c.market:buy(buyer, "L1", NOW + 100).ok, "buy L1")
		-- Rolling back the buyer's window undoes only the purchase.
		local undone = c.market:rollback("buyer", NOW, NOW + 200, NOW + 1000)
		assert(#undone.reversed == 1 and undone.reversed[1] == "L1:buy", "only the buy reversed")
		assert(c.items("buyer")["L1"] == nil and c.items("seller")["L1"].quantity == 4, "item returned")
		assert(c.wallet("buyer"):balance("coins") == 1000, "buyer refunded")
		-- Seller window [NOW, NOW+200] covers L1 list only; L2 stays active.
		local seller1 = c.market:rollback("seller", NOW, NOW + 200, NOW + 1001)
		assert(#seller1.reversed == 1 and seller1.reversed[1] == "L1:list", "L1 list reversed")
		assert(c.stored("L1").status == "cancelled" and c.stored("L2").status == "active", "window respected")
		assert(c.wallet("seller"):balance("coins") == 1000 - 1, "L1 fee refunded, L2 fee kept")
		local repeated = c.market:rollback("buyer", NOW, NOW + 200, NOW + 1002)
		assert(#repeated.reversed == 0 and #repeated.skipped == 0, "repeat rollback is a no-op")
	end,

	["rollback skips a tampered receipt"] = function()
		local c = fixture()
		assert(c.market:list(account("seller"), stack("wood-1", "wood", 10), 4, 50, "L1", NOW).ok, "list")
		c.market._receipts[1].fee = 999
		local result = c.market:rollback("seller", 0, NOW + 10, NOW + 10)
		assert(#result.reversed == 0 and result.skipped[1].code == "TAMPERED", "binding mismatch detected")
		assert(c.wallet("seller"):balance("coins") == 990, "no refund on tampered receipt")
	end,

	["seller funds already spent block the buy rollback"] = function()
		local c = fixture()
		assert(c.market:list(account("seller"), stack("wood-1", "wood", 10), 4, 50, "L1", NOW).ok, "list")
		assert(c.market:buy(account("buyer"), "L1", NOW + 1).ok, "buy")
		assert(c.wallet("seller"):debit("coins", 1100), "seller spends the proceeds")
		local result = c.market:rollback("buyer", 0, NOW + 10, NOW + 10)
		assert(result.skipped[1].code == "SELLER_FUNDS_SPENT", "flag instead of negative balance")
		assert(c.items("buyer")["L1"].quantity == 4 and c.wallet("seller"):balance("coins") == 90, "unchanged")
	end,
}
