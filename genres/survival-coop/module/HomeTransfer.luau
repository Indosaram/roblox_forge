--!strict
-- A home-owned intent fences the two participant records before escrow. The
-- existing ItemTransfer protocol owns all debit/credit crash barriers.
local Transfer = require("../../../core/infra/data/ItemTransfer")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Ledger = require("../../../core/domain/command/Ledger")
local Home = require("../../../core/domain/home/HomeState")
local Spoilage = require("../../../core/domain/survival/Spoilage")
local M = {}

-- A placed refrigerator makes home storage a cold container (food ages at the policy rate).
function M.refrigerated(home: any): boolean
	for _, placed in home.structures or {} do
		if placed.kind == "refrigerator" then
			return true
		end
	end
	return false
end

function M.new(config: any): any
	local api = {}
	local function drive(actor: string, request: any): any
		local port = config.personal(actor)
		if not port then
			return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
		end
		local lens = port.personal:inventoryLens()
		local router: any = {}
		function router:update(token, transform)
			if token.key == request.homeKey then
				return config.update(actor, function(data)
					local view =
						transform({ inventory = Home.copy(data.home.storage), itemTransfers = data.itemTransfers })
					data.home.storage, data.itemTransfers = view.inventory, view.itemTransfers
					return data
				end)
			end
			local projected, reason = lens:update(port.profile(), transform)
			if not projected then
				return nil, reason
			end
			local current, err = port.personal:refresh(projected)
			if current then
				port.install(current)
			end
			return if current then projected else nil, err
		end
		local coordinator = Transfer.new(router, config.catalog, {
			maxReceipts = 4096,
			now = config.now,
			authorize = function(candidate)
				return Ledger.canonical(candidate) == Ledger.canonical(request.transfer)
			end,
		})
		local result
		for _ = 1, 4 do
			local home, reason = config.open(actor)
			if not home then
				return { ok = false, reason = reason }
			end
			local projected = Home.copy(home)
			projected.data = { inventory = home.data.home.storage, itemTransfers = home.data.itemTransfers }
			local source = if request.deposit then port.profile() else projected
			local destination = if request.deposit then projected else port.profile()
			result = coordinator:advance(source, destination, request.transfer, nil)
			if result.status ~= "pending" or result.error then
				break
			end
		end
		if result.status == "confirmed" or result.status == "rejected" then
			local updated, reason = config.update(actor, function(data: any)
				data.transfers[request.transfer.id].result =
					{ ok = result.status == "confirmed", reason = result.error }
				-- Deposited food keeps the age it reached in the bag; from here it ages at the home rate.
				local stored = data.home.storage.items[request.transfer.outputId]
				if
					result.status == "confirmed"
					and request.deposit
					and request.agedAt
					and stored
					and config.spoilage
				then
					local rebased = Spoilage.rebase(stored, config.spoilage, request.agedAt, false)
					if rebased ~= stored then
						data.home.storage.items[request.transfer.outputId] = Home.copy(rebased)
						data.home.storage.version += 1
					end
				end
				return data
			end)
			if not updated then
				return { ok = false, reason = reason }
			end
		end
		return {
			ok = result.status == "confirmed",
			reason = result.error or (if result.status ~= "confirmed" then "TRANSFER_PENDING" else nil),
		}
	end
	function api.recover(actor: string): any
		local token, reason = config.open(actor)
		if not token then
			return { ok = false, reason = reason }
		end
		for _, request in token.data.transfers or {} do
			if not request.result then
				local result = drive(actor, request)
				if not result.ok then
					return result
				end
			end
		end
		return { ok = true }
	end
	function api.command(
		actor: string,
		deposit: boolean,
		itemId: string,
		quantity: number,
		context: any,
		admit: any
	): any
		if not Catalog.identity(itemId) or not Catalog.integer(quantity, 1, 1000) then
			return { ok = false, reason = "INVALID_TRANSFER_REQUEST" }
		end
		local token, reason = config.open(actor)
		if not token then
			return { ok = false, reason = reason }
		end
		local id = "home-transfer:" .. actor .. ":" .. tostring(context.sessionEpoch) .. ":" .. context.requestId
		local binding = Ledger.canonical({ deposit = deposit, itemId = itemId, quantity = quantity })
		local known = (token.data.transfers or {})[id]
		if known then
			if known.binding ~= binding then
				return { ok = false, reason = "REQUEST_CONFLICT" }
			end
			return known.result or drive(actor, known)
		end
		local recovered = api.recover(actor)
		if not recovered.ok then
			return recovered
		end
		local admitted = admit()
		if not admitted.ok then
			return admitted
		end
		local port = config.personal(actor)
		if not port then
			return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
		end
		token = assert(config.open(actor))
		local personal = port.profile()
		local bag = personal.data.envelope.genres["survival-coop"].data.inventory.bag
		local home = token.data.home
		local source = if deposit then bag else home.storage
		local destination = if deposit then home.storage else bag
		local item = source.items[itemId]
		if not item or Inventory.available(Inventory.fromSave(source, config.catalog), itemId) < quantity then
			return { ok = false, reason = "INSUFFICIENT_ITEMS" }
		end
		local agedAt = if config.spoilage and config.nowMillis then config.nowMillis() else nil
		if agedAt and not deposit then
			-- Withdrawn food leaves with the age it reached in storage (an expired stack leaves spoiled).
			local rebased = Spoilage.rebase(item, config.spoilage, agedAt, M.refrigerated(home))
			if rebased ~= item then
				local aged, agedError = config.update(actor, function(data: any)
					data.home.storage.items[itemId] = Home.copy(rebased)
					data.home.storage.version += 1
					return data
				end)
				if not aged then
					return { ok = false, reason = agedError }
				end
				token = aged
				home = token.data.home
				source = home.storage
				item = source.items[itemId]
			end
		end
		if deposit then
			local occupied = 0
			for _ in destination.items do
				occupied += 1
			end
			if occupied > home.storageSlots then
				return { ok = false, reason = "HOME_OVERFLOW_WITHDRAW_ONLY" }
			end
		end
		local output = Home.copy(item)
		output.itemId = if item.quantity == quantity then itemId else id .. ":output"
		output.quantity = quantity
		local target = Inventory.fromSave(destination, config.catalog)
		if deposit then
			target.limits.slots = home.storageSlots
		end
		local fits, refusal = Inventory.add(target, config.catalog, output, target.version)
		if not fits then
			return { ok = false, reason = refusal }
		end
		local request = {
			binding = binding,
			deposit = deposit,
			agedAt = agedAt,
			homeKey = token.key,
			transfer = {
				id = id,
				actor = actor,
				epoch = tostring(context.sessionEpoch),
				expiresAt = config.now() + 86400,
				source = if deposit then personal.key else token.key,
				destination = if deposit then token.key else personal.key,
				itemId = itemId,
				outputId = output.itemId,
				quantity = quantity,
			},
		}
		local committed, err = config.update(actor, function(data)
			data.transfers = data.transfers or {}
			data.transfers[id] = request
			return data
		end)
		return if committed then drive(actor, request) else { ok = false, reason = err }
	end
	return api
end
return M
