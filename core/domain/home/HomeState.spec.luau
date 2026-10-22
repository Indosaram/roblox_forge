--!strict
local Home = require("./HomeState")
local Inventory = require("../inventory/Inventory")
local Catalog = require("../inventory/ItemCatalog")
local serde = require("@lune/serde")
local M = {}

function M.placedPlotCap()
	local f = M.fixture()
	f.ctx.rules.placedPlots = true
	f.ctx.rules.plotCaps = { 1, 2, 3 }
	f.ctx.structures["farm-plot"] = f.ctx.structures.workbench
	f.state.structures.plot = { kind = "farm-plot", position = { x = 0, y = 2, z = 0 }, owner = "owner" }
	local state, reason = Home.apply(f.state, "owner", "home:owner", "place", {
		id = "second",
		kind = "farm-plot",
		position = { x = 12, y = 2, z = 0 },
	}, f.ctx)
	assert(state == nil and reason == "PLOT_CAP", "placed plot cap")
	local planted = assert(Home.apply(f.state, "owner", "home:owner", "plant", {
		plot = "plot",
		crop = "corn",
		seedItem = "seed",
	}, f.ctx))
	local recovered, errorCode = Home.apply(planted, "owner", "home:owner", "recover", { id = "plot" }, f.ctx)
	assert(recovered == nil and errorCode == "PLOT_OCCUPIED", "cannot recover planted plot")
	local unknown, unknownReason = Home.apply(f.state, "owner", "home:owner", "plant", {
		plot = "p1",
		crop = "corn",
		seedItem = "seed",
	}, f.ctx)
	assert(unknown == nil and unknownReason == "UNKNOWN_CROP_OR_PLOT", "fixed fixture plot does not exist")
end

function M.fixture(): any
	local catalog = Catalog.new({
		{ id = "corn-seed", stackMax = 50, weightMilli = 0 },
		{ id = "water", stackMax = 50, weightMilli = 0 },
		{ id = "corn", stackMax = 50, weightMilli = 0 },
		{ id = "workbench-kit", stackMax = 1, weightMilli = 0 },
	})
	local rules = {
		baseSlots = 20,
		storageGrants = { patron = 10, warehouse = 10, monthly = 5 },
		landSizes = { 64, 96, 128 },
		floors = { 2, 14, 26 },
		dock = { x = 0, y = 2, z = 144 },
		plots = { p1 = true },
	}
	local state = Home.new("owner", rules, 74)
	local bag = Inventory.fromSave(state.storage, catalog)
	for _, item in
		{
			{ id = "seed", kind = "corn-seed", quantity = 2 },
			{ id = "water", kind = "water", quantity = 2 },
			{ id = "kit", kind = "workbench-kit", quantity = 1 },
		}
	do
		bag = assert(Inventory.add(bag, catalog, {
			itemId = item.id,
			catalogId = item.kind,
			quantity = item.quantity,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = { level = 30 },
		}, bag.version))
	end
	state.storage = Inventory.save(bag)
	return {
		state = state,
		ctx = {
			rules = rules,
			catalog = catalog,
			facts = { ownerOnline = true },
			now = 10,
			nodes = { farming_1 = true },
			entitlements = {},
			developmentRank = 3,
			structures = { workbench = { kit = "workbench-kit", halfSize = 4, rank = 1 } },
			crops = {
				corn = {
					seed = "corn-seed",
					output = "corn",
					seconds = 600,
					quantity = 3,
					inputs = { { item = "corn-seed", quantity = 1 }, { item = "water", quantity = 1 } },
					nodes = { "farming_1" },
				},
			},
		},
	}
end

local function apply(f: any, action: string, args: any, actor: string?): (any?, string?)
	return Home.apply(f.state, actor or "owner", f.state.homeId, action, args, f.ctx)
end

