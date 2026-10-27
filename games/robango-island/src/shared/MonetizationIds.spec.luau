--!strict
-- Deploy-injected product ids replace the staging defaults per environment, and a key the
-- environment does not carry becomes 0 so another environment's product is never prompted.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Catalog: any = require("./MonetizationCatalog")
local Ids = require("./MonetizationIds")
local deploy = require("../../../../cli/forge/commands/deploy")

local function ids(catalog: any): { [string]: any }
	local out = {}
	for _, section in { "gamepasses", "products", "subscriptions" } do
		for _, listing in catalog[section] do
			out[listing.key] = listing.id
		end
	end
	return out
end

return {
	["without an override the staging catalog is returned unchanged"] = function()
		assert(Ids.apply(Catalog, nil) == Catalog, "same table")
	end,
	["an override replaces every id and keeps everything else"] = function()
		local applied = Ids.apply(Catalog, {
			routeGuildPatron = 11,
			wideWarehouse = 12,
			skinRidgeStriderGold = 13,
			routeGuildMonthly = "EXP-14",
		})
		local got = ids(applied)
		assert(got.routeGuildPatron == 11 and got.wideWarehouse == 12, "gamepasses")
		assert(got.skinRidgeStriderGold == 13 and got.routeGuildMonthly == "EXP-14", "product and subscription")
		assert(applied.products[1].price == Catalog.products[1].price, "price kept")
		assert(Catalog.products[1].id == 3720013569, "source catalog not mutated")
	end,
	["a key the override lacks becomes 0, never the staging id"] = function()
		local got = ids(Ids.apply(Catalog, { routeGuildPatron = 11 }))
		assert(got.routeGuildPatron == 11, "set")
		assert(got.wideWarehouse == 0 and got.skinRidgeStriderGold == 0 and got.routeGuildMonthly == 0, "unset -> 0")
	end,
	["deploy.yml maps staging to the catalog ids and production to unset references"] = function()
		local file = serde.decode("yaml", fs.readFile("games/robango-island/deploy.yml"))
		local staging = deploy.monetizationIds(file, "staging", {}) :: { [string]: any }
		local expected = ids(Catalog)
		for key, id in expected do
			assert(staging[key] == id, "staging " .. key)
		end
		local production = deploy.monetizationIds(file, "production", {}) :: { [string]: any }
		for key in expected do
			assert(production[key] == 0, "unset production " .. key .. " is 0")
		end
		local set = deploy.monetizationIds(file, "production", {
			FORGE_PRODUCTION_PRODUCT_ROUTE_GUILD_PATRON = "21",
			FORGE_PRODUCTION_PRODUCT_ROUTE_GUILD_MONTHLY = "EXP-22",
		}) :: { [string]: any }
		assert(set.routeGuildPatron == 21 and set.routeGuildMonthly == "EXP-22", "references resolve")
	end,
}
