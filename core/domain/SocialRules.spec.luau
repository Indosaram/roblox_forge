--!strict
-- Domain rules added for the social/home/trade screens: home move, per-category home grants,
-- outpost leave + previous ownership, and same-server direct trade escrow.
local Home = require("./home/HomeState")
local HomeMove = require("./home/HomeMove")
local Outpost = require("./settlement/ClanOutpost")
local Trade = require("./market/DirectTrade")
local Inventory = require("./inventory/Inventory")
local Catalog = require("./inventory/ItemCatalog")

local rules = {
	baseSlots = 20,
	storageGrants = {},
	landSizes = { 64 },
	floors = { 2 },
	dock = { x = 0, y = 2, z = 28 },
	moveDestinations = { "cove-north", "cove-east", "cove-south" },
}
local catalog = Catalog.new({ { id = "plank", stackMax = 50, weightMilli = 0 } })

local function bag(items: { any }): any
	local state = Inventory.new("bag", { slots = 10, softWeightMilli = 90000, hardWeightMilli = 90000 })
	for _, item in items do
		state = assert(Inventory.add(state, catalog, item, state.version))
	end
	return Inventory.save(state)
end

return {
	["home move keeps grants and history, refuses non-owner same spot and pending transfers"] = function()
		local home = Home.new("owner", rules, 1)
		home.permissions =
			{ visit = "friend", cooperate = "friend", friends = { pal = true }, clanId = "", offlineCoop = true }
		local ctx = { rules = rules, now = 50, pendingTransfers = 0 }
		local refused, reason = HomeMove.apply(home, "pal", "home:owner", { destination = "cove-east" }, ctx)
		assert(refused == nil and reason == "FORBIDDEN", "only the owner moves")
		local _, same = HomeMove.apply(home, "owner", "home:owner", { destination = "cove-north" }, ctx)
		assert(same == "SAME_DESTINATION", "default spot is the first destination")
		local _, unknown = HomeMove.apply(home, "owner", "home:owner", { destination = "moon" }, ctx)
		assert(unknown == "UNKNOWN_DESTINATION", "unknown destination refused")
		local _, locked = HomeMove.apply(
			home,
			"owner",
			"home:owner",
			{ destination = "cove-east" },
			{ rules = rules, now = 50, pendingTransfers = 1 }
		)
		assert(locked == "TRANSFER_LOCKED", "unsettled storage transfer locks the move")
		local moved = assert(HomeMove.apply(home, "owner", "home:owner", { destination = "cove-east" }, ctx))
		assert(moved.location == "cove-east" and moved.revision == home.revision + 1, "moved")
		assert(moved.permissions.friends.pal and moved.permissions.offlineCoop, "grants preserved")
		assert(#moved.moveHistory == 1 and moved.moveHistory[1].from == "cove-north", "history recorded")
		assert(home.location == nil, "copy on write")
	end,
	["home grants separate use build and recover and require a clan for clan access"] = function()
		local home = Home.new("owner", rules, 1)
		local base = {
			rules = rules,
			catalog = catalog,
			structures = {},
			facts = { friend = true, ownerOnline = true },
		}
		local acl = {
			visit = "friend",
			cooperate = "friend",
			grants = { use = "friend", build = "owner", recover = "owner" },
			friends = {},
			anyFriend = true,
			clanId = "",
			offlineCoop = false,
		}
		local granted = assert(Home.apply(home, "owner", "home:owner", "permissions", { permissions = acl }, base))
		assert(Home.allowed(granted, "pal", "visit", base.facts), "any friend may visit")
		assert(Home.allowed(granted, "pal", "plant", base.facts), "use grant covers planting")
		assert(not Home.allowed(granted, "pal", "place", base.facts), "build stays owner-only")
		assert(not Home.allowed(granted, "pal", "recover", base.facts), "recover stays owner-only")
		local _, forbidden = Home.apply(granted, "pal", "home:owner", "place", { kind = "x" }, base)
		assert(forbidden == "FORBIDDEN", "build refusal from the grant")
		local clan = table.clone(acl)
		clan.grants = { use = "clan", build = "owner", recover = "owner" }
		local _, reason = Home.apply(home, "owner", "home:owner", "permissions", { permissions = clan }, base)
		assert(reason == "CLAN_REQUIRED", "clan grant without a clan is refused")
		local legacy = Home.new("owner", rules, 1)
		legacy.permissions =
			{ visit = "friend", cooperate = "friend", friends = { pal = true }, clanId = "", offlineCoop = false }
		assert(Home.allowed(legacy, "pal", "place", base.facts), "homes without grants keep cooperate")
	end,
	["outpost leave is explicit for participants and settlement records previous ownership"] = function()
		local policy = { minTeam = 3, maxTeam = 8, matchSeconds = 600, captureSeconds = 180, ownershipSeconds = 86400 }
		local teams =
			{ { clanId = "alpha", actors = { "a", "b", "c" } }, { clanId = "beta", actors = { "d", "e", "f" } } }
		local ctx: any = {
			server = true,
			role = "team-outpost",
			rules = policy,
			teams = teams,
			occupants = {},
			eligible = function(): boolean
				return true
			end,
			optedIn = function(): boolean
				return true
			end,
		}
		local state = Outpost.new("o", "")
		state.owner, state.expiresAt = "gamma", 1000
		local started = assert(Outpost.apply(state, "srv", "start", { matchId = "m" }, "s", 10, ctx))
		assert(started.matches.m.previousOwner == "gamma" and started.matches.m.previousExpiresAt == 1000, "previous")
		local client = table.clone(ctx)
		client.server = false
		local refused, reason = Outpost.apply(started, "z", "leave", { matchId = "m" }, "l0", 20, client)
		assert(refused == nil and reason == "NOT_IN_MATCH", "outsider cannot leave")
		local left = assert(Outpost.apply(started, "a", "leave", { matchId = "m" }, "l1", 20, client))
		assert(left.matches.m.actors.a == nil and left.matches.m.left.a == 20, "leaver removed")
		ctx.occupants = { "a", "b" }
		local ticked = assert(Outpost.apply(left, "srv", "advance", { matchId = "m" }, "t", 100, ctx))
		assert(ticked.matches.m.score[1] == 90, "remaining member still controls; leaver does not count")
	end,
	["direct trade escrow clears confirmations on change and settles exact stacks once"] = function()
		local stack = {
			itemId = "p1",
			catalogId = "plank",
			quantity = 5,
			qualityMilli = 3000,
			durabilityMilli = 0,
			attributes = { level = 7 },
		}
		local a = { balance = 100, inventory = { bag = bag({ stack }) } }
		local b = { balance = 40, inventory = { bag = bag({}) } }
		local _, self = Trade.open("t", "a", "a", { sameServer = true })
		assert(self == "SELF_TRADE", "no self trade")
		local _, away = Trade.open("t", "a", "b", { sameServer = false })
		assert(away == "DIFFERENT_SERVER", "same server only")
		local trade = assert(Trade.open("t", "a", "b", { sameServer = true }))
		local _, empty = Trade.confirm(trade, "a", 0)
		assert(empty == "EMPTY_TRADE", "empty trade cannot be confirmed")
		local _, poor = Trade.offer(trade, "b", 0, { coins = 50 }, { balance = 40, bag = b.inventory.bag })
		assert(poor == "INSUFFICIENT_FUNDS", "cannot offer more than balance")
		trade = assert(
			Trade.offer(
				trade,
				"a",
				0,
				{ itemId = "p1", quantity = 3, coins = 0 },
				{ balance = 100, bag = a.inventory.bag }
			)
		)
		trade = assert(Trade.confirm(trade, "a", 1))
		local _, stale = Trade.confirm(trade, "b", 0)
		assert(stale == "STALE_REVISION", "confirmation is bound to the revision")
		trade = assert(Trade.offer(trade, "b", 1, { coins = 30 }, { balance = 40, bag = b.inventory.bag }))
		assert(next(trade.confirmed) == nil and trade.revision == 2, "change clears both confirmations")
		trade = assert(Trade.confirm(trade, "a", 2))
		trade = assert(Trade.confirm(trade, "b", 2))
		assert(trade.status == "locked", "both confirmations lock")
		local a1 = assert(Trade.debit(trade, "a", a, catalog))
		local b1 = assert(Trade.debit(trade, "b", b, catalog))
		local b2 = assert(Trade.credit(trade, "b", "a", b1, catalog))
		local a2 = assert(Trade.credit(trade, "a", "b", a1, catalog))
		assert(a2.balance == 130 and b2.balance == 10, "currency moved")
		local received = b2.inventory.bag.items["trade:t:a"]
		assert(
			received.quantity == 3 and received.qualityMilli == 3000 and received.attributes.level == 7,
			"exact stack"
		)
		assert(a2.inventory.bag.items.p1.quantity == 2, "remainder stays")
		local _, cancelLocked = Trade.cancel({ status = "settled", offers = trade.offers }, "a")
		assert(cancelLocked == "TRADE_SETTLED", "settled trade cannot be cancelled")
	end,
}
