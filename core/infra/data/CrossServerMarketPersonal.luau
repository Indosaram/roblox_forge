--!strict
-- Market views are projected inside the Session personal fence, never copied
-- into a second account key. Claims are owner-indexed pages of at most 50 rows.
local Data = require("../../domain/genre/SerializedData")
local Inventory = require("../../domain/inventory/Inventory")
local Catalog = require("../../domain/inventory/ItemCatalog")
local M = {}
function M.new(session: any, definitions: { any }, tradeable: { string }): any
	local rows, allowed = {}, {}
	for _, id in tradeable do
		allowed[id] = true
	end
	for _, item in definitions do
		table.insert(rows, {
			id = item.id,
			stackMax = item.stackMax,
			weightMilli = item.weightMilli,
			maxDurabilityMilli = item.maxDurabilityMilli,
		})
	end
	local catalog = Catalog.new(rows)
	local api = {}
	function api.update(actor: string, transform: (any) -> any): (boolean, any)
		local projected: any = nil
		local ok, reason = session.personalTransaction(actor, function(raw)
			local document: any = raw.envelope.genres["survival-coop"].data
			local bag = Inventory.fromSave(document.inventory.bag, catalog)
			local market = Data.clone(document.market or {
				markers = {},
				escrow = {},
				active = {},
				pages = {},
				applied = {},
			})
			market.claims = {}
			local items = Data.clone(bag.items)
			for id, item in items do
				-- Reserved, equipped, paid or noncatalog goods cannot enter escrow.
				if
					not allowed[item.catalogId]
					or Inventory.available(bag, id) ~= item.quantity
					or item.attributes.robuxPurchased == true
					or item.attributes.equipped == true
				then
					items[id] = nil
				end
			end
			local before = Data.clone(items)
			projected = transform({ items = items, coins = document.balance, market = market })
			assert(projected, "MARKET_ACCOUNT_REQUIRED")
			for id, item in before do
				local after = projected.items[id]
				local quantity = item.quantity - (if after then after.quantity else 0)
				if quantity > 0 then
					local consumed, failure = Inventory.consume(bag, id, quantity, bag.version)
					assert(consumed, failure)
					bag = consumed
				end
			end
			market = projected.market
			for id, claim in projected.market.claims do
				if not market.applied[id] then
					local page = market.pages[#market.pages]
					if not page or #page >= 50 then
						page = {}
						table.insert(market.pages, page)
					end
					table.insert(page, { id = id, value = Data.clone(claim) })
					market.applied[id] = true
				end
			end
			projected.market.claims = nil
			document.market = projected.market
			document.balance = projected.coins
			document.inventory.bag = Inventory.save(bag)
			return raw
		end)
		return ok, if ok then projected else reason
	end
	function api.claim(actor: string, id: string): any
		local outcome: any = { ok = false, reason = "CLAIM_UNAVAILABLE" }
		local ok, reason = session.personalTransaction(actor, function(raw)
			local document: any = raw.envelope.genres["survival-coop"].data
			local market = document.market
			if not market then
				return raw
			end
			for _, page in market.pages do
				for index, row in page do
					if row.id == id then
						local claim = row.value
						if claim.item then
							local bag = Inventory.fromSave(document.inventory.bag, catalog)
							local item = Data.clone(claim.item)
							-- A partial escrow may share its source id with the remainder.
							local held = bag.items[item.itemId]
							if held and Inventory.compatible(held, item) then
								item.quantity += held.quantity
								bag.items[item.itemId] = nil
							end
							local added, failure = Inventory.add(bag, catalog, item, bag.version)
							if not added then
								outcome = { ok = false, reason = failure }
								return raw
							end
							document.inventory.bag = Inventory.save(added)
						elseif document.balance + claim.coins <= 1e9 then
							document.balance += claim.coins
						else
							outcome = { ok = false, reason = "WALLET_FULL" }
							return raw
						end
						table.remove(page, index)
						outcome = { ok = true }
						return raw
					end
				end
			end
			return raw
		end)
		return if ok then outcome else { ok = false, reason = reason }
	end
	function api.snapshot(actor: string, pageNumber: number): any
		local port = session.personalTransfer(actor)
		if not port then
			return nil
		end
		local document = port.profile().data.envelope.genres["survival-coop"].data
		local market = document.market
		return {
			balance = document.balance,
			items = Data.clone(document.inventory.bag.items),
			claims = if market then Data.clone(market.pages[pageNumber] or {}) else {},
			page = pageNumber,
			pages = if market then #market.pages else 0,
			active = if market then Data.clone(market.active) else {},
		}
	end
	return api
end
return M
