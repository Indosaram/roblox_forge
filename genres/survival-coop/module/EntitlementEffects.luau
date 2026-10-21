--!strict
-- Inject pack policy/catalog values; no product IDs or pack catalog are copied here.
local Inventory = require("../../../core/domain/inventory/Inventory")
local M = {}
function M.migrateBag(saved: any, contentVersion: number, slots: number): any
	local result = table.clone(saved)
	result.limits = table.clone(saved.limits)
	result.limits.contentVersion = contentVersion
	result.limits.kind = "bag"
	result.limits.slots = slots
	return result
end
function M.home(saved: any, capacity: number): any
	-- Keep the physical envelope large enough to decode overflow after expiry.
	local result = table.clone(saved)
	result.limits = table.clone(saved.limits)
	local occupied = 0
	for _ in saved.items do
		occupied += 1
	end
	result.limits.slots = math.max(capacity, occupied)
	return { storage = result, storageSlots = capacity, withdrawOnly = occupied > capacity }
end
function M.deposit(saved: any, catalog: any, capacity: number, item: any): (any?, string?)
	local occupied = 0
	for _ in saved.items do
		occupied += 1
	end
	if occupied > capacity then
		return nil, "HOME_OVERFLOW_WITHDRAW_ONLY"
	end
	local target = Inventory.fromSave(saved, catalog)
	target.limits.slots = capacity
	local updated, reason = Inventory.add(target, catalog, item, target.version)
	return if updated then Inventory.save(updated) else nil, reason
end
function M.supported(listing: any, effects: any): boolean
	local grant = listing.grant
	if grant.kind == "storageSlots" then
		return effects.warehouseSlots ~= nil
	elseif grant.kind == "cosmeticSet" then
		return grant.cosmeticSetId ~= nil and effects.skinSupported(grant.cosmeticSetId)
	elseif grant.kind == "subscriptionMonthly" then
		return effects.warehouseSlots ~= nil
			and (grant.cosmeticSetId == nil or effects.skinSupported(grant.cosmeticSetId))
	end
	return false
end
return M
