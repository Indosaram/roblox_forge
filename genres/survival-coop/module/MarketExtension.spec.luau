--!strict
-- MarketExtension over a real PersonalAggregate (bag + Coins balance + receipts) and real Fenced
-- market aggregates on one MemoryBackend: escrow persistence, cancel, expiry return, atomic coin
-- settlement, idempotent replay across ambiguous writes, and every refusal leaving state intact.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Fenced = require("../../../core/infra/data/FencedStore")
local PersonalAggregate = require("../../../core/infra/data/PersonalAggregate")
local Content = require("../../../core/domain/survival/Content")
local Market = require("./MarketExtension")

local DAY = 86400
local PATH = { "genres", "survival-coop", "data", "inventory", "bag" }

local content = assert(Content.canonicalize(serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))))
local budget = {
	encode = function(value: any): string
		return serde.encode("json", value)
	end,
}

local function envelope(balance: number, items: { any }): any
	local map = {}
	for _, item in items do
		map[item.itemId] = item
	end
	return {
		version = 1,
		genres = {
			["survival-coop"] = {
				version = 1,
				data = {
					balance = balance,
					inventory = {
						bag = {
							id = "bag",
							version = 0,
							saveVersion = 1,
							limits = { slots = 4, softWeightMilli = 60000, hardWeightMilli = 90000 },
							items = map,
							reservations = {},
						},
					},
				},
			},
		},
	}
end
local function stack(itemId: string, catalogId: string, quantity: number, attributes: any?): any
	return {
		itemId = itemId,
		catalogId = catalogId,
		quantity = quantity,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = attributes or {},
	}
end

-- One "world": a backend, a clock, players' personal aggregates and a market extension.
local function world(seed: { [string]: any })
	local backend = Memory.new()
	local clock = { now = 30 * DAY }
	local now = function()
		return clock.now
	end
	local personal = PersonalAggregate.new(backend, {
		namespace = "personal",
		inventoryPath = PATH,
		validateEnvelope = function(value)
			return type(value) == "table" and value.version == 1
		end,
		store = { sessionId = "players", leaseSeconds = 120, now = now, budget = budget },
	})
	local tokens: { [string]: any } = {}
	local faults: { [string]: string } = {}
	for actor, value in seed do
		tokens[actor] = assert(personal:load(actor, function()
			return value
		end))
	end
	-- Fault injection on the next personal write: "fail" = nothing written, "lost" = written but
	-- the acknowledgement is lost. Both look identical to the caller (an ambiguous failure).
	local function port(actor: string): any
		if tokens[actor] == nil then
			return nil
		end
		return {
			personal = {
				inventoryPath = function(_self)
					return personal:inventoryPath()
				end,
				refresh = function(_self, token)
					return personal:refresh(token)
				end,
				update = function(_self, token, transform): (any, string?)
					local fault = faults[actor]
					faults[actor] = nil
					if fault == "fail" then
						return nil, "throttled"
					end
					local updated, err = personal:update(token, transform)
					if fault == "lost" then
						if updated then
							tokens[actor] = updated
						end
						return nil, "throttled"
					end
					return updated, err
				end,
			},
			profile = function()
				return tokens[actor]
			end,
			install = function(token)
				tokens[actor] = token
			end,
		}
	end
	local eligible: { [string]: boolean } = {}
	local self = {
		backend = backend,
		clock = clock,
		tokens = tokens,
		faults = faults,
		eligible = eligible,
		extension = nil :: any,
	}
	-- Players reconnect: their personal aggregates are acquired again (fresh leases).
	function self.rejoin()
		for actor in tokens do
			tokens[actor] = assert(personal:load(actor, function()
				error("existing aggregate")
			end))
		end
	end
	function self.open(sessionId: string, members: { string }?)
		Market.configure({
			catalogIds = { "wood", "fiber" },
			account = function(actor, at)
				return {
					id = actor,
					createdAt = at - 30 * DAY,
					playSeconds = 10 * 3600,
					tutorialComplete = eligible[actor] ~= false,
				}
			end,
			market = { currency = "Coins", throttle = { capacity = 100, refillPerSecond = 1 } },
			listingSeconds = DAY,
		})
		self.extension = assert(Market.factory({
			store = function()
				return Fenced.new(backend, { sessionId = sessionId, leaseSeconds = 120, now = now, budget = budget })
			end,
			now = now,
			content = content,
			personalTransfer = port,
			members = function()
				return members or { "1", "2", "3" }
			end,
		}))
		return self.extension
	end
	function self.command(actor: string, action: string, args: { any }, requestId: string): any
		return self.extension.command(
			actor,
			"survival-coop:market-" .. action,
			args,
			{ actorId = actor, requestId = requestId, sessionEpoch = 0 },
			"client",
			function()
				return { ok = true }
			end
		)
	end
	function self.balance(actor: string): number
		return tokens[actor].data.envelope.genres["survival-coop"].data.balance
	end
	function self.held(actor: string, catalogId: string): number
		local total = 0
		for _, item in tokens[actor].data.envelope.genres["survival-coop"].data.inventory.bag.items do
			if item.catalogId == catalogId then
				total += item.quantity
			end
		end
		return total
	end
	function self.markers(actor: string): number
		local count = 0
		for _ in tokens[actor].data.itemTransfers.receipts do
			count += 1
		end
		return count
	end
	return self
