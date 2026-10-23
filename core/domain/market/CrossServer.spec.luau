--!strict
local Market = require("./CrossServer")
local function clone(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local r = {}
	for k, x in v do
		r[k] = clone(x)
	end
	return r
end
local function fixture(): any
	local f: any = {
		records = {
			["player:seller"] = {
				coins = 100,
				items = { twig = { catalogId = "branch", quantity = 10, attributes = { level = 3 } } },
			},
			["player:buyer"] = { coins = 100, items = {} },
			["player:other"] = { coins = 100, items = {} },
		},
		writes = 0,
		failAt = 0,
		after = false,
		index = {},
	}
	f.ports = {
		update = function(key, transform)
			f.writes += 1
			if f.writes == f.failAt and not f.after then
				return false, nil
			end
			local value = transform(clone(f.records[key]))
			f.records[key] = clone(value)
			if f.writes == f.failAt then
				return false, nil
			end
			return true, clone(value)
		end,
		index = function(key, value)
			f.index[key] = value
		end,
		search = function(key)
			return { clone(f.index[key]) }
		end,
	}
	f.serverA = Market.new(f.ports)
	f.serverB = Market.new(f.ports)
	return f
end
local function conserved(f: any)
	local seller = f.records["player:seller"]
	local buyer = f.records["player:buyer"]
	local total, coins = 0, seller.coins + buyer.coins
	for _, p in { seller, buyer } do
		for _, item in p.items do
			total += item.quantity
		end
		for _, item in p.market.escrow do
			total += item.quantity
		end
		for _, claim in p.market.claims do
			if claim.item then
				total += claim.item.quantity
				assert(claim.item.attributes.level == 3, "trade invariant")
			end
			coins += claim.coins or 0
		end
	end
	assert(total == 10, "item conservation")
	assert(coins + f.records["listing:seller:one"].fee == 200, "currency plus fee conservation")
end
return {
	["buyer delivery survives a seller held by another server and settles after release"] = function()
		local f = fixture()
		assert(f.serverA.list("seller", "one", "twig", 4, 21, 0).ok, "listed")
		local update = f.ports.update
		f.ports.update = function(key, transform)
			if key == "player:seller" then
				return false, nil
			end
			return update(key, transform)
		end
		local result = f.serverB.buy("buyer", "buy", "seller:one", 21, 1)
		assert(not result.ok and f.records["listing:seller:one"].state == "DELIVERED", "seller settlement pending")
		assert(f.records["player:buyer"].market.claims["buyer:buy:0"].item.quantity == 4, "buyer already delivered")
		f.ports.update = update
		assert(Market.new(f.ports).recover("seller:one", 2).ok, "offline worker finishes")
		conserved(f)
	end,
	["return claims survive before and after each cancellation CAS"] = function()
		for after = 0, 1 do
			for barrier = 1, 5 do
				local f = fixture()
				assert(f.serverA.list("seller", "one", "twig", 4, 21, 0).ok, "listing prepared")
				f.failAt = f.writes + barrier
				f.after = after == 1
				f.serverA.cancel("seller", "seller:one", 1)
				f.failAt = 0
				local restart = Market.new(f.ports)
				assert(restart.cancel("seller", "seller:one", 2).ok, "return resumes")
				assert(restart.recover("seller:one", 3).ok, "return replay")
				local seller = f.records["player:seller"]
				assert(
					seller.market.claims["seller:one:return:0"].item.quantity + seller.items.twig.quantity == 10,
					"return conservation"
				)
			end
		end
	end,
	["offline seller cross server bundle sale conserves items and floor fee"] = function()
		local f = fixture()
		assert(f.serverA.list("seller", "one", "twig", 4, 21, 0).ok, "trade invariant")
		assert(f.serverB.search("branch")[1].id == "seller:one", "trade invariant")
		assert(f.serverB.buy("buyer", "buy", "seller:one", 21, 1).ok, "trade invariant")
		assert(f.serverB.buy("buyer", "buy", "seller:one", 21, 2).ok, "trade invariant")
		assert(not f.serverA.cancel("seller", "seller:one", 2).ok, "trade invariant")
		assert(not f.serverA.buy("other", "buy", "seller:one", 21, 2).ok, "trade invariant")
		assert(f.records["player:buyer"].coins == 79, "trade invariant")
		assert(f.records["player:seller"].market.claims["buyer:buy:1"].coins == 20, "trade invariant")
		conserved(f)
	end,
	["every before and after participant CAS crash recovers exactly once"] = function()
		for after = 0, 1 do
			for barrier = 1, 25 do
				local f = fixture()
				f.failAt = barrier
				f.after = after == 1
				f.serverA.list("seller", "one", "twig", 4, 21, 0)
				f.serverB.buy("buyer", "buy", "seller:one", 21, 1)
				f.failAt = 0
				local restart = Market.new(f.ports)
				assert(restart.list("seller", "one", "twig", 4, 21, 0).ok, "trade invariant")
				assert(restart.buy("buyer", "buy", "seller:one", 21, 1).ok, "trade invariant")
				assert(restart.recover("seller:one", 2).ok, "trade invariant")
				conserved(f)
			end
		end
	end,
	["stale search changed price self purchase and payload conflicts refuse"] = function()
		local f = fixture()
		assert(f.serverA.list("seller", "one", "twig", 4, 21, 0).ok, "trade invariant")
		assert(not f.serverA.list("seller", "one", "twig", 5, 21, 0).ok, "trade invariant")
		assert(not f.serverB.buy("buyer", "buy", "seller:one", 22, 1).ok, "trade invariant")
		assert(not f.serverB.buy("seller", "own", "seller:one", 21, 1).ok, "trade invariant")
		assert(not f.serverB.buy("buyer", "buy", "seller:one", 21, 1).ok, "trade invariant")
		assert(f.serverA.cancel("seller", "seller:one", 1).ok, "trade invariant")
		assert(not f.serverB.buy("buyer", "new", "seller:one", 21, 1).ok, "trade invariant")
	end,
	["cancellation and expiry return claims without requiring bag space"] = function()
		for _, expire in { false, true } do
			local f = fixture()
			assert(f.serverA.list("seller", "one", "twig", 4, 1, 0).ok, "trade invariant")
			local result = if expire
				then f.serverB.recover("seller:one", 86400)
				else f.serverA.cancel("seller", "seller:one", 1)
			assert(result.ok and result.data.state == "RETURNED", "trade invariant")
			assert(f.serverB.recover("seller:one", 86401).ok, "trade invariant")
			local seller = f.records["player:seller"]
			assert(seller.market.claims["seller:one:return:0"].item.quantity == 4, "trade invariant")
			assert(seller.items.twig.quantity == 6 and seller.coins == 100, "trade invariant")
		end
	end,
	["insufficient balance paid goods invalid quantities and listing cap refuse"] = function()
		local f = fixture()
		assert(not f.serverA.list("seller", "bad", "twig", 0, 1, 0).ok, "trade invariant")
		assert(not f.serverA.list("seller", "bad", "twig", 1, 1000001, 0).ok, "trade invariant")
		f.records["player:seller"].items.twig.robuxPurchased = true
		assert(not f.serverA.list("seller", "paid", "twig", 1, 1, 0).ok, "trade invariant")
		f.records["player:seller"].items.twig.robuxPurchased = nil
		assert(f.serverA.list("seller", "one", "twig", 4, 101, 0).ok, "trade invariant")
		assert(not f.serverB.buy("buyer", "poor", "seller:one", 101, 1).ok, "trade invariant")
		assert(f.records["player:buyer"].coins == 100, "trade invariant")
		assert(f.records["listing:seller:one"].state == "ACTIVE", "trade invariant")
		local seller = f.records["player:seller"]
		for i = 1, 20 do
			seller.market.active[tostring(i)] = true
		end
		assert(not f.serverA.list("seller", "limit", "twig", 1, 1, 0).ok, "trade invariant")
	end,
	["p45 a list of goods the seller does not hold or cannot escrow names its refusal"] = function()
		local f = fixture()
		local missing = f.serverA.list("seller", "gone", "no-such-stack", 1, 10, 0)
		assert(not missing.ok and missing.reason == "item_unavailable", "missing stack: " .. tostring(missing.reason))
		assert(f.records["listing:seller:gone"] == nil, "no listing record for a missing stack")
		local seller = f.records["player:seller"]
		seller.market = { markers = {}, escrow = {}, active = {}, claims = {} }
		for i = 1, 20 do
			seller.market.active[tostring(i)] = true
		end
		local capped = f.serverA.list("seller", "capped", "twig", 1, 10, 0)
		assert(not capped.ok and capped.reason == "listing_declined", "declined escrow: " .. tostring(capped.reason))
		assert(seller.items.twig.quantity == 10, "nothing moved")
	end,
}
