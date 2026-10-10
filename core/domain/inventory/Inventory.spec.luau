--!strict
local Inventory = require("./Inventory")
local ItemCatalog = require("./ItemCatalog")
local catalog = ItemCatalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000, maxDurabilityMilli = 1000 } })

local function bag(id: string, slots: number?): Inventory.State
	return Inventory.new(
		id,
		{ slots = slots or 20, softWeightMilli = 60000, hardWeightMilli = 90000, speedPenaltyMilli = 250 }
	)
end

local function item(id: string, quantity: number, quality: number?): Inventory.Item
	return {
		itemId = id,
		catalogId = "wood",
		quantity = quantity,
		qualityMilli = quality or 1000,
		durabilityMilli = 500,
		attributes = { origin = "forest", grade = 2 },
	}
end

local function add(state: Inventory.State, value: Inventory.Item): Inventory.State
	local result, err = Inventory.add(state, catalog, value, state.version)
	assert(result, err)
	return result
end

local function equal(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

return {
	["configured soft threshold may tighten without changing global inbound bounds"] = function()
		local tightened = Inventory.new("tight", { slots = 20, softWeightMilli = 30000, hardWeightMilli = 90000 })
		assert(Inventory.fromSave(Inventory.save(tightened), catalog).limits.softWeightMilli == 30000, "tight save")
		for _, limits in
			{
				{ slots = 21, softWeightMilli = 60000, hardWeightMilli = 90000 },
				{ slots = 20, softWeightMilli = 60000, hardWeightMilli = 90001 },
				{ slots = 20, softWeightMilli = 90001, hardWeightMilli = 90000 },
			}
		do
			assert(not pcall(Inventory.new, "invalid", limits), "new refuses policy bypass")
			local saved = Inventory.save(tightened)
			saved.limits = limits
			assert(not pcall(Inventory.fromSave, saved, catalog), "restore refuses policy bypass")
		end
	end,
	["move conserves units and attributes without mutating either input"] = function()
		local source = add(bag("personal"), item("wood-1", 10))
		local target = bag("tribe")
		local before = Inventory.snapshot(source)
		local left, right, err =
			Inventory.move(source, target, catalog, "wood-1", 3, "transfer-101", source.version, target.version)
		assert(left and right, err)
		assert(left.items["wood-1"].quantity == 7 and right.items["transfer-101"].quantity == 3, "inventory invariant")
		assert(Inventory.weight(left, catalog) + Inventory.weight(right, catalog) == 10000, "inventory invariant")
		assert(equal(before, source) and next(target.items) == nil, "inventory invariant")
		assert(equal(source.items["wood-1"].attributes, right.items["transfer-101"].attributes), "inventory invariant")
		local wholeLeft, wholeRight =
			Inventory.move(left, right, catalog, "wood-1", 7, "wood-1", left.version, right.version)
		assert(
			wholeLeft and wholeRight and not wholeLeft.items["wood-1"] and wholeRight.items["wood-1"].quantity == 7,
			"inventory invariant"
		)
	end,
	["refused moves preserve exact state for stale full same and incompatible targets"] = function()
		local source = add(bag("a"), item("a1", 10))
		local target = add(bag("b", 1), item("b1", 10, 2000))
		local before, targetBefore = Inventory.snapshot(source), Inventory.snapshot(target)
		local cases: { { target: Inventory.State, id: string, version: number, error: string } } = {
			{ target = target, id = "new", version = source.version, error = "FULL_SLOTS" },
			{ target = target, id = "b1", version = source.version, error = "INCOMPATIBLE_STACK" },
			{ target = target, id = "new", version = 0, error = "STALE_VERSION" },
			{ target = source, id = "new", version = source.version, error = "SAME_CONTAINER" },
		}
		for _, test in cases do
			local a, b, err =
				Inventory.move(source, test.target, catalog, "a1", 1, test.id, test.version, (test.target).version)
			assert(not a and not b and err == test.error, "inventory invariant")
		end
		assert(equal(source, before) and equal(target, targetBefore), "inventory invariant")
	end,
	["reservations survive save restoration and competing owner cannot steal final unit"] = function()
		local state = add(bag("a"), item("one", 1))
		local reserved = Inventory.reserve(state, "job1", { one = 1 }, state.version)
		assert(reserved, "inventory invariant")
		local saved = Inventory.save(reserved)
		local restored = Inventory.fromSave(saved, catalog)
		assert(equal(reserved, restored) and Inventory.available(restored, "one") == 0, "inventory invariant")
		local before = Inventory.snapshot(restored)
		assert(not Inventory.reserve(restored, "job2", { one = 1 }, restored.version), "inventory invariant")
		assert(not Inventory.consume(restored, "one", 1, restored.version), "inventory invariant")
		assert(
			not Inventory.move(restored, bag("b"), catalog, "one", 1, "one", restored.version, 0),
			"inventory invariant"
		)
		assert(not Inventory.release(restored, "job2", restored.version), "inventory invariant")
		assert(equal(restored, before), "inventory invariant")
		saved.items.one.attributes.origin = "changed"
		saved.reservations.job1.one = 99
		assert(
			restored.items.one.attributes.origin == "forest" and restored.reservations.job1.one == 1,
			"inventory invariant"
		)
		local released = Inventory.release(restored, "job1", restored.version)
		assert(released and Inventory.available(released, "one") == 1, "inventory invariant")
	end,
	["split merge preserves metadata and refuses different durability and attribute stacks"] = function()
		local state = add(bag("a"), item("one", 10))
		local split = Inventory.split(state, catalog, "one", 4, "two", state.version)
		assert(split and split.items.one.quantity == 6 and split.items.two.quantity == 4, "inventory invariant")
		local merged = Inventory.merge(split, catalog, "two", "one", 4, split.version)
		assert(merged and merged.items.one.quantity == 10 and not merged.items.two, "inventory invariant")
		for _, field in { "durability", "attributes" } do
			local altered = Inventory.snapshot(split)
			if field == "durability" then
				altered.items.two.durabilityMilli = 400
			else
				altered.items.two.attributes.origin = "cave"
			end
			local before = Inventory.snapshot(altered)
			local result, err = Inventory.merge(altered, catalog, "two", "one", 1, altered.version)
			assert(not result and err == "INCOMPATIBLE_STACK" and equal(before, altered), "inventory invariant")
		end
	end,
	["slots and soft hard weight include reserved quantity at exact boundaries"] = function()
		local state = bag("a")
		for i = 1, 20 do
			state = add(state, item(tostring(i), 3))
		end
		assert(
			Inventory.weight(state, catalog) == 60000 and Inventory.speedMultiplierMilli(state, catalog) == 1000,
			"inventory invariant"
		)
		local refused, err = Inventory.add(state, catalog, item("21", 1), state.version)
		assert(not refused and err == "FULL_SLOTS", "inventory invariant")
		local heavy = add(bag("heavy"), item("wood", 90))
		assert(Inventory.speedMultiplierMilli(heavy, catalog) == 750, "inventory invariant")
		local reserved = Inventory.reserve(heavy, "job", { wood = 90 }, heavy.version)
		assert(reserved and Inventory.weight(reserved, catalog) == 90000, "inventory invariant")
		local tooHeavy, weightErr = Inventory.add(reserved, catalog, item("extra", 1), reserved.version)
		assert(not tooHeavy and weightErr == "FULL_WEIGHT", "inventory invariant")
	end,
	["atomic exchange plans output after all reserved consumption and never partially consumes"] = function()
		local state = add(add(bag("a", 2), item("one", 2)), item("two", 3))
		local reserved = Inventory.reserve(state, "job", { one = 2, two = 2 }, state.version)
		assert(reserved, "inventory invariant")
		local before = Inventory.snapshot(reserved)
		local failed, err =
			Inventory.exchange(reserved, catalog, "job", { item("out1", 1), item("out2", 1) }, reserved.version)
		assert(not failed and err == "FULL_SLOTS" and equal(before, reserved), "inventory invariant")
		local success = Inventory.exchange(reserved, catalog, "job", { item("out1", 4) }, reserved.version)
		assert(
			success and not success.items.one and success.items.two.quantity == 1 and success.items.out1.quantity == 4,
			"inventory invariant"
		)
		assert(
			not success.reservations.job and not Inventory.exchange(success, catalog, "job", {}, success.version),
			"inventory invariant"
		)
	end,
	["integer boundaries reject NaN infinities fractions and malformed saves unchanged"] = function()
		local state = add(bag("a"), item("one", 3))
		local before = Inventory.snapshot(state)
		for _, bad in { 0 / 0, math.huge, -math.huge, 1.5, 0, -1 } do
			assert(not Inventory.consume(state, "one", bad, state.version), "inventory invariant")
			local invalid = item("invalid", bad)
			assert(not Inventory.add(state, catalog, invalid, state.version), "inventory invariant")
		end
		assert(equal(before, state), "inventory invariant")
		local save = Inventory.save(state)
		save.reservations = { owner1 = { one = 2 }, owner2 = { one = 2 } }
		assert(not pcall(Inventory.fromSave, save, catalog), "inventory invariant")
		save.saveVersion = 2
		assert(not pcall(Inventory.fromSave, save, catalog), "inventory invariant")
	end,
}
