--!strict
local Consumption = require("./Consumption")
local Content = require("./Content")
local Vitals = require("./Vitals")
local Inventory = require("../inventory/Inventory")
local ItemCatalog = require("../inventory/ItemCatalog")

-- Test catalog only; no gameplay catalog or balance policy is installed.
local function rawContent(): any
	local items: { Content.Item } = {
		{
			id = "food",
			name = "Food",
			stackMax = 10,
			weightMilli = 100,
			tags = {},
			foodEffects = { hungerMilli = 20000, healthMilli = 10000, fatigueMilli = 1000 },
		},
		{
			id = "health",
			name = "Health",
			stackMax = 10,
			weightMilli = 100,
			tags = {},
			foodEffects = { hungerMilli = 0, healthMilli = 10000, fatigueMilli = 0 },
		},
		{
			id = "zero",
			name = "Zero",
			stackMax = 10,
			weightMilli = 100,
			tags = {},
			foodEffects = { hungerMilli = 0, healthMilli = 0, fatigueMilli = 0 },
		},
		{ id = "stone", name = "Stone", stackMax = 10, weightMilli = 100, tags = {} },
	}
	return {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		items = items,
	}
end

local function fixture(): (Content.Document, Inventory.State, Vitals.State)
	local content, errors = Content.canonicalize(rawContent())
	assert(content, table.concat(errors, "; "))
	local definitions: { ItemCatalog.Definition } = {}
	for _, item in content.items do
		table.insert(definitions, {
			id = item.id,
			stackMax = item.stackMax,
			weightMilli = item.weightMilli,
			maxDurabilityMilli = item.maxDurabilityMilli,
		})
	end
	local catalog = ItemCatalog.new(definitions)
	local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for _, definition in content.items do
		local added, err = Inventory.add(bag, catalog, {
			itemId = definition.id .. "-stack",
			catalogId = definition.id,
			quantity = 2,
			qualityMilli = 1200,
			durabilityMilli = 0,
			attributes = { origin = "fixture" },
		}, bag.version)
		assert(added, err)
		bag = added
	end
	local vitals = Vitals.new(0, {
		hungerMillisPerUnit = 17000,
		fatigueMilliPerAction = 501,
		restMilliPerSecond = 2001,
		starvationMillisPerUnit = 5001,
	})
	vitals = Vitals.advance(Vitals.action(Vitals.damage(vitals, 5000)), 101)
	return content, bag, vitals
end

local function equal(left: any, right: any)
	assert(type(left) == type(right), "type changed")
	if type(left) ~= "table" then
		assert(left == right, "value changed")
		return
	end
	for key, value in left do
		equal(value, right[key])
	end
	for key in right do
		assert(left[key] ~= nil, "extra key")
	end
end

local function refused(bag: Inventory.State, vitals: Vitals.State, content: Content.Document, id: string, code: string)
	local before = Inventory.snapshot(bag)
	local beforeVitals = table.clone(vitals)
	local nextBag, nextVitals, err = Consumption.consume(bag, vitals, content, id)
	assert(nextBag == nil and nextVitals == nil and err == code, tostring(err))
	equal(bag, before)
	equal(vitals, beforeVitals)
end

return {
	["food resolves actual stack catalog and returns one detached clamped debit"] = function()
		local content, bag, vitals = fixture()
		local before, beforeVitals = Inventory.snapshot(bag), table.clone(vitals)
		local nextBag, nextVitals, err = Consumption.consume(bag, vitals, content, "food-stack")
		assert(nextBag and nextVitals and err == nil, "useful food succeeds")
		assert(nextBag.items["food-stack"].quantity == 1 and nextBag.version == bag.version + 1, "one debit")
		assert(
			nextVitals.healthMilli == 100000 and nextVitals.hungerMilli == 100000 and nextVitals.fatigueMilli == 0,
			"effects clamp"
		)
		equal(nextVitals, Vitals.food(vitals, content.items[1].foodEffects :: Content.FoodEffects))
		equal(bag, before)
		equal(vitals, beforeVitals)
		local againBag, againVitals = Consumption.consume(bag, vitals, content, "food-stack")
		equal(nextBag, againBag)
		equal(nextVitals, againVitals)
		assert(nextVitals.config ~= vitals.config and table.isfrozen(nextVitals.config), "detached immutable config")
		nextBag.items["stone-stack"].attributes.origin = "changed"
		equal(bag, before)
	end,
	["missing identity nonfood nofood and ineffective food leave both states unchanged"] = function()
		local content, bag, vitals = fixture()
		refused(bag, vitals, content, "", "INVALID_ITEM_ID")
		refused(bag, vitals, content, nil :: any, "INVALID_ITEM_ID")
		refused(bag, vitals, content, "absent", "UNAVAILABLE")
		refused(bag, vitals, content, "stone-stack", "NOT_FOOD")
		refused(bag, vitals, content, "zero-stack", "NO_EFFECT")
		local full = Vitals.new(0)
		refused(bag, full, content, "food-stack", "NO_EFFECT")
		full = Vitals.advance(full, 18000)
		refused(bag, full, content, "health-stack", "NO_EFFECT")
	end,
	["reserved quantity cannot be consumed and unreserved unit remains usable"] = function()
		local content, bag, vitals = fixture()
		local reserved = Inventory.reserve(bag, "craft", { ["food-stack"] = 2 }, bag.version)
		assert(reserved, "reserve entire stack")
		refused(reserved, vitals, content, "food-stack", "UNAVAILABLE")
		local partial = Inventory.reserve(bag, "craft", { ["food-stack"] = 1 }, bag.version)
		assert(partial, "reserve one unit")
		local consumed = Consumption.consume(partial, vitals, content, "food-stack")
		assert(consumed and consumed.items["food-stack"].quantity == 1, "consume unreserved unit")
		assert(consumed.reservations.craft["food-stack"] == 1, "preserve reservation")
		refused(consumed, vitals, content, "food-stack", "UNAVAILABLE")
	end,
	["dead and offline actors cannot debit food"] = function()
		local content, bag, vitals = fixture()
		refused(bag, Vitals.damage(vitals, 100000), content, "food-stack", "NOT_ALIVE")
		refused(bag, Vitals.disconnect(vitals, vitals.clockMillis), content, "food-stack", "NOT_ALIVE")
	end,
	["content boundary refuses missing identity and NaN food effects"] = function()
		local raw = rawContent()
		raw.items[1].id = nil
		local content, errors = Content.canonicalize(raw)
		assert(content == nil and #errors > 0, "missing catalog identity rejected")
		raw = rawContent()
		raw.items[1].foodEffects.healthMilli = 0 / 0
		content, errors = Content.canonicalize(raw)
		assert(content == nil and #errors > 0, "NaN catalog effect rejected")
	end,
}
