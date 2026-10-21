--!strict
-- Durable universe-wide book. update is one record transaction (DataStore
-- UpdateAsync semantics); index is advisory (MemoryStore semantics). Neither
-- callback may yield or perform another record transaction.
local Ledger = require("../command/Ledger")
local M = {}
export type Ports = {
	update: (string, (any) -> any) -> (boolean, any),
	index: (string, any) -> (),
	search: (string) -> { any },
}
local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, entry in value do
		result[key] = copy(entry)
	end
	return result
end
local function integer(n: any, low: number, high: number): boolean
	return type(n) == "number" and n % 1 == 0 and n >= low and n <= high
end
local function text(s: any): boolean
	return type(s) == "string" and #s > 0 and #s <= 100 and not string.find(s, "%c")
end
local function account(old: any): any
	assert(old ~= nil, "ACCOUNT_NOT_PROVISIONED")
	old.market = old.market or { markers = {}, escrow = {}, active = {}, claims = {} }
	return old
end
function M.new(ports: Ports): any
	local api = {}
	local function read(key: string): any
		local ok, value = ports.update(key, function(old)
			return old
		end)
		return if ok then value else nil
	end
	local function change(key: string, transform: (any) -> any): any
		local ok, value = ports.update(key, function(old)
			local nextValue = transform(copy(old))
			if nextValue ~= nil then
				nextValue.schemaVersion = 1
				nextValue.revision = (if old then old.revision or 0 else 0) + 1
			end
			return nextValue
		end)
		return if ok then value else nil
	end
	function api.search(catalogId: string): { any }
		return ports.search("universe:" .. catalogId)
	end
	function api.quote(id: string): any
		return read("listing:" .. id)
	end
	function api.recover(id: string, now: number): any
		local key = "listing:" .. id
		local listing = read(key)
		if not listing then
			return { ok = false, reason = "pending" }
		end
		local sellerKey = "player:" .. listing.seller
		if listing.state == "PREPARED" then
			local seller = change(sellerKey, function(old)
				old = account(old)
				if old.market.markers[id .. ":list"] then
					return old
				end
				local count = 0
				for _ in old.market.active do
					count += 1
				end
				local item = old.items[listing.itemId]
				if
					count >= 20
					or not item
					or item.catalogId ~= listing.catalogId
					or item.quantity < listing.quantity
					or item.robuxPurchased
				then
					old.market.markers[id .. ":list"] = "DECLINED"
					return old
				end
				local escrow = copy(item)
				escrow.quantity = listing.quantity
				old.market.escrow[id] = escrow
				item.quantity -= listing.quantity
				if item.quantity == 0 then
					old.items[listing.itemId] = nil
				end
				old.market.active[id] = true
				old.market.markers[id .. ":list"] = "DEBITED"
				return old
			end)
			if not seller then
				return { ok = false, reason = "pending" }
			end
			listing = change(key, function(old)
				if old.state == "PREPARED" then
					old.state = if seller.market.markers[id .. ":list"] == "DEBITED" then "ACTIVE" else "ABORTED"
				end
				return old
			end)
			if not listing then
				return { ok = false, reason = "pending" }
			end
		end
		if listing.state == "ACTIVE" and now >= listing.expiresAt then
			listing = change(key, function(old)
				if old.state == "ACTIVE" then
					old.state = "RETURNING"
				end
				return old
			end)
			if not listing then
				return { ok = false, reason = "pending" }
			end
		end
		if listing.state == "RESERVED" then
			local operation = listing.operation
			local buyer = change("player:" .. listing.buyer, function(old)
				old = account(old)
				if old.market.markers[operation] then
					return old
				end
				if old.coins < listing.price then
					old.market.markers[operation] = "DECLINED"
				else
					old.coins -= listing.price
					old.market.markers[operation] = "DEBITED"
				end
				return old
			end)
			if not buyer then
				return { ok = false, reason = "pending" }
			end
			if buyer.market.markers[operation] == "DECLINED" then
				listing = change(key, function(old)
					if old.operation == operation then
						old.state = "ACTIVE"
						old.rejected[operation] = true
					end
					return old
				end)
				return { ok = false, reason = if listing then "insufficient_funds" else "pending" }
			end
			local seller = read(sellerKey)
			if not seller then
				return { ok = false, reason = "pending" }
			end
			local item = seller.market.escrow[id]
			buyer = change("player:" .. listing.buyer, function(old)
				old = account(old)
				if old.market.markers[operation] == "DEBITED" then
					assert(item, "ESCROW_MISSING")
					old.market.claims[operation .. ":0"] = { item = copy(item) }
					old.market.markers[operation] = "CREDITED"
				end
				return old
			end)
			if not buyer then
				return { ok = false, reason = "pending" }
			end
			-- If delivery committed before a crash, its marker wins over coordinator state.
			seller = change(sellerKey, function(old)
				old = account(old)
				if old.market.markers[operation] ~= "COMMITTED" then
					old.market.claims[operation .. ":1"] = { coins = listing.price - listing.fee }
					old.market.escrow[id] = nil
					old.market.active[id] = nil
					old.market.markers[operation] = "COMMITTED"
				end
				return old
			end)
			if not seller then
				return { ok = false, reason = "pending" }
			end
			listing = change(key, function(old)
				if old.operation == operation then
					old.state = "SOLD"
				end
				return old
			end)
		elseif listing.state == "RETURNING" then
			local seller = change(sellerKey, function(old)
				old = account(old)
				if old.market.markers[id .. ":return"] == nil then
					old.market.claims[id .. ":return:0"] = { item = old.market.escrow[id] }
					old.market.escrow[id] = nil
					old.market.active[id] = nil
					old.market.markers[id .. ":return"] = "COMMITTED"
				end
				return old
			end)
			if not seller then
				return { ok = false, reason = "pending" }
			end
			listing = change(key, function(old)
				old.state = "RETURNED"
				return old
			end)
		end
		if not listing then
			return { ok = false, reason = "pending" }
		end
		ports.index("universe:" .. listing.catalogId, copy(listing))
		return { ok = listing.state ~= "ABORTED", data = listing }
	end
	function api.list(
		actor: string,
		requestId: string,
		itemId: string,
		quantity: number,
		price: number,
		now: number
	): any
		if
			not text(actor)
			or not text(requestId)
			or not text(itemId)
			or not integer(quantity, 1, 1000000)
			or not integer(price, 1, 1000000)
		then
			return { ok = false, reason = "invalid_listing" }
		end
		local id = actor .. ":" .. requestId
		local seller = read("player:" .. actor)
		local item = if seller then seller.items[itemId] else nil
		local binding = Ledger.canonical({
			actor = actor,
			requestId = requestId,
			itemId = itemId,
			quantity = quantity,
			price = price,
		})
		local listing = change("listing:" .. id, function(old)
			if old then
				return old
			end
			if not item then
				return nil
			end
			return {
				id = id,
				seller = actor,
				itemId = itemId,
				catalogId = item.catalogId,
				quantity = quantity,
				price = price,
				fee = math.floor(price * 5 / 100),
				expiresAt = now + 86400,
				binding = binding,
				state = "PREPARED",
				rejected = {},
			}
		end)
		if not listing then
			return { ok = false, reason = "pending" }
		end
		if listing.binding ~= binding then
			return { ok = false, reason = "conflict" }
		end
		return api.recover(id, now)
	end
	function api.buy(actor: string, requestId: string, id: string, price: number, now: number): any
		if not text(actor) or not text(requestId) then
			return { ok = false, reason = "invalid_request" }
		end
		local operation = actor .. ":" .. requestId
		local binding = Ledger.canonical({ id = id, price = price })
		local receipt = change("operation:" .. operation, function(old)
			return old or { binding = binding }
		end)
		if not receipt then
			return { ok = false, reason = "pending" }
		end
		if receipt.binding ~= binding then
			return { ok = false, reason = "conflict" }
		end
		local listing = change("listing:" .. id, function(old)
			if
				old
				and old.state == "ACTIVE"
				and now < old.expiresAt
				and old.seller ~= actor
				and old.price == price
				and not old.rejected[operation]
			then
				old.state = "RESERVED"
				old.buyer = actor
				old.operation = operation
			end
			return old
		end)
		if not listing then
			return { ok = false, reason = "pending" }
		end
		if
			listing.operation ~= operation
			or listing.price ~= price
			or (listing.state ~= "RESERVED" and listing.state ~= "SOLD")
		then
			return { ok = false, reason = "listing_unavailable" }
		end
		return api.recover(id, now)
	end
	function api.cancel(actor: string, id: string, now: number): any
		local listing = change("listing:" .. id, function(old)
			if old and old.seller == actor and old.state == "ACTIVE" then
				old.state = "RETURNING"
			end
			return old
		end)
		if not listing or listing.seller ~= actor or (listing.state ~= "RETURNING" and listing.state ~= "RETURNED") then
			return { ok = false, reason = "listing_unavailable" }
		end
		return api.recover(id, now)
	end
	return api
end
return M
