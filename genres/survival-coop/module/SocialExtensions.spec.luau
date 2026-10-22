--!strict
-- Server commands for the social/home/trade screens: home-move and home-permissions through
-- the real HomeExtension store, and the DirectTradeExtension escrow settlement through fake
-- personal records with receipt markers.
local HomeExtension = require("./HomeExtension")
local TradeExtension = require("./DirectTradeExtension")
local HomeContent = require("../../../core/domain/home/HomeContent")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Fenced = require("../../../core/infra/data/FencedStore")
local Memory = require("../../../core/infra/data/MemoryBackend")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()

local function admit(): any
	return { ok = true }
end

local catalog = Catalog.new({ { id = "plank", stackMax = 50, weightMilli = 0 } })

local function personal(balance: number, items: { any }): (any, () -> any, (boolean) -> ())
	local bag = Inventory.new("bag", { slots = 10, softWeightMilli = 90000, hardWeightMilli = 90000 })
	for _, item in items do
		bag = assert(Inventory.add(bag, catalog, item, bag.version))
	end
	local record: any = {
		data = {
			envelope = {
				genres = {
					["survival-coop"] = { data = { balance = balance, inventory = { bag = Inventory.save(bag) } } },
				},
			},
			itemTransfers = { version = 1, receipts = {} },
		},
	}
	local fail = false
	local port = {
		personal = {
			update = function(_self: any, token: any, transform: any): (any?, string?)
				if fail then
					return nil, "STORE_UNAVAILABLE"
				end
				local view = transform({ envelope = token.data.envelope, itemTransfers = token.data.itemTransfers })
				return { data = { envelope = view.envelope, itemTransfers = view.itemTransfers } }, nil
			end,
		},
		profile = function(): any
			return record
		end,
		install = function(updated: any)
			record = updated
		end,
	}
	return port,
		function(): any
			return record.data.envelope.genres["survival-coop"].data
		end,
		function(value: boolean)
			fail = value
		end
end

return {
	["home-move and home-permissions commands persist through the home store with receipts"] = function()
		local rules = HomeContent.rules(Content)
		local extension = HomeExtension.new({
			content = Content,
			rules = rules,
			structures = {},
			seed = function()
				return 1
			end,
			now = function()
				return 5
			end,
			store = function()
				return Fenced.new(Memory.new(), {
					sessionId = "s",
					now = function()
						return 5
					end,
					leaseSeconds = 30,
				})
			end,
			ownerOf = function(actor, token)
				return if token == "home:" .. actor then actor else nil
			end,
			facts = function()
				return { reachable = true, friend = true }
			end,
		})
		local function send(action: string, body: any, id: string): any
			return extension.command(
				"owner",
				"survival-coop:" .. action,
				{ "home:owner", body },
				{ actorId = "owner", requestId = id, sessionEpoch = 1 },
				"client",
				admit
			)
		end
		assert(extension.handles("survival-coop:home-move"), "home-move routed")
		assert(send("home-move", { destination = "cove-north" }, "m0").reason == "SAME_DESTINATION", "refusal")
		local acl = {
			visit = "friend",
			cooperate = "owner",
			grants = { use = "owner", build = "friend", recover = "owner" },
			clanId = "",
			offlineCoop = true,
			anyFriend = true,
		}
		assert(send("home-permissions", { permissions = acl }, "p1").ok, "permissions saved")
		assert(send("home-move", { destination = "cove-south" }, "m1").ok, "moved")
		assert(send("home-move", { destination = "cove-south" }, "m1").ok, "replayed receipt")
		local home = assert(extension.snapshot("owner"))
		assert(home.location == "cove-south" and #home.moveHistory == 1, "move persisted once")
		assert(home.permissions.grants.build == "friend" and home.permissions.offlineCoop, "grants kept through move")
	end,
	["direct trade settles both records once and refuses outside the server"] = function()
		local portA, dataA = personal(100, {
			{
				itemId = "p1",
				catalogId = "plank",
				quantity = 5,
				qualityMilli = 3000,
				durabilityMilli = 0,
				attributes = { level = 7 },
			},
		})
		local portB, dataB, failB = personal(40, {})
		local members = { "a", "b" }
		local extension = TradeExtension.new({
			catalog = catalog,
			personal = function(actor: string): any
				return if actor == "a" then portA else portB
			end,
			members = function(): { string }
				return members
			end,
			now = function(): number
				return 1
			end,
		})
		local n = 0
		local function send(actor: string, op: string, args: any): any
			n += 1
			return extension.command(
				actor,
				"survival-coop:trade-" .. op,
				args,
				{ actorId = actor, requestId = "r" .. n, sessionEpoch = 1 },
				"client",
				admit
			)
		end
		assert(send("a", "open", { "zed" }).reason == "DIFFERENT_SERVER", "other server refused")
		local opened = send("a", "open", { "b" })
		local id = opened.data.tradeId
		assert(extension.snapshot("b").trade.tradeId == id, "invitation visible to counterpart")
		assert(send("a", "offer", { id, { revision = 0, itemId = "p1", quantity = 3, coins = 0 } }).ok, "offer a")
		assert(send("b", "offer", { id, { revision = 1, coins = 30 } }).ok, "offer b")
		assert(send("a", "confirm", { id, 2 }).ok, "a confirms")
		failB(true)
		local stuck = send("b", "confirm", { id, 2 })
		assert(not stuck.ok and dataA().balance == 100, "failed second debit refunds before any credit")
		local bagA = dataA().inventory.bag.items
		assert(bagA.p1.quantity == 2 and bagA["trade:" .. id .. ":a"].quantity == 3, "escrowed stack refunded")
		assert(bagA["trade:" .. id .. ":a"].attributes.level == 7, "refund keeps attributes")
		failB(false)
		-- Fresh trade completes.
		local again = send("a", "open", { "b" }).data.tradeId
		assert(send("b", "offer", { again, { revision = 0, coins = 30 } }).ok, "b offers")
		assert(send("a", "confirm", { again, 1 }).ok, "a confirms")
		n += 1
		local request = { actorId = "b", requestId = "final", sessionEpoch = 1 }
		local done = extension.command("b", "survival-coop:trade-confirm", { again, 1 }, request, "client", admit)
		assert(done.ok and done.data.status == "delivered", "settled")
		local replay = extension.command("b", "survival-coop:trade-confirm", { again, 1 }, request, "client", admit)
		assert(replay.ok and dataB().balance == 10 and dataA().balance == 130, "replay does not settle twice")
		assert(extension.snapshot("a").last.status == "settled", "result reflected")
	end,
}
