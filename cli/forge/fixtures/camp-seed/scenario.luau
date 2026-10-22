--!strict
-- Native fixture operation: seed_bag adds a gathered-material stack to a joined
-- player's carried bag through the real Session personal transaction, standing in
-- for the gathering a scenario does not replay (camp project costs exceed the
-- starter kit by design).
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Job = require("../../../../core/domain/crafting/Job")
local Content: any = require("../../../../games/robango-island/src/shared/SurvivalContent")
local M = {}
M.operations = {
	seed_bag = function(ctx: any, step: any): string?
		local actor = ctx.playerOf(step)
		local ok, failure = ctx.session.personalTransaction(actor, function(raw)
			local data = raw.envelope.genres["survival-coop"].data
			local catalog = Job.catalog(Content)
			local bag = Inventory.fromSave(data.inventory.bag, catalog)
			bag = assert(Inventory.add(bag, catalog, {
				itemId = step.itemId,
				catalogId = step.item,
				quantity = step.quantity,
				qualityMilli = 1000,
				durabilityMilli = 0,
				attributes = { origin = "gathered" },
			}, bag.version))
			data.inventory.bag = Inventory.save(bag)
			return raw
		end)
		return if ok then nil else "seed_bag: " .. tostring(failure)
	end,
}
function M.new(_ctx: any): any
	return {}
end
return M
