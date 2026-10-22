--!strict
-- The runtime catalog must equal game.yml `monetization` (the source `forge deploy` and `forge econ`
-- read) and pass the ADR-07 rules MonetizationExtension.configure enforces at server start.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local CatalogCore = require("../../../../core/infra/monetization/Catalog")
local Mounts = require("../../../../genres/survival-coop/module/Mounts")
local Catalog = require("./MonetizationCatalog")
local Taming = require("./TamingConfig")
local Content: any = require("./SurvivalContent")
local HomeContent = require("../../../../core/domain/home/HomeContent")
local Home = require("../../../../core/domain/home/HomeState")

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
	["ids are 0 or registered Roblox ids and only extension-granted kinds are sold"] = function()
		local supported = { storageSlots = true, cosmeticSet = true, subscriptionMonthly = true }
		for _, section in { Catalog.gamepasses or {}, Catalog.products or {} } do
			for _, listing in section do
				assert(type(listing.id) == "number" and listing.id >= 0 and listing.id % 1 == 0, listing.key)
				assert(supported[listing.grant.kind], "grant the extension cannot apply: " .. listing.key)
			end
		end
		-- An experience subscription id is the `EXP-<digits>` string PromptSubscriptionPurchase takes.
		for _, listing in Catalog.subscriptions or {} do
			assert(
				listing.id == 0 or (type(listing.id) == "string" and string.match(listing.id, "^EXP%-%d+$") ~= nil),
				listing.key
			)
			assert(supported[listing.grant.kind], "grant the extension cannot apply: " .. listing.key)
		end
	end,
	["Patron Pass grants +2 terrain-preset slots and Wide Warehouse does not"] = function()
		local grants: { [string]: any } = {}
		for _, listing in Catalog.gamepasses do
			grants[listing.key] = listing.grant
		end
		assert(grants.routeGuildPatron.presetSlots == 2, "patron grants two preset slots")
		assert(grants.wideWarehouse.presetSlots == nil, "wide warehouse grants no preset slots")
		local rules = HomeContent.rules(Content)
		assert(
			rules.presetGrants.routeGuildPatron == grants.routeGuildPatron.presetSlots,
			"home rules mirror the grant"
		)
		local function home(entitlements: { [string]: boolean }): any
			local state = Home.new("7", rules, 1)
			local ctx = { rules = rules, facts = {}, entitlements = entitlements }
			return assert(Home.apply(state, "7", state.homeId, "capacity", {}, ctx)), ctx
		end
		local free, freeCtx = home({})
		local wide, wideCtx = home({ wideWarehouse = true })
		local patron, patronCtx = home({ routeGuildPatron = true })
		assert(Home.presetSlots(rules, {}) == 1 and free.presetSlots == nil, "free home: one preset slot")
		assert(Home.presetSlots(rules, { wideWarehouse = true }) == 1 and wide.presetSlots == nil, "wide: one slot")
		assert(patron.presetSlots == 3, "patron: base 1 + 2 preset slots")
		assert(wide.storageSlots == 30 and patron.storageSlots == 30, "both passes still grant warehouse +10")
		for _, case in { { free, freeCtx }, { wide, wideCtx } } do
			local refused, reason = Home.apply(case[1], "7", case[1].homeId, "preset", { preset = 2 }, case[2])
			assert(refused == nil and reason == "PRESET_LOCKED", "preset 2 is locked without the patron pass")
		end
		local picked = assert(Home.apply(patron, "7", patron.homeId, "preset", { preset = 3 }, patronCtx))
		assert(picked.terrainPreset == 3, "patron owner picks preset 3")
		local _, invalid = Home.apply(patron, "7", patron.homeId, "preset", { preset = 4 }, patronCtx)
		assert(invalid == "PRESET_LOCKED", "no fourth preset")
		local _, visitor = Home.apply(patron, "8", patron.homeId, "preset", { preset = 1 }, patronCtx)
		assert(visitor == "FORBIDDEN", "only the owner picks the preset")
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
