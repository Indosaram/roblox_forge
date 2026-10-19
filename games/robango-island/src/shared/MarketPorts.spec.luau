--!strict
-- MarketPorts: the robango-island Market wiring maps Players facts onto Market accounts and trades
-- only gathered raw goods; escrow and Coins settlement are the genre extension's.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local MarketExtension = require("../../../../genres/survival-coop/module/MarketExtension")
local Catalog = require("./MonetizationCatalog")
local Ports = require("./MarketPorts")

local DAY = 86400

local function deps(overrides: { [string]: any }?): Ports.Deps
	local value: any = {
		accountAgeDays = function(_actor: string)
			return 30
		end,
		sessionSeconds = function(_actor: string, _now: number)
			return 600
		end,
		tutorialComplete = function(_actor: string)
			return true
		end,
	}
	for key, item in (overrides or {}) :: { [string]: any } do
		value[key] = item
	end
	return value
end

return {
	["catalog ids are gathered raw goods from content.yml and never Robux items"] = function()
		local content = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
		local items: { [string]: any } = {}
		for _, item in content.items do
			items[item.id] = item
		end
		local crafted: { [string]: boolean } = {}
		for _, recipe in content.recipes do
			for _, output in recipe.outputs do
				crafted[output.item] = true
			end
		end
		local paid: { [string]: boolean } = {}
		for _, listing in Catalog.products or {} do
			paid[listing.grant.cosmeticSetId or ""] = true
		end
		for _, id in Ports.CATALOG_IDS do
			local item = items[id]
			assert(item ~= nil, "unknown content item: " .. id)
			assert(not crafted[id], "crafted goods are not raw: " .. id)
			assert(item.maxDurabilityMilli == nil, "tools are not traded: " .. id)
			assert(not paid[id], "Robux-granted id: " .. id)
		end
	end,
	["account maps AccountAge, session play time and tutorial"] = function()
		local now = 100 * DAY
		local account = assert(Ports.account(deps(), "7", now))
		assert(account.createdAt == now - 30 * DAY and account.playSeconds == 600, "age and play")
		assert(account.tutorialComplete, "tutorial")
		assert(Ports.account(
			deps({
				accountAgeDays = function()
					return nil
				end,
			}),
			"7",
			now
		) == nil, "absent player is unknown")
	end,
	["config is accepted by MarketExtension and trades only Coins"] = function()
		local config = Ports.config(deps())
		MarketExtension.configure(config)
		MarketExtension.configure(nil)
		assert(config.market.currency == "Coins", "pack currency")
		assert(config.transfer == nil and config.wallet == nil, "escrow and wallet belong to the genre")
		assert(#config.catalogIds == 16, "16 raw goods")
	end,
}
