--!strict
local Journey = require("./Journey.fixture")
local Inventory = require("../../core/domain/inventory/Inventory")
local Catalog = require("../../core/domain/inventory/ItemCatalog")
local Content: any = require("./src/shared/SurvivalContent")

return {
	["closed-world tagged stations are not replicated into the next island client"] = function()
		local host = Journey.new()
		host.enter("rw.harbor")
		local workspace = host.engine.game:GetService("Workspace")
		local stale = nil
		for _, part in workspace:FindFirstChild("ForgeRoleWorld"):GetDescendants() do
			if part:IsA("BasePart") then
				stale = part
				break
			end
		end
		assert(stale ~= nil, "role world contains a part")
		stale:SetAttribute("ForgeStationKind", "campfire")
		stale:SetAttribute("ForgeStationId", "closed-world-fire")
		host.engine.game:GetService("CollectionService"):AddTag(stale, "ForgeSurvivalStation")
		stale:Destroy()
		local h = host.render()
		for _, part in h.workspace:GetDescendants() do
			assert(
				part:GetAttribute("ForgeStationId") ~= "closed-world-fire",
				"detached station must not reappear on the harbor"
			)
		end
	end,
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
