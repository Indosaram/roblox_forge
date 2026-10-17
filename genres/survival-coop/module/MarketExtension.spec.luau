--!strict
local serde = require("@lune/serde")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Fenced = require("../../../core/infra/data/FencedStore")
local Wallet = require("../../../core/domain/economy/Wallet")
local Market = require("./MarketExtension")

local DAY = 86400
local NOW = 30 * DAY

local function build(backend: any?)
	local wallets: { [string]: Wallet.Wallet } = {}
	local moves: { any } = {}
	local function wallet(actor: string): Wallet.Wallet
		wallets[actor] = wallets[actor] or Wallet.new({ coins = 1000 })
		return wallets[actor]
	end
	Market.configure({
		catalogIds = { "wood", "stone" },
		account = function(actor, _now)
			return {
				id = actor,
				createdAt = 0,
				playSeconds = 10 * 3600,
				tutorialComplete = actor ~= "9",
			}
		end,
		wallet = wallet,
		item = function(actor, catalogId)
			return { itemId = "stack-" .. actor .. "-" .. catalogId, catalogId = catalogId, quantity = 10 }
		end,
		transfer = function(request)
			table.insert(moves, request)
			return true, nil
		end,
		market = { throttle = { capacity = 100, refillPerSecond = 1 } },
	})
	local store = backend or Memory.new()
	local extension = assert(Market.factory({
		store = function()
			return Fenced.new(store, {
				sessionId = "mkt",
				leaseSeconds = 120,
				now = function()
					return 0
				end,
				budget = {
					encode = function(value)
						return serde.encode("json", value)
					end,
				},
			})
		end,
		now = function()
			return NOW
		end,
	}))
	return extension, wallet, moves
end
local function command(extension: any, actor: string, action: string, args: { any }): any
	return extension.command(
		actor,
		action,
		args,
		{ actorId = actor, requestId = "r", sessionEpoch = 0 },
		"client",
		function()
			return { ok = true }
		end
	)
end

return {
	["factory stays disabled without configuration"] = function()
		Market.configure(nil)
		assert(Market.factory({
			store = function()
				error("unused")
			end,
			now = function()
				return 0
			end,
		}) == nil, "disabled")
	end,
	["list then buy settles escrow, fee and price"] = function()
		local extension, wallet, moves = build()
		local listed = command(extension, "7", "survival-coop:market-list", { "wood", 4, 25 })
		assert(listed.ok, tostring(listed.reason))
		-- fee = max(minFee 1, 4 * 25 * 500bp) = 5
		assert(listed.data.fee == 5, "fee is " .. tostring(listed.data.fee))
		assert(wallet("7"):balance("coins") == 995, "fee debited from the seller")
		assert(#moves == 1 and moves[1].destination == "market:escrow", "units moved into escrow")
		local view = extension.snapshot("8")
		assert(
			#view.catalogs[1].listings == 1 and view.catalogs[1].listings[1].unitPrice == 25,
			"lowest listing visible"
		)
		local bought = command(extension, "8", "survival-coop:market-buy", { listed.data.listingId })
		assert(bought.ok and bought.data.price == 100, tostring(bought.reason))
		assert(wallet("8"):balance("coins") == 900, "price debited from the buyer")
		assert(wallet("7"):balance("coins") == 1095, "price credited to the seller")
		assert(#moves == 2 and moves[2].source == "market:escrow" and moves[2].destination == "8", "units delivered")
		assert(#extension.snapshot("8").catalogs[1].listings == 0, "sold listing leaves the book")
		assert(extension.snapshot("8").bought[listed.data.listingId].price == 100, "buyer ledger")
		assert(extension.snapshot("7").listed[listed.data.listingId].status == "sold", "seller ledger")
		assert(
			command(extension, "8", "survival-coop:market-buy", { listed.data.listingId }).reason
				== "LISTING_UNAVAILABLE",
			"resold listing refused"
		)
		assert(extension.close().ok, "close")
	end,
	["ineligible account is rejected before anything moves"] = function()
		local extension, wallet, moves = build()
		local result = command(extension, "9", "survival-coop:market-list", { "wood", 1, 10 })
		assert(not result.ok and result.reason == "INELIGIBLE_TUTORIAL", tostring(result.reason))
		assert(#moves == 0 and wallet("9"):balance("coins") == 1000, "no state change")
		assert(extension.close().ok, "close")
	end,
	["outlier price is rejected and invalid input refused"] = function()
		local extension, _wallet, moves = build()
		for _ = 1, 3 do
			assert(command(extension, "7", "survival-coop:market-list", { "wood", 1, 10 }).ok, "seed listing")
		end
		local high = command(extension, "7", "survival-coop:market-list", { "wood", 1, 100 })
		assert(not high.ok and high.reason == "PRICE_OUTLIER", tostring(high.reason))
		local low = command(extension, "7", "survival-coop:market-list", { "wood", 1, 1 })
		assert(not low.ok and low.reason == "PRICE_OUTLIER", tostring(low.reason))
		assert(#moves == 3, "rejected listings never reach escrow")
		assert(
			command(extension, "7", "survival-coop:market-list", { "wood", 0, 10 }).reason == "INVALID_LISTING",
			"INVALID_LISTING"
		)
		assert(
			command(extension, "7", "survival-coop:market-list", { "gold", 1, 10 }).reason == "UNKNOWN_CATALOG",
			"UNKNOWN_CATALOG"
		)
		assert(
			command(extension, "7", "survival-coop:market-list", { "wood", 11, 10 }).reason == "NOT_OWNED",
			"NOT_OWNED"
		)
		assert(command(extension, "7", "survival-coop:market-buy", { "mk:7:1" }).reason == "SELF_TRADE", "SELF_TRADE")
		assert(extension.close().ok, "close")
	end,
	["listing ledger survives a reload"] = function()
		local backend = Memory.new()
		local first = build(backend)
		local listed = command(first, "7", "survival-coop:market-list", { "stone", 2, 7 })
		assert(listed.ok, tostring(listed.reason))
		assert(first.close().ok, "close")
		local second = build(backend)
		local view = second.snapshot("7")
		assert(view.seq == 1 and view.listed[listed.data.listingId].unitPrice == 7, "ledger reloaded")
		assert(second.close().ok, "close")
	end,
}
