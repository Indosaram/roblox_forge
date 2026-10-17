--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Extension = require("./ContractsExtension")
local Content = require("../../../core/domain/survival/Content")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")
local Memory = require("../../../core/infra/data/MemoryBackend")

local function content(): any
	local document = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
	return assert(Content.canonicalize(document))
end

local function bagWith(document: any, items: { { string | number } }): any
	local catalog = Job.catalog(document)
	local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for index, entry in items do
		local definition = catalog[entry[1] :: string]
		bag = assert(Inventory.add(bag, catalog, {
			itemId = "seed-" .. index,
			catalogId = entry[1] :: string,
			quantity = entry[2] :: number,
			qualityMilli = 1000,
			durabilityMilli = if definition.maxDurabilityMilli then definition.maxDurabilityMilli else 0,
			attributes = {},
		}, bag.version))
	end
	return { inventory = Inventory.save(bag), itemTransfers = { version = 1, receipts = {} } }
end

local function quantityOf(view: any, catalogId: string): number
	local total = 0
	for _, item in view.inventory.items do
		if item.catalogId == catalogId then
			total += item.quantity
		end
	end
	return total
end

return {
	["exchange consumes the delivery and grants the reward exactly once"] = function()
		local document = content()
		local catalog = Job.catalog(document)
		local view = bagWith(document, { { "wood", 5 } })
		local out, err = Extension.exchange(
			view,
			catalog,
			{ { item = "wood", quantity = 3 } },
			{ { item = "cord", quantity = 1 } },
			"ct:r1"
		)
		assert(out, tostring(err))
		assert(quantityOf(out, "wood") == 2 and quantityOf(out, "cord") == 1, "consumed and granted")
		local again = assert(
			Extension.exchange(
				out,
				catalog,
				{ { item = "wood", quantity = 3 } },
				{ { item = "cord", quantity = 1 } },
				"ct:r1"
			)
		)
		assert(quantityOf(again, "wood") == 2 and quantityOf(again, "cord") == 1, "marker makes a replay a no-op")
	end,
	["exchange refuses when the bag does not hold the delivery"] = function()
		local document = content()
		local catalog = Job.catalog(document)
		local out, err = Extension.exchange(
			bagWith(document, { { "wood", 1 } }),
			catalog,
			{ { item = "wood", quantity = 3 } },
			{},
			"ct:r2"
		)
		assert(out == nil and err == "INSUFFICIENT_ITEMS", tostring(err))
	end,
	["a pack without a contracts section leaves the extension disabled"] = function()
		local document = content()
		document.contracts = nil
		local built = Extension.factory({
			content = document,
			store = function()
				return nil :: any
			end,
		})
		assert(built == nil, "disabled without a catalog")
		assert(Memory.new() ~= nil, "backend constructible")
	end,
	["the extension handles exactly its declared actions"] = function()
		local document = content()
		local built = assert(Extension.factory({
			content = document,
			store = function()
				return { acquire = function() end } :: any
			end,
			nowMillis = function()
				return 0
			end,
			members = function()
				return {}
			end,
			personalTransfer = function()
				return nil
			end,
		}))
		for _, action in
			{ "contract-accept", "contract-deliver", "contract-swap", "contract-claim", "tutorial-skip-arrival" }
		do
			assert(built.handles("survival-coop:" .. action), action)
		end
		assert(not built.handles("survival-coop:gather") and not built.handles("contract-accept"), "foreign ids")
	end,
}
