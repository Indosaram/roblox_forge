--!strict
local Effects = require("./EntitlementEffects")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Ledger = require("../../../core/domain/command/Ledger")
local catalog = Catalog.new({ { id = "gear", stackMax = 1, weightMilli = 0, maxDurabilityMilli = 1000 } })
local function item(id: number): any
	return {
		itemId = "gear-" .. id,
		catalogId = "gear",
		quantity = 1,
		qualityMilli = 1000,
		durabilityMilli = 700,
		attributes = { equipped = id == 1, origin = "legacy", grade = 2 },
	}
end
local function filled(slots: number, version: number?, kind: string?): any
	local state = Inventory.new("container", {
		slots = slots,
		contentVersion = version,
		kind = kind,
		softWeightMilli = 90000,
		hardWeightMilli = 90000,
	})
	for n = 1, slots do
		state = assert(Inventory.add(state, catalog, item(n), state.version))
	end
	return Inventory.save(state)
end
return {
	["legacy migration retains identity attributes quantity equipment and reservations"] = function()
		local old = filled(20)
		old.reservations.job = { ["gear-2"] = 1 }
		local before = Ledger.canonical(old)
		local migrated = Effects.migrateBag(old, 2, 30)
		assert(Ledger.canonical(old) == before and old.limits.slots == 20, "migration mutated source")
		assert(migrated.limits.slots == 30, "free bag capacity")
		assert(Ledger.canonical(old.items) == Ledger.canonical(migrated.items), "migration lost item state")
		assert(
			Ledger.canonical(old.reservations) == Ledger.canonical(migrated.reservations),
			"migration lost reservation"
		)
		local state = Inventory.fromSave(migrated, catalog)
		for n = 21, 30 do
			state = assert(Inventory.add(state, catalog, item(n), state.version))
		end
		local denied, reason = Inventory.add(state, catalog, item(31), state.version)
		assert(not denied and reason == "FULL_SLOTS", "31st nonmergeable stack accepted")
	end,
	["expiry preserves overflow and permits withdrawals but no deposits"] = function()
		local saved = filled(45, 2, "home")
		local before = Ledger.canonical(saved)
		local home = Effects.home(saved, 40)
		assert(home.withdrawOnly and home.storageSlots == 40 and home.storage.limits.slots == 45, "overflow hidden")
		assert(
			Ledger.canonical(saved) == before and Ledger.canonical(saved.items) == Ledger.canonical(home.storage.items),
			"expiry deletes items"
		)
		local denied, reason = Effects.deposit(home.storage, catalog, 40, item(46))
		assert(not denied and reason == "HOME_OVERFLOW_WITHDRAW_ONLY", "overflow deposit accepted")
		local state = Inventory.fromSave(home.storage, catalog)
		for n = 45, 40, -1 do
			state = assert(Inventory.consume(state, "gear-" .. n, 1, state.version))
		end
		assert(Effects.deposit(Inventory.save(state), catalog, 40, item(46)), "withdrawal did not restore deposits")
	end,
	["unsupported products cannot prompt even when registered"] = function()
		local effects = {
			warehouseSlots = function() end,
			skinSupported = function(skin)
				return skin == "gold"
			end,
		}
		assert(Effects.supported({ grant = { kind = "storageSlots" } }, effects), "storage disabled")
		assert(
			Effects.supported({ grant = { kind = "cosmeticSet", cosmeticSetId = "gold" } }, effects),
			"skin disabled"
		)
		assert(
			not Effects.supported({ grant = { kind = "cosmeticSet", cosmeticSetId = "missing" } }, effects),
			"missing effect accepted"
		)
		assert(not Effects.supported({ grant = { kind = "currency" } }, effects), "unknown grant accepted")
	end,
}
