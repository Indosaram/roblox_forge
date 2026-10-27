--!strict
-- Environment product ids for the monetization catalog. `forge deploy` injects the target
-- environment's ids (deploy.yml `environments.<env>.monetization`, keyed by the catalog `key`) as
-- ServerStorage.ForgeMonetizationIds. MonetizationCatalog keeps the staging ids as defaults.
-- With an override, every listing takes its id from the override, and a key the override does
-- not carry becomes 0, so another environment's product is never prompted.

local M = {}

local SECTIONS = { "gamepasses", "products", "subscriptions" }

--- Returns a copy of `catalog` with ids from `ids`; returns `catalog` itself when `ids` is nil.
function M.apply(catalog: any, ids: { [string]: any }?): any
	if ids == nil then
		return catalog
	end
	local out: any = {}
	for section, listings in catalog do
		if table.find(SECTIONS, section) and type(listings) == "table" then
			local copied = {}
			for _, listing in listings do
				local entry = table.clone(listing)
				local id = ids[listing.key]
				entry.id = if id == nil or id == "" then 0 else id
				table.insert(copied, entry)
			end
			out[section] = copied
		else
			out[section] = listings
		end
	end
	return out
end

return M
