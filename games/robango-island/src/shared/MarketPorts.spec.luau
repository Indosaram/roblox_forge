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
	["catalog ids exist in content.yml and are never Robux items"] = function()
		local content = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
		local items: { [string]: any } = {}
		for _, item in content.items do
			items[item.id] = item
		end
		local paid: { [string]: boolean } = {}
		for _, listing in Catalog.products or {} do
			paid[listing.grant.cosmeticSetId or ""] = true
		end
		for _, id in Ports.CATALOG_IDS do
			local item = items[id]
			assert(item ~= nil, "unknown content item: " .. id)
			assert(not paid[id], "Robux-granted id: " .. id)
		end
	end,
	["tradeable set is every content item except quest-bound, bound and retired ids"] = function()
		local content = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
		local ids: { [string]: boolean } = {}
		for _, id in Ports.CATALOG_IDS do
			assert(not ids[id], "duplicate id: " .. id)
			ids[id] = true
		end
		for _, id in { "leather", "copper", "axe-t1", "berry-meal", "iron-ore", "bow-t1", "cold-top" } do
			assert(ids[id], "processed goods and gear trade: " .. id)
		end
		-- Quest-only ledger items (quests spec) and the retired reed/samphire aliases (world spec).
		for _, id in
			{
				"bandage",
				"cord",
				"signal-lens",
				"relief-unit",
				"survey-sample",
				"birch-bark",
				"rw-journal-seal-1",
				"reed",
				"samphire",
				"practice-stitch",
			}
		do
			assert(not ids[id], "never tradeable: " .. id)
		end
		local expected = 0
		for _, item in content.items do
			local blocked = false
			for _, tag in item.tags or {} do
				blocked = blocked or Ports.UNTRADEABLE_TAGS[tag] == true
			end
			assert((ids[item.id] == true) == not blocked, "derived from content tags: " .. item.id)
			expected += if blocked then 0 else 1
		end
		assert(#Ports.CATALOG_IDS == expected, "exactly the untagged content items")
	end,
	["market search filters the large catalog by name and category with bounded pages"] = function()
		local Panel = require("../../../../genres/survival-coop/module/CrossServerMarketPanel")
		local names = { wood = "Wood", leather = "Leather", ["axe-t1"] = "Axe T1", berry = "Bramble Berry" }
		local categories = { wood = "material", leather = "material", ["axe-t1"] = "gear", berry = "food" }
		local ids = { "wood", "leather", "axe-t1", "berry" }
		local function name(id: string): string
			return names[id]
		end
		local function category(id: string): string
			return categories[id]
		end
		local hit = Panel.browse(ids, "ber", "all", 1, name, category)
		assert(#hit.ids == 1 and hit.ids[1] == "berry" and hit.pages == 1, "query matches the display name")
		local gear = Panel.browse(ids, "", "gear", 1, name, category)
		assert(#gear.ids == 1 and gear.ids[1] == "axe-t1", "category filter")
		local all = Ports.CATALOG_IDS
		local first = Panel.browse(all, "", "all", 1, function(id)
			return id
		end, function()
			return "material"
		end)
		assert(#first.ids == Panel.PAGE_SIZE and first.pages == math.ceil(#all / Panel.PAGE_SIZE), "paged")
		local last = Panel.browse(all, "", "all", 999, function(id)
			return id
		end, function()
			return "material"
		end)
		assert(last.page == first.pages and #last.ids > 0, "page clamps to the last page")
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
		assert(#config.catalogIds == #Ports.CATALOG_IDS and #config.catalogIds > 100, "derived catalog")
	end,
}