return {
	["placed farm plots use stable identities and enforce tier cap"] = M.placedPlotCap,
	["expiry overflow remains loadable and refuses harvest until space exists"] = function()
		local f = M.fixture()
		f.ctx.entitlements = { patron = true, warehouse = true, monthly = true }
		f.state = assert(apply(f, "capacity", {}))
		f.state = assert(apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "seed" }))
		local bag = Inventory.fromSave(f.state.storage, f.ctx.catalog)
		for index = 1, 39 do
			bag = assert(Inventory.add(bag, f.ctx.catalog, {
				itemId = "stored-" .. tostring(index),
				catalogId = "workbench-kit",
				quantity = 1,
				qualityMilli = 1000,
				durabilityMilli = 0,
				attributes = {},
			}, bag.version))
		end
		f.state.storage = Inventory.save(bag)
		f.ctx.entitlements.monthly = nil
		f.state = assert(apply(f, "capacity", {}))
		f.state = Home.load(f.state, "owner", f.ctx.catalog)
		assert(f.state.storageSlots == 40 and f.state.storage.limits.slots == 42, "overflow retains 42 identities")
		f.ctx.now = 610
		local out, reason = apply(f, "harvest", { plot = "p1" })
		assert(out == nil and reason == "FULL_SLOTS" and f.state.plots.p1 ~= nil, "full home retains crop")
	end,
	["placement consumes one kit and recovery returns it once"] = function()
		local f = M.fixture()
		f.state = assert(apply(f, "place", { id = "bench", kind = "workbench", position = { x = 0, y = 2, z = -16 } }))
		assert(f.state.storage.items.kit == nil, "deployment consumes kit")
		local out, reason =
			apply(f, "place", { id = "bench", kind = "workbench", position = { x = 0, y = 2, z = -16 } })
		assert(out == nil and reason == "INVALID_STRUCTURE", "duplicate placement refused")
		f.state = assert(apply(f, "recover", { id = "bench" }))
		assert(f.state.structures.bench == nil, "recovery removes structure")
		local twice, twiceReason = apply(f, "recover", { id = "bench" })
		assert(twice == nil and twiceReason == "UNKNOWN_STRUCTURE", "duplicate recovery refused")
	end,
	["home fixed identity and copy save survive a new load"] = function()
		local f = M.fixture()
		f.state = assert(apply(f, "place", { id = "bench", kind = "workbench", position = { x = 0, y = 2, z = -16 } }))
		f.state = assert(apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "seed" }))
		local loaded = Home.load(f.state, "owner", f.ctx.catalog)
		assert(
			loaded.homeId == "home:owner" and loaded.structures.bench and loaded.plots.p1.readyAt == 610,
			"home invariant: 40"
		)
		loaded.storage.items.seed.quantity = 9
		assert(f.state.storage.items.seed.quantity == 1, "home invariant: 42")
		assert(not pcall(Home.load, f.state, "other", f.ctx.catalog), "home invariant: 43")
	end,
	["wrong token and nonmembers cannot harvest or recover without side effects"] = function()
		local f = M.fixture()
		f.state = assert(apply(f, "place", { id = "bench", kind = "workbench", position = { x = 0, y = 2, z = -16 } }))
		f.state = assert(apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "seed" }))
		f.ctx.now = 610
		local revision = f.state.revision
		local before = serde.encode("json", f.state)
		for _, action in { "harvest", "recover" } do
			local out, reason = apply(f, action, { plot = "p1", id = "bench" }, "intruder")
			assert(out == nil and reason == "FORBIDDEN", "home invariant: 53")
			assert(
				serde.encode("json", f.state) == before,
				"nonmember refusal preserves entire home and storage version"
			)
		end
		local out, reason = Home.apply(f.state, "owner", "home:other", "harvest", { plot = "p1" }, f.ctx)
		assert(out == nil and reason == "WRONG_HOME_TOKEN", "home invariant: 56")
		assert(serde.encode("json", f.state) == before, "wrong token preserves entire home and storage version")
		assert(f.state.revision == revision and f.state.plots.p1 and f.state.structures.bench, "home invariant: 57")
	end,
	["explicit growth clock reconnect recovery and double harvest"] = function()
		local f = M.fixture()
		f.state = assert(apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "seed" }))
		local out, reason = apply(f, "harvest", { plot = "p1" })
		assert(out == nil and reason == "NOT_GROWN", "home invariant: 63")
		local duplicate, duplicateReason = apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "seed" })
		assert(duplicate == nil and duplicateReason == "PLOT_OCCUPIED", "home invariant: 65")
		local saved = Home.copy(f.state)
		f.ctx.now = 610
		f.state = Home.load(saved, "owner", f.ctx.catalog)
		f.state = assert(apply(f, "harvest", { plot = "p1" }))
		local crop = f.state.storage.items["home:owner:crop:1"]
		assert(
			crop.quantity == 3 and crop.attributes.level == 30 and crop.attributes.roll == saved.plots.p1.roll,
			"home invariant: 71"
		)
		local before = serde.encode("json", f.state)
		local twice, twiceReason = apply(f, "harvest", { plot = "p1" })
		assert(twice == nil and twiceReason == "EMPTY_PLOT", "second harvest refused")
		assert(serde.encode("json", f.state) == before, "double harvest preserves entire home and storage version")
		local same = M.fixture()
		same.state = assert(apply(same, "plant", { plot = "p1", crop = "corn", seedItem = "seed" }))
		assert(same.state.plots.p1.roll == saved.plots.p1.roll, "home invariant: 76")
	end,
	["offline owner permission survives load and requires real friendship or clan"] = function()
		local f = M.fixture()
		f.state = assert(apply(f, "permissions", {
			permissions = {
				visit = "friend",
				cooperate = "friend",
				friends = { helper = true },
				clanId = "clan",
				offlineCoop = true,
			},
		}))
		f.state = Home.load(f.state, "owner", f.ctx.catalog)
		f.ctx.facts = { friend = true, ownerOnline = false }
		assert(Home.allowed(f.state, "helper", "cooperate", f.ctx.facts))
		assert(not Home.allowed(f.state, "stranger", "visit", f.ctx.facts), "home invariant: 85")
		assert(
			not Home.allowed(f.state, "helper", "cooperate", { friend = false, ownerOnline = false }),
			"home invariant: 86"
		)
		f.state.permissions.offlineCoop = false
		assert(not Home.allowed(f.state, "helper", "cooperate", f.ctx.facts), "home invariant: 88")
		f.state.permissions.cooperate = "clan"
		f.state.permissions.offlineCoop = true
		assert(Home.allowed(f.state, "member", "cooperate", { clanId = "clan", ownerOnline = false }))
		assert(
			not Home.allowed(f.state, "member", "cooperate", { clanId = "other", ownerOnline = true }),
			"home invariant: 92"
		)
	end,
	["capacity entitlements are home only and land expands at fixed dock"] = function()
		local f = M.fixture()
		for _, case in
			{
				{ grants = {}, slots = 20 },
				{ grants = { patron = true }, slots = 30 },
				{ grants = { patron = true, warehouse = true }, slots = 40 },
				{ grants = { patron = true, warehouse = true, monthly = true }, slots = 45 },
			}
		do
			f.ctx.entitlements = case.grants
			f.state = assert(apply(f, "capacity", {}))
			assert(
				f.state.storage.limits.slots == case.slots and f.state.storage.limits.kind == "home",
				"home invariant: 100"
			)
		end
		assert(not apply(f, "expand", { atDock = false }), "home invariant: 104")
		f.state = assert(apply(f, "expand", { atDock = true }))
		assert(f.state.landRank == 3 and f.state.dock.z == 144, "home invariant: 106")
		assert(not apply(f, "expand", { atDock = true }), "same earned rank expands only once")
	end,
	["skill seed water placement and unknown actions refuse atomically"] = function()
		local f = M.fixture()
		f.ctx.nodes = {}
		local out, reason = apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "seed" })
		assert(out == nil and reason == "SKILL_LOCKED", "home invariant: 112")
		f.ctx.nodes.farming_1 = true
		local wrongSeed, wrongSeedReason = apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "water" })
		assert(wrongSeed == nil and wrongSeedReason == "WRONG_SEED", "seed identity enforced")
		f.state.storage.items.water = nil
		local dry, dryReason = apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "seed" })
		assert(
			dry == nil and dryReason == "INSUFFICIENT_ITEMS" and f.state.storage.items.seed.quantity == 2,
			"home invariant: 118"
		)
		local outside, outsideReason =
			apply(f, "place", { id = "bench", kind = "workbench", position = { x = 40, y = 2, z = 0 } })
		assert(outside == nil and outsideReason == "OUTSIDE_LAND", "placement boundary enforced")
		local unknown, unknownReason = apply(f, "unknown", {})
		assert(unknown == nil and unknownReason == "UNKNOWN_ACTION", "unknown action refused")
	end,
}
