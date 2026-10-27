--!strict
-- Durable plot claim/build over real FencedStores and a bag held in memory (C5a negatives included).
local Memory = require("../../../../core/infra/data/MemoryBackend")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Job = require("../../../../core/domain/crafting/Job")
local Content: any = require("./SurvivalContent")
local TownPlots = require("./TownPlots")
local TownRuntime = require("./TownRuntime")

local function harness(backend: any?, sessionId: string?): any
	local clock = 1000
	local catalog = Job.catalog(Content)
	local definitions = {}
	for _, definition in Content.structures do
		definitions[definition.id] = {
			id = definition.id,
			footprintX = definition.footprintX,
			footprintZ = definition.footprintZ,
			cost = definition.cost,
			station = definition.station,
		}
	end
	local shared = backend or Memory.new()
	local bags: { [string]: any } = {}
	local ranks: { [string]: number } = { ["1"] = 1, ["2"] = 2, ["3"] = 0 }
	local h: any = { backend = shared, bags = bags, ranks = ranks, catalog = catalog }
	h.runtime = TownRuntime.new({
		layout = TownPlots.layout(4310),
		townId = "town-01",
		definitions = definitions,
		catalog = catalog,
		store = Fenced.new(shared, {
			sessionId = sessionId or "town-spec",
			leaseSeconds = 60,
			now = function()
				return clock
			end,
		}),
		now = function()
			return clock
		end,
		rank = function(actor)
			return ranks[actor] or 0
		end,
		bag = function(actor, transform)
			local bag = bags[actor]
			local nextBag, reason = transform(bag)
			if reason then
				return false, reason
			end
			if nextBag then
				bags[actor] = nextBag
			end
			return true, nil
		end,
	})
	function h.give(actor: string, item: string, quantity: number)
		local bag = bags[actor]
			or Inventory.new("bag-" .. actor, { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		bags[actor] = assert(Inventory.add(bag, catalog, {
			itemId = item .. "-" .. actor,
			catalogId = item,
			quantity = quantity,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = {},
		}, bag.version))
	end
	function h.count(actor: string, item: string): number
		local total = 0
		for _, row in (bags[actor] or { items = {} }).items do
			if row.catalogId == item then
				total += row.quantity
			end
		end
		return total
	end
	return h
end

local function at(plot: any, cx: number, cz: number): string
	return string.format("%s:floor:%d:%d:0", plot.id, plot.min.x + cx * 4, plot.min.z + cz * 4)
end

return {
	["claim persists one plot per account and refuses an owned plot"] = function()
		local h = harness()
		local runtime = h.runtime
		assert(#runtime.start() == 0, "every plot loads")
		assert(runtime.view().free == 28 and runtime.view().total == 28, "28 free plots")
		local claimed = runtime.command("1", "town-claim", "W01")
		assert(claimed.ok, tostring(claimed.reason))
		assert(runtime.command("2", "town-claim", "W01").reason == "PLOT_OWNED", "owned plot refused")
		assert(runtime.command("1", "town-claim", "W02").reason == "ALREADY_CLAIMED", "one plot per account")
		assert(runtime.command("3", "town-claim", "W02").reason == "RANK_REQUIRED", "tutorial rank gate")
		assert(runtime.command("2", "town-claim", "Q01").reason == "UNKNOWN_PLOT", "unknown plot")
		assert(runtime.view().free == 27, "one plot taken")
		-- A fresh server over the same store sees the claim.
		local again = harness(h.backend, "town-spec-2").runtime
		again.start()
		assert(again.doc("W01") and again.doc("W01").ownerId == "1", "claim survives a restart")
		assert(again.command("1", "town-claim", "E01").reason == "ALREADY_CLAIMED", "account record is durable")
	end,
	["build pays from the bag, and outsiders or out-of-plot builds are refused without charge"] = function()
		local h = harness()
		local runtime, layout = h.runtime, TownPlots.layout(4310)
		runtime.start()
		assert(runtime.command("1", "town-claim", "E05").ok, "claim")
		assert(runtime.command("2", "town-claim", "E06").ok, "neighbour claim")
		h.give("1", "wood", 10)
		h.give("2", "wood", 10)
		local e05, e06 = layout.byId.E05, layout.byId.E06
		local built = runtime.command("1", "town-build", at(e05, 2, 2))
		assert(built.ok, tostring(built.reason))
		assert(h.count("1", "wood") == 6, "floor cost 4 wood paid")
		assert(next(h.bags["1"].reservations) == nil, "bag lock consumed")
		local refused = runtime.command("2", "town-build", at(e05, 6, 6))
		assert(
			tostring(refused.reason) == "NOT_PLOT_MEMBER",
			"building on another's plot refused: " .. tostring(refused.reason)
		)
		refused = runtime.command("1", "town-build", string.format("E05:floor:%d:%d:0", e06.min.x + 8, e06.min.z + 8))
		assert(tostring(refused.reason) == "OUT_OF_PLOT", "building outside your plot refused")
		refused = runtime.command("1", "town-build", "W01:floor:0:0:0")
		assert(tostring(refused.reason) == "PLOT_UNCLAIMED" or refused.reason == "OUT_OF_PLOT", "unclaimed plot")
		refused =
			runtime.command("1", "town-build", string.format("E05:clan-hall:%d:%d:0", e05.min.x + 16, e05.min.z + 16))
		assert(tostring(refused.reason) == "STRUCTURE_NOT_ALLOWED", "clan hall refused on a plot")
		assert(h.count("1", "wood") == 6 and h.count("2", "wood") == 10, "refusals never charge")
		h.bags["1"] = assert(Inventory.consume(h.bags["1"], "wood-1", 6, h.bags["1"].version))
		refused = runtime.command("1", "town-build", at(e05, 6, 6))
		assert(tostring(refused.reason) == "MISSING_KIT", "no materials")
		local doc = runtime.doc("E05") :: any
		assert(next(doc.settlement.reservations) == nil, "the failed build left no reservation")
		assert(runtime.command("1", "town-build", "E05:floor:x:1:0").reason == "INVALID_TOWN_BUILD", "bad args")
	end,
	["recover settles a bag lock a crash left behind"] = function()
		local h = harness()
		local runtime, layout = h.runtime, TownPlots.layout(4310)
		runtime.start()
		assert(runtime.command("1", "town-claim", "N01").ok, "claim")
		h.give("1", "wood", 8)
		-- Crash after the bag lock: an open plot reservation and a matching bag reservation.
		local plot = layout.byId.N01
		local doc = runtime.doc("N01") :: any
		local defs =
			{ floor = { id = "floor", footprintX = 2, footprintZ = 2, cost = { { item = "wood", quantity = 4 } } } }
		local reserved, _, id = TownPlots.reserve(
			layout,
			doc,
			"1",
			{ structure = "floor", x = plot.min.x + 8, z = plot.min.z + 8, rotation = 0 },
			defs :: any
		)
		local store = Fenced.new(h.backend, {
			sessionId = "crash",
			leaseSeconds = 60,
			now = function()
				return 1000
			end,
		})
		local profile = assert(store:acquire(TownPlots.key("town-01", "N01"), function(data)
			return data
		end))
		assert(store:update(profile, function()
			return TownPlots.save(reserved :: any)
		end))
		store:release(profile)
		h.bags["1"] = assert(
			Inventory.reserve(
				h.bags["1"],
				"town:town-01:N01:" .. (id :: string),
				{ ["wood-1"] = 4 },
				h.bags["1"].version
			)
		)
		assert(runtime.recover("1").ok, "recover")
		assert(next(h.bags["1"].reservations) == nil and h.count("1", "wood") == 8, "lock released, nothing charged")
		local after = runtime.doc("N01") :: any
		assert(next(after.settlement.reservations) == nil, "open plot reservation cancelled")
	end,
}
