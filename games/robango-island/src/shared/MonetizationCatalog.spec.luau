--!strict
-- The runtime catalog must equal game.yml `monetization` (the source `forge deploy` and `forge econ`
-- read) and pass the ADR-07 rules MonetizationExtension.configure enforces at server start.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local CatalogCore = require("../../../../core/infra/monetization/Catalog")
local Mounts = require("../../../../genres/survival-coop/module/Mounts")
local Catalog = require("./MonetizationCatalog")
local Taming = require("./TamingConfig")

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
	["runtime catalog equals game.yml monetization"] = function()
		local game = serde.decode("yaml", fs.readFile("games/robango-island/game.yml"))
		assert(type(game.monetization) == "table", "game.yml declares monetization")
		assert(equal(game.monetization, Catalog), "MonetizationCatalog.luau drifted from game.yml monetization")
	end,
	["catalog passes core validate and the ADR-07 lint"] = function()
		local ok, reason = CatalogCore.validate(Catalog)
		assert(ok, tostring(reason))
		local violations = CatalogCore.lint(Catalog)
		assert(#violations == 0, table.concat(violations, "; "))
	end,
	["unregistered items keep id 0 and only extension-granted kinds are sold"] = function()
		local supported = { storageSlots = true, cosmeticSet = true, subscriptionMonthly = true }
		for _, section in { Catalog.gamepasses or {}, Catalog.products or {}, Catalog.subscriptions or {} } do
			for _, listing in section do
				assert(type(listing.id) == "number" and listing.id >= 0 and listing.id % 1 == 0, listing.key)
				assert(supported[listing.grant.kind], "grant the extension cannot apply: " .. listing.key)
			end
		end
	end,
	["cosmetic products name a mount skin the taming policy declares"] = function()
		for _, listing in Catalog.products or {} do
			if listing.grant.kind == "cosmeticSet" then
				local skin = (Taming.mounts.skins :: any)[listing.grant.cosmeticSetId]
				assert(
					skin ~= nil and skin.paid == true,
					"unknown paid skin: " .. tostring(listing.grant.cosmeticSetId)
				)
			end
		end
		assert(Mounts ~= nil, "mounts module loads")
	end,
}
