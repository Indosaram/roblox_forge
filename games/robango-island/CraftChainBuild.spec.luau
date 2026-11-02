--!strict
local Journey = require("./Journey.fixture")
local Inventory = require("../../core/domain/inventory/Inventory")
local Catalog = require("../../core/domain/inventory/ItemCatalog")
local Content: any = require("./src/shared/SurvivalContent")

return {
	["home Build pays the carried kit advertised by the shipped client"] = function()
		local host = Journey.new()
		host.enter("home", { x = 0, y = 5, z = -10 })
		local stocked, stockReason = host.session.personalTransaction(Journey.ACTOR, function(raw: any)
			local data = raw.envelope.genres["survival-coop"].data
			local item = {
				itemId = "kit",
				catalogId = "tanning-frame-kit",
				quantity = 1,
				qualityMilli = 1000,
				durabilityMilli = 0,
				attributes = {},
			}
			data.inventory.bag =
				assert(Inventory.add(data.inventory.bag, Catalog.new(Content.items), item, data.inventory.bag.version))
			return raw
		end)
		assert(stocked, tostring(stockReason))
		local state = host.session.snapshot(Journey.ACTOR).survivalSettlement
		local result = host.command("settlement-reserve", {
			"tanning-frame",
			8,
			1,
			0,
			state.settlement.version,
			state.warehouse.version,
			state.settlement.membershipRevision,
		})
		assert(result.ok, tostring(result.reason))
		state = host.session.snapshot(Journey.ACTOR).survivalSettlement
		local reservationId = next(state.settlement.reservations)
		assert(reservationId ~= nil, "reserve created placement")
		result = host.command("settlement-place", { reservationId, state.settlement.version, state.warehouse.version })
		assert(result.ok, tostring(result.reason))
		state = host.session.snapshot(Journey.ACTOR).survivalSettlement
		local placed = false
		for _, structure in state.settlement.structures do
			placed = placed or structure.definition.id == "tanning-frame"
		end
		assert(placed, "kit becomes a real structure")
	end,
}