end

local function standard()
	return world({
		["1"] = envelope(100, { stack("w1", "wood", 10) }),
		["2"] = envelope(150, {}),
		["3"] = envelope(10, {}),
	})
end

return {
	["actor handoff settles ambiguous buyer payment and conserves seller buyer fee and escrow"] = function()
		for _, fault in { "fail", "lost" } do
			local w = standard()
			local market = w.open("origin")
			assert(w.command("1", "list", { "wood", 4, 25 }, "list").ok, "escrow listing")
			w.faults["2"] = fault
			assert(not w.command("2", "buy", { "mk:1:1" }, "buy").ok, "payment barrier")
			assert(market.drain("2").ok, "handoff drains pending purchase")
			assert(w.held("1", "wood") + w.held("2", "wood") == 10, "bag plus settled escrow item conservation")
			assert(w.balance("1") + w.balance("2") + 5 == 250, "buyer plus seller plus explicit fee conservation")
			assert(market.releaseActor("2").ok, "buyer release")
			assert(market.releaseActor("2").ok, "duplicate buyer release")
			assert(market.recover("2", 8).status == "confirmed", "old sweep does not reacquire")
			assert(market.snapshot("2") == nil, "departed buyer cannot load through snapshot")
			assert(market.resumeActor("2").ok, "origin reacquisition")
			assert(w.command("2", "buy", { "mk:1:1" }, "buy").ok, "replay purchase")
			assert(
				w.balance("1") + w.balance("2") + 5 == 250 and w.held("2", "wood") == 4,
				"duplicate receipt grants zero extra"
			)
			assert(market.close().ok, "close")
		end
	end,
	["factory stays disabled without configuration"] = function()
		Market.configure(nil)
		assert(Market.factory({} :: any) == nil, "disabled")
	end,
	["list escrows units out of the bag and debits the fee"] = function()
		local w = standard()
		local market = w.open("srv-a")
		local listed = w.command("1", "list", { "wood", 4, 25 }, "l1")
		assert(listed.ok and listed.data.listingId == "mk:1:1", tostring(listed.reason))
		-- fee = max(minFee 1, 4 * 25 * 500bp) = 5
		assert(listed.data.fee == 5 and listed.stateVersion ~= nil, "fee and durable outcome")
		assert(w.held("1", "wood") == 6 and w.balance("1") == 95, "bag -4, coins -5")
		assert(w.markers("1") == 0, "listing marker pruned")
		local view = market.snapshot("2")
		local row = view.catalogs[1].listings[1]
		assert(row.unitPrice == 25 and row.quantity == 4 and row.seller == "1", "listing visible to buyers")
		assert(market.snapshot("1").holdings.wood == 6, "holdings reflect the bag")
		assert(market.close().ok, "close")
	end,
	["escrow survives a server restart and the seller can cancel it back"] = function()
		local w = standard()
		local first = w.open("srv-a")
		assert(w.command("1", "list", { "wood", 4, 25 }, "l1").ok, "list")
		assert(first.close().ok, "close releases the market lease")
		local second = w.open("srv-b")
		local mine = second.snapshot("1")
		assert(mine.listed["mk:1:1"].status == "active", "escrowed listing reloaded")
		assert(second.snapshot("2").catalogs[1].listings[1].id == "mk:1:1", "visible again after rejoin")
		local cancelled = w.command("1", "cancel", { "mk:1:1" }, "c1")
		assert(cancelled.ok and cancelled.data.quantity == 4, tostring(cancelled.reason))
		assert(w.held("1", "wood") == 10 and w.balance("1") == 95, "units back, fee is a sink")
		assert(#second.snapshot("2").catalogs[1].listings == 0, "cancelled listing leaves the book")
		local again = w.command("1", "cancel", { "mk:1:1" }, "c1")
		assert(again.ok and w.held("1", "wood") == 10, "replayed cancel returns the stored outcome only")
		assert(w.command("1", "cancel", { "mk:1:1" }, "c2").reason == "LISTING_UNAVAILABLE", "double cancel")
		assert(w.command("2", "cancel", { "mk:1:1" }, "c3").reason == "LISTING_UNAVAILABLE", "not the owner")
		assert(second.close().ok, "close")
	end,
	["an expired listing returns to the seller on their next load"] = function()
		local w = standard()
		local first = w.open("srv-a")
		assert(w.command("1", "list", { "wood", 3, 20 }, "l1").ok, "list")
		assert(first.close().ok, "close")
		w.clock.now += DAY + 1
		w.rejoin()
		local second = w.open("srv-b")
		assert(#second.snapshot("2").catalogs[1].listings == 0, "expired listing is not buyable")
		local recovered = second.recover("1", 8)
		assert(recovered.status == "confirmed", tostring(recovered.error))
		assert(w.held("1", "wood") == 10, "units returned")
		local listing = second.snapshot("1").listed["mk:1:1"]
		assert(listing.status == "returned" and listing.reason == "expired", "expiry recorded")
		assert(second.close().ok, "close")
	end,
	["buy moves coins atomically, applies the fee and delivers the units"] = function()
		local w = standard()
		local market = w.open("srv-a")
		assert(w.command("1", "list", { "wood", 4, 25 }, "l1").ok, "list")
		local bought = w.command("2", "buy", { "mk:1:1" }, "b1")
		assert(bought.ok and bought.data.price == 100, tostring(bought.reason))
		assert(w.balance("2") == 50 and w.held("2", "wood") == 4, "buyer -100 coins, +4 wood")
		assert(w.balance("1") == 195 and w.held("1", "wood") == 6, "seller +100 coins (fee 5 sunk)")
		assert(w.markers("1") == 0 and w.markers("2") == 0, "markers pruned")
		local seller = market.snapshot("1").listed["mk:1:1"]
		assert(seller.status == "sold" and seller.paid == true, "seller ledger")
		assert(market.snapshot("2").bought["mk:1:1"].price == 100, "buyer ledger")
		local replay = w.command("2", "buy", { "mk:1:1" }, "b1")
		assert(replay.ok and replay.stateVersion == bought.stateVersion, "replay returns the stored outcome")
		assert(w.balance("2") == 50 and w.balance("1") == 195 and w.held("2", "wood") == 4, "no second debit")
		assert(w.command("2", "buy", { "mk:1:1" }, "b1x").reason == "LISTING_UNAVAILABLE", "sold out")
		assert(w.command("2", "buy", { "mk:1:1" }, "b1").ok, "same id still replays")
		assert(w.command("2", "list", { "wood", 1, 25 }, "b1").reason == "REQUEST_CONFLICT", "id bound to args")
		assert(market.close().ok, "close")
	end,
	["an ambiguous payment write resumes exactly once"] = function()
		for _, fault in { "fail", "lost" } do
			local w = standard()
			local market = w.open("srv-a")
			assert(w.command("1", "list", { "wood", 4, 25 }, "l1").ok, "list")
			w.faults["2"] = fault
			local first = w.command("2", "buy", { "mk:1:1" }, "b1")
			assert(not first.ok and first.stateVersion == nil, fault .. ": unsettled, client keeps the id")
			assert(market.snapshot("2").pending == true, fault .. ": purchase pending durably")
			assert(#market.snapshot("3").catalogs[1].listings == 0, fault .. ": claimed listing is off the book")
			local retried = w.command("2", "buy", { "mk:1:1" }, "b1")
			assert(retried.ok and retried.data.price == 100, fault .. ": " .. tostring(retried.reason))
			assert(w.balance("2") == 50 and w.held("2", "wood") == 4, fault .. ": debited and delivered once")
			assert(w.balance("1") == 195, fault .. ": seller paid once")
			assert(market.close().ok, "close")
		end
	end,
	["a pending purchase resumes after a restart through recovery"] = function()
		local w = standard()
		local first = w.open("srv-a")
		assert(w.command("1", "list", { "wood", 4, 25 }, "l1").ok, "list")
		w.faults["2"] = "lost"
		assert(not w.command("2", "buy", { "mk:1:1" }, "b1").ok, "ack lost")
		assert(first.close().ok, "close")
		local second = w.open("srv-b")
		assert(second.recover("2", 8).status == "confirmed", "buyer recovery settles the purchase")
		assert(w.balance("2") == 50 and w.held("2", "wood") == 4 and w.balance("1") == 195, "settled once")
		local replay = w.command("2", "buy", { "mk:1:1" }, "b1")
		assert(replay.ok and replay.data.price == 100, "the original request id gets the settled result")
		assert(second.close().ok, "close")
	end,
	["insufficient coins refuses before anything moves"] = function()
		local w = standard()
		local market = w.open("srv-a")
		assert(w.command("1", "list", { "wood", 4, 25 }, "l1").ok, "list")
		local poor = w.command("3", "buy", { "mk:1:1" }, "p1")
		assert(not poor.ok and poor.reason == "INSUFFICIENT_FUNDS", tostring(poor.reason))
		assert(w.balance("3") == 10 and w.held("3", "wood") == 0 and w.balance("1") == 95, "nothing moved")
		assert(market.snapshot("2").catalogs[1].listings[1].id == "mk:1:1", "listing still active")
		assert(market.close().ok, "close")
	end,
	["ineligible accounts, items and prices are refused with state intact"] = function()
		local w = world({
			["1"] = envelope(100, {
				stack("w1", "wood", 10),
				stack("f1", "fiber", 5, { robuxPurchased = true }),
			}),
			["2"] = envelope(0, {}),
		})
		local market = w.open("srv-a")
		w.eligible["2"] = false
		assert(w.command("2", "list", { "wood", 1, 10 }, "x1").reason == "INELIGIBLE_TUTORIAL", "tutorial gate")
		assert(w.command("1", "list", { "stone-axe", 1, 10 }, "x2").reason == "UNKNOWN_CATALOG", "whitelist")
		assert(w.command("1", "list", { "fiber", 1, 10 }, "x3").reason == "UNTRADEABLE_PAID", "Robux item")
		assert(w.command("1", "list", { "wood", 11, 10 }, "x4").reason == "NOT_OWNED", "not owned")
		assert(w.command("1", "list", { "wood", 0, 10 }, "x5").reason == "INVALID_LISTING", "invalid input")
		for index = 1, 3 do
			assert(w.command("1", "list", { "wood", 1, 10 }, "seed" .. index).ok, "seed listing")
		end
		assert(w.command("1", "list", { "wood", 1, 100 }, "x6").reason == "PRICE_OUTLIER", "outlier")
		assert(w.command("1", "buy", { "mk:1:1" }, "x7").reason == "SELF_TRADE", "self trade")
		assert(w.held("1", "wood") == 7 and w.held("1", "fiber") == 5, "only the 3 real listings moved")
		assert(w.balance("1") == 97, "only their 1-coin minimum fees")
		assert(market.snapshot("1").holdings.fiber == nil, "paid stack never offered for sale")
		assert(market.close().ok, "close")
	end,
	["a full bag refuses a cancel and keeps the listing in escrow"] = function()
		local w = world({
			["1"] = envelope(100, { stack("w1", "wood", 2) }),
		})
		local market = w.open("srv-a")
		assert(w.command("1", "list", { "wood", 2, 10 }, "l1").ok, "whole stack listed")
		-- Fill all four slots so the returned stack has nowhere to go.
		local fill = {}
		for index = 1, 4 do
			fill["f" .. index] = stack("f" .. index, "fiber", 1)
		end
		local port = assert(w.tokens["1"], "seller token")
		local personal = PersonalAggregate.new(w.backend, {
			namespace = "personal",
			inventoryPath = PATH,
			validateEnvelope = function(value)
				return type(value) == "table"
			end,
			store = {
				sessionId = "players",
				leaseSeconds = 120,
				now = function()
					return w.clock.now
				end,
				budget = budget,
			},
		})
		w.tokens["1"] = assert(personal:update(port, function(view)
			view.envelope.genres["survival-coop"].data.inventory.bag.items = fill
			return view
		end))
		local refused = w.command("1", "cancel", { "mk:1:1" }, "c1")
		assert(not refused.ok and refused.reason == "BAG_FULL", tostring(refused.reason))
		assert(market.snapshot("1").listed["mk:1:1"].status == "active", "still listed, units safe")
		assert(market.close().ok, "close")
	end,
	["the snapshot publishes the same eligibility gate the commands apply"] = function()
		local w = standard()
		local market = w.open("srv-a")
		local open = market.snapshot("1")
		assert(open.eligible == true and open.ineligibleReason == nil, "eligible seller")
		w.eligible["3"] = false
		local closed = market.snapshot("3")
		assert(closed.eligible == false and closed.ineligibleReason == "INELIGIBLE_TUTORIAL", "gate published")
		local refused = w.command("3", "list", { "wood", 1, 10 }, "g1")
		assert(refused.reason == closed.ineligibleReason, "snapshot reason equals the command refusal")
		-- Reading the gate never spends a throttle token or a daily-cap slot.
		for _ = 1, 20 do
			market.snapshot("1")
		end
		assert(w.command("1", "list", { "wood", 1, 10 }, "g2").ok, "snapshots did not consume the gate")
		assert(market.close().ok, "close")
	end,
}
