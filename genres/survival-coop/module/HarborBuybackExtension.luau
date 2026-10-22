--!strict
-- harborPolicy: the harbor buys raw units for Coins (daily cap); a repair operation enables
-- item-repair at Job.repairCost. One atomic bag+Coins write each.
local Shared = require("../../../core/domain/genre/Contract")
local Buyback = require("../../../core/domain/market/Buyback")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")
local Data = require("../../../core/domain/genre/SerializedData")

local M = {}
M.SELL = "survival-coop:harbor-sell"
M.REPAIR = "survival-coop:item-repair"
local GENRE = "survival-coop"
local HARBOR_LAYOUT = "rw.harbor"
local MAX_BALANCE = 1e9

--- Buyback policy from content, or nil when the pack declares none.
function M.policy(content: any): Buyback.Policy?
	local raw = content and content.harborPolicy
	if raw == nil then
		return nil
	end
	local prices: { [string]: number } = {}
	for _, row in raw.buyback do
		prices[row.item] = row.price
	end
	return { prices = prices, dailyUnits = raw.dailyUnits, daySeconds = raw.daySeconds }
end

local function bagAt(envelope: any, path: { string }): any?
	local node = envelope
	for _, key in path do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	return if type(node) == "table" and type(node.items) == "table" then node else nil
end

local function setBag(envelope: any, path: { string }, bag: any)
	local node = envelope
	for index = 1, #path - 1 do
		node = node[path[index]]
	end
	node[path[#path]] = bag
end

function M.factory(ctx: any): (Shared.Extension & { close: (() -> Shared.Result)? })?
	local policy = M.policy(ctx.content)
	local repair: any = nil
	for _, operation in ctx.content.operations or {} do
		repair = if operation.kind == "repair" then operation else repair
	end
	if policy == nil and repair == nil then
		return nil
	end
	local catalog = Job.catalog(ctx.content)
	local function atHarbor(): boolean
		local layout = if ctx.world then ctx.world.layout else nil
		return layout == nil or layout.id == HARBOR_LAYOUT
	end
	local extension = {
		id = "harbor-buyback",
		handles = function(action: string): boolean
			return action == M.SELL and policy ~= nil or action == M.REPAIR and repair ~= nil
		end,
		command = function(actor, action, args, _context, _origin, admit): Shared.Result
			local catalogId: any, quantity: any, repairing = args[1], args[2], action == M.REPAIR
			if not repairing and (policy :: any).prices[catalogId] == nil then
				return { ok = false, reason = "NOT_BOUGHT" }
			elseif not repairing and not atHarbor() then
				return { ok = false, reason = "NOT_AT_HARBOR" }
			end
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local port = ctx.personalTransfer(actor)
			if not port then
				return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
			end
			local path = port.personal:inventoryPath()
			local now = ctx.now()
			local outcome: Shared.Result = { ok = false, reason = "SELL_FAILED" }
			local token, err = port.personal:update(port.profile(), function(view)
				local work = Data.clone(view)
				local slice = work.envelope.genres[GENRE].data
				local saved = bagAt(work.envelope, path)
				if saved == nil or type(slice.balance) ~= "number" then
					outcome = { ok = false, reason = "WALLET_UNAVAILABLE" }
					return view
				end
				if repairing then
					local bag = Inventory.fromSave(saved, catalog)
					local fixed, refused = Job.repair(bag, catalog, catalogId, bag.version)
					local cost = if fixed then Job.repairCost(repair, bag.items[catalogId].catalogId) else 0
					outcome = { ok = fixed ~= nil and slice.balance >= cost, reason = refused or "INSUFFICIENT_FUNDS" }
					if not outcome.ok then
						return view
					end
					setBag(work.envelope, path, Inventory.save(fixed :: any))
					slice.balance -= cost
					return work
				end
				local coins, nextState, refused =
					Buyback.sell(policy :: any, slice.harborBuyback, catalogId, quantity, now)
				if coins == nil or nextState == nil then
					outcome = { ok = false, reason = refused }
					return view
				end
				if slice.balance + coins > MAX_BALANCE then
					outcome = { ok = false, reason = "WALLET_FULL" }
					return view
				end
				-- Stable order; reserved and Robux-bought units are never sold.
				local bag = Inventory.fromSave(saved, catalog)
				local ids: { string } = {}
				for id, item in bag.items do
					if item.catalogId == catalogId and item.attributes.robuxPurchased ~= true then
						table.insert(ids, id)
					end
				end
				table.sort(ids)
				local remaining = quantity
				for _, id in ids do
					local take = math.min(remaining, Inventory.available(bag, id))
					if take > 0 then
						bag = assert(Inventory.consume(bag, id, take, bag.version))
						remaining -= take
					end
				end
				if remaining > 0 then
					outcome = { ok = false, reason = "INSUFFICIENT_ITEMS" }
					return view
				end
				setBag(work.envelope, path, Inventory.save(bag))
				slice.balance += coins
				slice.harborBuyback = nextState
				outcome = {
					ok = true,
					data = {
						catalogId = catalogId,
						quantity = quantity,
						coins = coins,
						remaining = (policy :: any).dailyUnits - nextState.sold,
					},
				}
				return work
			end)
			if not token then
				return { ok = false, reason = err or "SAVE_FAILED" }
			end
			port.install(token)
			return outcome
		end,
		snapshot = function(actor: string): (Shared.StateData?, string?)
			local port = ctx.personalTransfer(actor)
			if not port or not policy then
				return nil, "PERSONAL_UNAVAILABLE"
			end
			local slice = port.profile().data.envelope.genres[GENRE].data
			local prices: { [string]: number } = table.clone(policy.prices)
			return {
				prices = prices,
				dailyUnits = policy.dailyUnits,
				remaining = Buyback.remaining(policy, slice.harborBuyback, ctx.now()),
				atHarbor = atHarbor(),
			} :: any,
				nil
		end,
	}
	return extension :: any
end

return M
