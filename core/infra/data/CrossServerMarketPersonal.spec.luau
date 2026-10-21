--!strict
local Personal = require("./CrossServerMarketPersonal")
local Inventory = require("../../domain/inventory/Inventory")
local Catalog = require("../../domain/inventory/ItemCatalog")
local Data = require("../../domain/genre/SerializedData")
local function fixture(): (any, () -> any)
	local definitions = { { id = "wood", stackMax = 100, weightMilli = 1, maxDurabilityMilli = 0 } }
	local bag = Inventory.new("bag", { slots = 1, softWeightMilli = 100, hardWeightMilli = 100 })
	local item = {
		itemId = "wood-1",
		catalogId = "wood",
		quantity = 2,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = {},
	}
	bag = assert(Inventory.add(bag, Catalog.new(definitions), item, bag.version), "seed bag")
	local raw: any = {
		envelope = {
			genres = { ["survival-coop"] = { data = { balance = 100, inventory = { bag = Inventory.save(bag) } } } },
		},
	}
	local session = {
		personalTransaction = function(_actor, transform)
			raw = transform(Data.clone(raw))
			return true, Data.clone(raw)
		end,
		personalTransfer = function(_actor)
			return {
				profile = function()
					return { data = Data.clone(raw) }
				end,
			}
		end,
	}
	return Personal.new(session, definitions, { "wood" }),
		function()
			return raw.envelope.genres["survival-coop"].data
		end
end
return {
	["claims page at fifty rows and full bags preserve undelivered claims"] = function()
		local port, read = fixture()
		local ok = port.update("seller", function(view)
			for number = 1, 51 do
				view.market.claims["coins:" .. number] = { coins = 1 }
			end
			view.market.claims.item = {
				item = {
					itemId = "wood-2",
					catalogId = "wood",
					quantity = 1,
					qualityMilli = 1000,
					durabilityMilli = 0,
					attributes = {},
				},
			}
			return view
		end)
		assert(ok, "commit claims")
		assert(#read().market.pages == 2 and #read().market.pages[1] == 50, "fifty entry page")
		assert(read().market.claims == nil, "no inline claims dictionary")
		assert(not port.claim("seller", "item").ok, "full bag rejects pickup")
		assert(read().inventory.bag.items["wood-1"].quantity == 2, "existing bag untouched")
		assert(port.claim("seller", "coins:1").ok, "coins claim succeeds independently of bag")
		assert(not port.claim("seller", "coins:1").ok and read().balance == 101, "no duplicate credit")
	end,
	["reserved exact items never enter the market escrow projection"] = function()
		local port, read = fixture()
		-- Reserve through the persisted inventory; market must preserve this authority.
		local bag = read().inventory.bag
		bag.reservations.craft = { ["wood-1"] = 1 }
		local ok = port.update("seller", function(view)
			assert(view.items["wood-1"] == nil, "reserved item withheld")
			return view
		end)
		assert(ok and read().inventory.bag.reservations.craft["wood-1"] == 1, "reservation retained")
	end,
}
