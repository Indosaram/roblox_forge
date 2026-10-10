--!strict
local Death = require("./DeathBundle")
local Inventory = require("../inventory/Inventory")
local Catalog = require("../inventory/ItemCatalog")
local Vitals = require("./Vitals")
local serde = require("@lune/serde")

local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 100 } })
local authority = { ownerId = "alice", serverId = "server" }
local function fixture(active: number?): (Death.State, Inventory.State, Vitals.State)
	local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for _, id in { "axe", "wood" } do
		bag = assert(Inventory.add(bag, catalog, {
			itemId = id,
			catalogId = "wood",
			quantity = 10,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = { origin = id },
		}, bag.version))
	end
	local vitals = Vitals.new(1000)
	vitals.healthMilli = 0
	vitals.activeMillis = active or 1800000
	return Death.new("alice", "server", "bag", 1000), bag, vitals
end

local function total(state: Death.State, bag: Inventory.State): number
	local quantity = 0
	for _, item in bag.items do
		quantity += item.quantity
	end
	for _, bundle in state.bundles do
		for _, item in bundle.inventory.items do
			quantity += item.quantity
		end
	end
	return quantity
end

return {
	["2026 Unix milliseconds support drop pickup JSON restart and expiry"] = function()
		local now = 1790899200000 -- 2026-10-02 UTC
		local _, bag, vitals = fixture()
		vitals.clockMillis = now
		local state = Death.new("alice", "server", "bag", now)
		local dropped, carried = Death.drop(state, bag, catalog, vitals, authority, 1, {}, now)
		assert(dropped and carried, "Unix-clock death must drop")
		local restored = Death.fromSave(serde.decode("json", serde.encode("json", Death.save(dropped))), catalog)
		assert(restored.bundles["death:1"].expiresMillis == now + 600000, "expiry must retain absolute milliseconds")
		vitals.healthMilli = 1
		vitals.clockMillis = now + 599999
		local picked, recovered = Death.pickup(restored, carried, catalog, vitals, authority, "death:1", now + 599999)
		assert(picked and recovered and total(picked, recovered) == 20, "Unix-clock pickup must conserve inventory")
		local expired = assert(Death.expire(restored, authority, now + 600000))
		assert(not next(expired.bundles) and expired.lastSequence == 1, "Unix-clock expiry must remove once")
	end,
	["newcomer threshold keeps bag and records death identity"] = function()
		local state, bag, vitals = fixture(1799999)
		local s, b, err = Death.drop(state, bag, catalog, vitals, authority, 1, {}, 1000)
		assert(s and b and not err and not next(s.bundles) and total(s, b) == 20, "death ownership invariant 36")
		assert(b.version == bag.version and b.items.wood.quantity == 10, "death ownership invariant 37")
		local duplicate, _, failure = Death.drop(s, b, catalog, vitals, authority, 1, {}, 1000)
		assert(not duplicate and failure == "DEATH_SEQUENCE", "death ownership invariant 39")
	end,
	["equipped owned identity retained and whole bag stack moved once"] = function()
		local state, bag, vitals = fixture()
		local s, b = Death.drop(state, bag, catalog, vitals, authority, 1, { axe = true }, 1000)
		assert(s and b and b.items.axe and not b.items.wood, "death ownership invariant 44")
		assert(
			s.bundles["death:1"].inventory.items.wood.quantity == 10 and total(s, b) == 20,
			"death ownership invariant 45"
		)
		assert(bag.items.wood.quantity == 10 and not next(state.bundles), "death ownership invariant 46")
		local rejected, _, err = Death.drop(state, bag, catalog, vitals, authority, 1, { invented = true }, 1000)
		assert(not rejected and err == "INVALID_EQUIPMENT", "death ownership invariant 48")
	end,
	["reserved partial stack stays job owned through drop and pickup"] = function()
		local state, bag, vitals = fixture()
		bag = assert(Inventory.reserve(bag, "craft-job", { wood = 4 }, bag.version))
		local s, b = Death.drop(state, bag, catalog, vitals, authority, 1, { axe = true }, 1000)
		assert(s and b and total(s, b) == 20, "death ownership invariant 54")
		assert(b.items.wood.quantity == 4 and b.reservations["craft-job"].wood == 4, "death ownership invariant 55")
		assert(Inventory.available(b, "wood") == 0, "death ownership invariant 56")
		assert(s.bundles["death:1"].inventory.items["death:1:split:2"].quantity == 6, "death ownership invariant 57")
		vitals.healthMilli = 100000
		local picked, restored = Death.pickup(s, b, catalog, vitals, authority, "death:1", 1000)
		assert(
			picked and restored and total(picked, restored) == 20 and not next(picked.bundles),
			"death ownership invariant 60"
		)
		assert(restored.reservations["craft-job"].wood == 4, "death ownership invariant 61")
		local completed = assert(Inventory.exchange(restored, catalog, "craft-job", {}, restored.version))
		assert(total(picked, completed) == 16 and not completed.items.wood, "death ownership invariant 63")
	end,
	["pickup rejects foreign server dead actor and wrong container"] = function()
		local state, bag, vitals = fixture()
		local s, b = Death.drop(state, bag, catalog, vitals, authority, 1, {}, 1000)
		assert(s and b, "death ownership invariant 68")
		for _, auth in { { ownerId = "bob", serverId = "server" }, { ownerId = "alice", serverId = "other" } } do
			local result, _, err = Death.pickup(s, b, catalog, vitals, auth, "death:1", 1000)
			assert(not result and err == "UNAUTHORIZED", "death ownership invariant 71")
		end
		local result, _, err = Death.pickup(s, b, catalog, vitals, authority, "death:1", 1000)
		assert(not result and err == "NOT_CURRENT_LIVING_ACTOR", "death ownership invariant 74")
		vitals.healthMilli = 1
		local wrong = Inventory.snapshot(b)
		wrong.id = "foreign"
		local wrongResult, _, wrongError = Death.pickup(s, wrong, catalog, vitals, authority, "death:1", 1000)
		assert(not wrongResult and wrongError == "WRONG_CONTAINER", "death ownership invariant 79")
	end,
	["projected full pickup is atomic including second stack failure"] = function()
		local state, bag, vitals = fixture()
		local s, b = Death.drop(state, bag, catalog, vitals, authority, 1, {}, 1000)
		assert(s and b, "death ownership invariant 84")
		vitals.healthMilli = 1
		b.limits.slots = 1
		local result, _, err = Death.pickup(s, b, catalog, vitals, authority, "death:1", 1000)
		assert(
			not result and err == "FULL_SLOTS" and not next(b.items) and total(s, b) == 20,
			"death ownership invariant 88"
		)
		b.limits.slots = 20
		b.limits.softWeightMilli = 0
		b.limits.hardWeightMilli = 1500
		local weightResult, _, weightError = Death.pickup(s, b, catalog, vitals, authority, "death:1", 1000)
		assert(
			not weightResult and weightError == "FULL_WEIGHT" and not next(b.items) and total(s, b) == 20,
			"death ownership invariant 93"
		)
	end,
	["absolute expiry exact boundary deletes once and cannot resurrect"] = function()
		local state, bag, vitals = fixture()
		local s, b = Death.drop(state, bag, catalog, vitals, authority, 1, {}, 1000)
		assert(s and b, "death ownership invariant 98")
		vitals.healthMilli = 1
		vitals.clockMillis = 600999
		local before, restored = Death.pickup(s, b, catalog, vitals, authority, "death:1", 600999)
		assert(before and restored and total(before, restored) == 20, "death ownership invariant 102")
		vitals.clockMillis = 601000
		local exact, _, err = Death.pickup(s, b, catalog, vitals, authority, "death:1", 601000)
		assert(not exact and err == "BUNDLE_EXPIRED", "death ownership invariant 105")
		local expired = assert(Death.expire(s, authority, 601000))
		assert(not next(expired.bundles) and total(expired, b) == 0, "death ownership invariant 107")
		expired = assert(Death.expire(expired, authority, 601000))
		assert(not next(expired.bundles) and expired.lastSequence == 1, "death ownership invariant 109")
		vitals.healthMilli = 0
		local replay, _, replayError = Death.drop(expired, b, catalog, vitals, authority, 1, {}, 601000)
		assert(not replay and replayError == "DEATH_SEQUENCE", "death ownership invariant 112")
	end,
	["JSON restart preserves ownership and terminal replay protection"] = function()
		local state, bag, vitals = fixture()
		local s, b = Death.drop(state, bag, catalog, vitals, authority, 1, {}, 1000)
		assert(s and b, "death ownership invariant 117")
		s = Death.fromSave(serde.decode("json", serde.encode("json", Death.save(s))), catalog)
		b = Inventory.fromSave(serde.decode("json", serde.encode("json", Inventory.save(b))), catalog)
		local replay, _, err = Death.drop(s, b, catalog, vitals, authority, 1, {}, 1000)
		assert(not replay and err == "DEATH_SEQUENCE" and total(s, b) == 20, "death ownership invariant 121")
		vitals.healthMilli = 1
		local picked, restored = Death.pickup(s, b, catalog, vitals, authority, "death:1", 1000)
		assert(picked and restored and total(picked, restored) == 20, "death ownership invariant 124")
		picked = Death.fromSave(serde.decode("json", serde.encode("json", Death.save(picked))), catalog)
		local duplicate, _, failure = Death.pickup(picked, restored, catalog, vitals, authority, "death:1", 1000)
		assert(
			not duplicate and failure == "BUNDLE_NOT_FOUND" and total(picked, restored) == 20,
			"death ownership invariant 127"
		)
	end,
}
