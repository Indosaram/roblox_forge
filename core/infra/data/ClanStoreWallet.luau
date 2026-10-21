--!strict
-- Same crash barriers as ItemTransfer: source ESCROWED -> target CREDITED ->
-- source FINALIZED. Receipts live in the existing itemTransfers envelope.
-- Callers retain both refreshed profiles even on an ambiguous acknowledgement.
local Wallet = require("../../domain/economy/Wallet")
local Clan = require("../../domain/settlement/Clan")
local M = {}

local function receipts(data: any): any
	if not data.itemTransfers then
		data.itemTransfers = { version = 1, receipts = {} }
	end
	assert(data.itemTransfers.version == 1, "INVALID_TRANSFER_SAVE")
	return data.itemTransfers.receipts
end

function M.advance(config: any, source: any, destination: any, request: any): any
	local function result(status: string, reason: string?): any
		return { status = status, reason = reason, source = source, destination = destination }
	end
	if
		type(request.amount) ~= "number"
		or request.amount <= 0
		or request.amount % 1 ~= 0
		or request.amount > 2 ^ 53 - 1
		or request.source ~= source.key
		or request.destination ~= destination.key
		or source.key == destination.key
		or (request.operation == "deposit" and string.sub(destination.key, 1, 5) ~= "clan:")
		or (request.operation == "withdraw" and string.sub(source.key, 1, 5) ~= "clan:")
		or type(request.id) ~= "string"
		or request.id == ""
		or type(request.actor) ~= "string"
		or request.actor == ""
		or type(request.epoch) ~= "string"
		or request.epoch == ""
		or type(request.expiresAt) ~= "number"
		or request.expiresAt % 1 ~= 0
		or request.expiresAt > 2 ^ 53 - 1
		or (request.operation ~= "deposit" and request.operation ~= "withdraw")
	then
		return result("rejected", "INVALID_REQUEST")
	end
	local binding = config.encode(request)
	local reason: string? = nil
	local phase: string? = nil
	local updated, err = config.store:update(source, function(data: any): any
		reason, phase = nil, nil
		local known = receipts(data)[request.id]
		if known then
			if known.binding ~= binding then
				reason = "TRANSFER_CONFLICT"
			else
				phase = known.phase
			end
			return data
		end
		if config.now() >= request.expiresAt then
			reason = "REQUEST_EXPIRED"
			return data
		end
		if not config.authorize(request, data) then
			reason = "FORBIDDEN"
			return data
		end
		if request.operation == "withdraw" and not Clan.allowed(data, request.actor, "withdraw") then
			reason = "FORBIDDEN"
			return data
		end
		local count = 0
		for _ in receipts(data) do
			count += 1
		end
		if count >= config.maxReceipts then
			reason = "RECEIPT_LIMIT"
			return data
		end
		local balance = config.balance(data, source.key)
		local wallet = Wallet.new({ Coins = balance })
		if not wallet:debit("Coins", request.amount) then
			reason = "INSUFFICIENT_FUNDS"
			return data
		end
		config.setBalance(data, source.key, wallet:balance("Coins"))
		receipts(data)[request.id] = { binding = binding, phase = "ESCROWED" }
		phase = "ESCROWED"
		return data
	end)
	if not updated then
		return result("recovering", err)
	end
	source = updated
	if reason then
		return result("rejected", reason)
	end
	if phase == "FINALIZED" then
		return result("confirmed", nil)
	end
	updated, err = config.store:update(destination, function(data: any): any
		reason = nil
		local known = receipts(data)[request.id]
		if known then
			if known.binding ~= binding or known.phase ~= "CREDITED" then
				reason = "TRANSFER_CONFLICT"
			end
			return data
		end
		local wallet = Wallet.new({ Coins = config.balance(data, destination.key) })
		local count = 0
		for _ in receipts(data) do
			count += 1
		end
		if count >= config.maxReceipts then
			reason = "RECEIPT_LIMIT"
			return data
		end
		wallet:credit("Coins", request.amount)
		config.setBalance(data, destination.key, wallet:balance("Coins"))
		receipts(data)[request.id] = { binding = binding, phase = "CREDITED" }
		return data
	end)
	if not updated then
		return result("recovering", err)
	end
	destination = updated
	if reason then
		return result("recovering", reason)
	end
	updated, err = config.store:update(source, function(data: any): any
		local known = receipts(data)[request.id]
		assert(known and known.binding == binding and known.phase == "ESCROWED", "TRANSFER_CONFLICT")
		known.phase = "FINALIZED"
		return data
	end)
	if not updated then
		return result("recovering", err)
	end
	source = updated
	return result("confirmed", nil)
end

return M
