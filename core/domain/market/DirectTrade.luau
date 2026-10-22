--!strict
-- Same-server direct trade: each participant escrows one exact item stack plus currency.
-- Any offer change bumps the revision and clears both confirmations; both confirmations on
-- the same revision lock the trade for settlement. Pure state; the caller persists sides.
local Inventory = require("../inventory/Inventory")
local M = {}

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[key] = copy(child)
	end
	return out
end
M.copy = copy

function M.open(tradeId: string, from: string, to: string, facts: any): (any?, string?)
	if from == to then
		return nil, "SELF_TRADE"
	end
	if facts.sameServer ~= true then
		return nil, "DIFFERENT_SERVER"
	end
	if facts.busy == true then
		return nil, "TRADE_BUSY"
	end
	return {
		tradeId = tradeId,
		participants = { from, to },
		revision = 0,
		offers = { [from] = { coins = 0 }, [to] = { coins = 0 } },
		confirmed = {},
		status = "open",
	},
		nil
end

local function check(state: any, actor: string, revision: number?): string?
	if state.offers[actor] == nil then
		return "NOT_PARTICIPANT"
	end
	if state.status ~= "open" then
		return "TRADE_CLOSED"
	end
	if revision ~= nil and revision ~= state.revision then
		return "STALE_REVISION"
	end
	return nil
end

-- offer: { itemId?, quantity?, coins }; item is the exact stack (attributes included).
function M.offer(state: any, actor: string, revision: number, offer: any, wallet: any): (any?, string?)
	local refused = check(state, actor, revision)
	if refused then
		return nil, refused
	end
	local coins = offer.coins or 0
	if type(coins) ~= "number" or coins < 0 or coins % 1 ~= 0 or coins > (wallet.balance or 0) then
		return nil, "INSUFFICIENT_FUNDS"
	end
	local entry: any = { coins = coins }
	if offer.itemId ~= nil then
		local item = wallet.bag.items[offer.itemId]
		local quantity = offer.quantity or 0
		if not item or quantity < 1 or Inventory.available(wallet.bag, offer.itemId) < quantity then
			return nil, "INSUFFICIENT_ITEMS"
		end
		entry.item = copy(item)
		entry.item.quantity = quantity
	end
	local out = copy(state)
	out.offers[actor] = entry
	out.revision += 1
	out.confirmed = {}
	return out, nil
end

function M.confirm(state: any, actor: string, revision: number): (any?, string?)
	local refused = check(state, actor, revision)
	if refused then
		return nil, refused
	end
	local empty = true
	for _, entry in state.offers do
		empty = empty and entry.item == nil and entry.coins == 0
	end
	if empty then
		return nil, "EMPTY_TRADE"
	end
	local out = copy(state)
	out.confirmed[actor] = true
	local a, b = out.participants[1], out.participants[2]
	if out.confirmed[a] and out.confirmed[b] then
		out.status = "locked"
	end
	return out, nil
end

function M.cancel(state: any, actor: string, reason: string?): (any?, string?)
	if state.offers[actor] == nil then
		return nil, "NOT_PARTICIPANT"
	end
	if state.status == "settled" then
		return nil, "TRADE_SETTLED"
	end
	local out = copy(state)
	out.status, out.reason, out.confirmed = "cancelled", reason or "CANCELLED", {}
	return out, nil
end

-- Escrow step: take the actor's own offer out of their record (PREPARED -> DEBITED).
function M.debit(state: any, actor: string, data: any, catalog: any): (any?, string?)
	if state.status ~= "locked" then
		return nil, "TRADE_NOT_LOCKED"
	end
	local give = state.offers[actor]
	if data.balance < give.coins then
		return nil, "INSUFFICIENT_FUNDS"
	end
	local bag = Inventory.fromSave(data.inventory.bag, catalog)
	if give.item then
		local consumed, reason = Inventory.consume(bag, give.item.itemId, give.item.quantity, bag.version)
		if not consumed then
			return nil, if reason == "UNAVAILABLE" then "INSUFFICIENT_ITEMS" else reason
		end
		bag = consumed
	end
	local out = copy(data)
	out.inventory.bag = Inventory.save(bag)
	out.balance = data.balance - give.coins
	return out, nil
end

-- Credit step: install `from`'s escrowed offer into `actor`'s record. A refund credits an
-- actor's own offer back. Stacks keep catalog, quality, durability and attributes.
function M.credit(state: any, _actor: string, from: string, data: any, catalog: any): (any?, string?)
	local take = state.offers[from]
	if data.balance + take.coins > 1000000000 then
		return nil, "WALLET_FULL"
	end
	local bag = Inventory.fromSave(data.inventory.bag, catalog)
	if take.item then
		local received = copy(take.item)
		received.itemId = "trade:" .. state.tradeId .. ":" .. from
		local added, reason = Inventory.add(bag, catalog, received, bag.version)
		if not added then
			return nil, reason
		end
		bag = added
	end
	local out = copy(data)
	out.inventory.bag = Inventory.save(bag)
	out.balance = data.balance + take.coins
	return out, nil
end

function M.other(state: any, actor: string): string
	return if state.participants[1] == actor then state.participants[2] else state.participants[1]
end

return M
