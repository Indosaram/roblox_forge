--!strict
local Home = require("./HomeState")
local Farming = require("./Farming")
local Inventory = require("../inventory/Inventory")
local Catalog = require("../inventory/ItemCatalog")

local function fixture(stock: { [string]: number }): any
	local ids =
		{ "corn-seed", "water", "corn", "liquid-fertilizer", "fruit-fertilizer", "stem-fertilizer", "sprinkler" }
	local definitions = {}
	for _, id in ids do
		table.insert(definitions, { id = id, stackMax = 50, weightMilli = 0 })
	end
	local catalog = Catalog.new(definitions)
	local rules = {
		baseSlots = 20,
		storageGrants = {},
		landSizes = { 64 },
		floors = { 2 },
		dock = { x = 0, y = 2, z = 30 },
		placedPlots = true,
		plotCaps = { 12 },
	}
	local state = Home.new("owner", rules, 74)
	local bag = Inventory.fromSave(state.storage, catalog)
	for _, id in ids do
		if stock[id] then
			bag = assert(Inventory.add(bag, catalog, {
				itemId = id,
				catalogId = id,
				quantity = stock[id],
				qualityMilli = 1000,
				durabilityMilli = 0,
				attributes = { level = 10 },
			}, bag.version))
		end
	end
	state.storage = Inventory.save(bag)
	for index, x in { 0, 8, 30 } do
		state.structures["p" .. index] = { kind = "farm-plot", position = { x = x, y = 2, z = 0 }, owner = "owner" }
	end
	return {
		state = state,
		ctx = {
			rules = rules,
			catalog = catalog,
			facts = {},
			now = 0,
			nodes = { farming_1 = true },
			entitlements = {},
			structures = {},
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
	local out, reason = Home.apply(f.state, actor or "owner", f.state.homeId, action, args, f.ctx)
	if out then
		f.state = out
	end
	return out, reason
end

local function refusal(f: any, action: string, args: any, actor: string?): string?
	local out, reason = apply(f, action, args, actor)
	return if out == nil then reason else "ACCEPTED"
end

local function held(f: any, catalogId: string): number
	local total = 0
	for _, item in f.state.storage.items do
		if item.catalogId == catalogId then
			total += item.quantity
		end
	end
	return total
end

return {
	["harvests rank the crop book and unlock one specialization per rank 1 3 5"] = function()
		local f = fixture({ ["corn-seed"] = 20, water = 20 })
		assert(
			refusal(f, "specialize", { crop = "corn", effect = "yield" }) == "RANK_LOCKED",
			"rank 0 cannot specialize"
		)
		assert(apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "corn-seed" }))
		f.ctx.now = 600
		assert(apply(f, "harvest", { plot = "p1" }))
		assert(Farming.rank(Farming.entry(f.state, "corn").harvests) == 1, "one harvest is rank 1")
		assert(apply(f, "specialize", { crop = "corn", effect = "time" }))
		assert(refusal(f, "specialize", { crop = "corn", effect = "yield" }) == "RANK_LOCKED", "one choice at rank 1")
		f.state.cropBook.corn.harvests = 6
		assert(
			refusal(f, "specialize", { crop = "corn", effect = "time" }) == "DUPLICATE_EFFECT",
			"no duplicate effects"
		)
		assert(apply(f, "specialize", { crop = "corn", effect = "yield" }))
		assert(refusal(f, "specialize", { crop = "corn", effect = "quality" }, "visitor") == "FORBIDDEN", "owner only")
		f.ctx.now = 1000
		assert(apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "corn-seed" }))
		local planted = f.state.plots.p1
		assert(planted.readyAt == 1000 + 540 and planted.quantity == 4, "time and yield effects apply to the next crop")
	end,
	["fertilizer consumes one unit and refuses wrong crop or double use without consuming"] = function()
		local f = fixture({ ["corn-seed"] = 2, water = 2, ["liquid-fertilizer"] = 2, ["fruit-fertilizer"] = 1 })
		assert(apply(f, "plant", { plot = "p1", crop = "corn", seedItem = "corn-seed" }))
		assert(
			refusal(f, "fertilize", { plot = "p1", fertilizer = "fruit-fertilizer" }) == "FERTILIZER_NOT_APPLICABLE"
				and held(f, "fruit-fertilizer") == 1,
			"fruit only"
		)
		f.ctx.now = 100
		assert(apply(f, "fertilize", { plot = "p1", fertilizer = "liquid-fertilizer" }))
		assert(f.state.plots.p1.readyAt == 600 - 100 and held(f, "liquid-fertilizer") == 1, "20% of remaining time")
		assert(
			refusal(f, "fertilize", { plot = "p1", fertilizer = "liquid-fertilizer" }) == "ALREADY_FERTILIZED"
				and held(f, "liquid-fertilizer") == 1,
			"once per crop"
		)
	end,
	["sprayer applies water and fertilizer per selected plot inside radius and reports each"] = function()
		local f = fixture({ ["corn-seed"] = 3, water = 4, ["liquid-fertilizer"] = 3 })
		for _, plot in { "p1", "p2", "p3" } do
			assert(apply(f, "plant", { plot = plot, crop = "corn", seedItem = "corn-seed" }))
		end
		assert(
			refusal(f, "area", { plot = "p1", plots = "p1,p2", fertilizer = "liquid-fertilizer" }) == "TOOL_REQUIRED",
			"sprinkler required"
		)
		f = fixture({ ["corn-seed"] = 3, water = 6, ["liquid-fertilizer"] = 3, sprinkler = 1 })
		for _, plot in { "p1", "p2", "p3" } do
			assert(apply(f, "plant", { plot = plot, crop = "corn", seedItem = "corn-seed" }))
		end
		assert(apply(f, "area", { plot = "p1", plots = "p1,p2,p3", fertilizer = "liquid-fertilizer" }))
		local results = f.state.areaResults
		assert(results[1].ok and results[2].ok and results[3].reason == "OUT_OF_AREA", "per-plot result")
		assert(held(f, "water") == 1 and held(f, "liquid-fertilizer") == 1, "two plots charged")
		assert(
			refusal(f, "area", { plot = "p1", plots = "p1,p2", fertilizer = "liquid-fertilizer" })
					== "ALREADY_FERTILIZED"
				and held(f, "water") == 1,
			"retry does not double charge"
		)
		assert(
			refusal(f, "area", { plot = "p1", plots = "a,b,c,d,e,f,g,h,i,j", fertilizer = "liquid-fertilizer" })
				== "AREA_LIMIT",
			"nine plots max"
		)
	end,
}
