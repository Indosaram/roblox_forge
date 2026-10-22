--!strict
-- Same-server direct trade (ui.direct-trade). Negotiation (open / offer / confirm / cancel)
-- is server-local: both players are on this server by construction and a departure cancels
-- any unlocked trade. Once both confirm the same revision the trade locks and settles through
-- the personal records with per-step receipts in itemTransfers.receipts:
-- debit A, debit B, credit B<-A, credit A<-B. A failed debit refunds an earlier debit before
-- any credit (ABORTED); after the first credit only recovery completes it, never a refund.
local Trade = require("../../../core/domain/market/DirectTrade")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Session = require("../../../core/infra/genre/Session")
local Schema = require("../../../core/infra/net/Schema")
local M = {}

function M.actions(): { any }
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	local revision = Schema.number({ min = 0, max = 2 ^ 31, integer = true })
	local rate = { capacity = 10, refillPerSecond = 2 }
	return {
		{ id = "trade-open", args = { id }, origin = "client", rate = rate },
		{
			id = "trade-offer",
			args = {
				id,
				Schema.object({
					revision = revision,
					itemId = Schema.optional(id),
					quantity = Schema.optional(Schema.number({ min = 1, max = 1000, integer = true })),
					coins = Schema.number({ min = 0, max = 1000000000, integer = true }),
				}),
			},
			origin = "client",
			rate = rate,
		},
		{ id = "trade-confirm", args = { id, revision }, origin = "client", rate = rate },
		{ id = "trade-cancel", args = { id }, origin = "client", rate = rate },
	}
end

-- config: { catalog, personal(actor) -> PersonalTransfer?, members() -> {string}, now() }
function M.new(config: any): any
	local trades: { [string]: any } = {}
	local byActor: { [string]: string } = {}
	local results: { [string]: any } = {}
	local finished: { [string]: any } = {}
	local sequence = 0
	local extension: any = { id = "trade" }

	local function data(view: any): any
		return view.envelope.genres["survival-coop"].data
	end
	-- One fenced personal step guarded by its receipt marker; replays are no-ops.
	local function step(actor: string, marker: string, transform: (any) -> (any?, string?)): (boolean, string?)
		local port = config.personal(actor)
		if not port then
			return false, "PERSONAL_UNAVAILABLE"
		end
		local refused: string? = nil
		local updated, err = port.personal:update(port.profile(), function(view: any): any
			refused = nil
			if view.itemTransfers.receipts[marker] then
				return view
			end
			local nextData, reason = transform(data(view))
			if not nextData then
				refused = reason
				return view
			end
			view.envelope.genres["survival-coop"].data = nextData
			view.itemTransfers.receipts[marker] = { phase = "APPLIED" }
			return view
		end)
		if not updated then
			return false, err
		end
		port.install(updated)
		return refused == nil, refused
	end
	local function close(trade: any, status: string, reason: string?)
		trade.status, trade.reason = status, reason
		for _, actor in trade.participants do
			if byActor[actor] == trade.tradeId then
				byActor[actor] = nil
			end
			finished[actor] = trade
		end
		trades[trade.tradeId] = nil
	end
	-- Drive a locked trade forward from its recorded phase.
	local function settle(trade: any): any
		local a, b = trade.participants[1], trade.participants[2]
		local prefix = "trade:" .. trade.tradeId .. ":"
		trade.phase = trade.phase or "PREPARED"
		if trade.phase == "PREPARED" then
			local ok, reason = step(a, prefix .. "debit", function(d)
				return Trade.debit(trade, a, d, config.catalog)
			end)
			if not ok then
				close(trade, "cancelled", reason)
				return { ok = false, reason = reason }
			end
			trade.phase = "DEBITED_A"
		end
		if trade.phase == "DEBITED_A" then
			local ok, reason = step(b, prefix .. "debit", function(d)
				return Trade.debit(trade, b, d, config.catalog)
			end)
			if not ok then
				-- Reverse A's escrow before any credit happened.
				local refunded, refundReason = step(a, prefix .. "refund", function(d)
					return Trade.credit(trade, a, a, d, config.catalog)
				end)
				if not refunded then
					return { ok = false, reason = refundReason, data = { status = "recovering" } }
				end
				close(trade, "cancelled", reason)
				return { ok = false, reason = reason }
			end
			trade.phase = "DEBITED"
		end
		if trade.phase == "DEBITED" then
			local ok, reason = step(b, prefix .. "credit", function(d)
				return Trade.credit(trade, b, a, d, config.catalog)
			end)
			if not ok then
				return { ok = false, reason = reason, data = { status = "recovering", operationId = trade.tradeId } }
			end
			trade.phase = "CREDITED_B"
		end
		if trade.phase == "CREDITED_B" then
			local ok, reason = step(a, prefix .. "credit", function(d)
				return Trade.credit(trade, a, b, d, config.catalog)
			end)
			if not ok then
				return { ok = false, reason = reason, data = { status = "recovering", operationId = trade.tradeId } }
			end
			trade.phase = "COMMITTED"
		end
		close(trade, "settled", nil)
		return { ok = true, data = { operationId = trade.tradeId, status = "delivered" } }
	end
	local function wallet(actor: string): any?
		local port = config.personal(actor)
		if not port then
			return nil
		end
		local d = data(port.profile().data)
		return { balance = d.balance or 0, bag = d.inventory.bag }
	end

	function extension.handles(action: string): boolean
		return action == "survival-coop:trade-open"
			or action == "survival-coop:trade-offer"
			or action == "survival-coop:trade-confirm"
			or action == "survival-coop:trade-cancel"
	end
	function extension.command(actor: string, action: string, args: any, context: any, _origin: string, admit: any): any
		if context.actorId ~= actor then
			return { ok = false, reason = "FORBIDDEN" }
		end
		local receipt = actor .. ":" .. tostring(context.sessionEpoch) .. ":" .. context.requestId
		if results[receipt] then
			return results[receipt]
		end
		local admitted = admit()
		if not admitted.ok then
			return admitted
		end
		local operation = string.gsub(action, "^survival%-coop:trade%-", "")
		local result: any
		if operation == "open" then
			local target = args[1]
			sequence += 1
			local tradeId = "t" .. tostring(config.now()) .. ":" .. tostring(sequence)
			local opened, reason = Trade.open(tradeId, actor, target, {
				sameServer = table.find(config.members(), target) ~= nil,
				busy = byActor[actor] ~= nil or byActor[target] ~= nil,
			})
			if opened then
				trades[tradeId], byActor[actor], byActor[target] = opened, tradeId, tradeId
				finished[actor], finished[target] = nil, nil
			end
			result = { ok = opened ~= nil, reason = reason, data = if opened then { tradeId = tradeId } else nil }
		else
			local trade = trades[args[1]]
			if not trade then
				result = { ok = false, reason = "NO_TRADE" }
			elseif operation == "cancel" then
				local cancelled, reason = Trade.cancel(trade, actor, "CANCELLED")
				if cancelled and trade.status == "open" then
					close(cancelled, "cancelled", "CANCELLED")
				end
				result = {
					ok = cancelled ~= nil and trade.status == "open",
					reason = reason or (if trade.status ~= "open" then "TRADE_CLOSED" else nil),
				}
			elseif table.find(config.members(), Trade.other(trade, actor)) == nil then
				close(trade, "cancelled", "COUNTERPART_LEFT")
				result = { ok = false, reason = "COUNTERPART_LEFT" }
			elseif operation == "offer" then
				local funds = wallet(actor)
				local nextTrade, reason =
					if funds then Trade.offer(trade, actor, args[2].revision, args[2], funds) else nil,
					if funds then nil else "PERSONAL_UNAVAILABLE"
				if nextTrade then
					trades[trade.tradeId] = nextTrade
				end
				result = { ok = nextTrade ~= nil, reason = reason }
			elseif operation == "confirm" then
				local nextTrade, reason = Trade.confirm(trade, actor, args[2])
				if nextTrade then
					trades[trade.tradeId] = nextTrade
					result = if nextTrade.status == "locked" then settle(nextTrade) else { ok = true }
				else
					result = { ok = false, reason = reason }
				end
			end
		end
		results[receipt] = result
		return result
	end
	function extension.snapshot(actor: string): any?
		local peers = {}
		for _, member in config.members() do
			if member ~= actor then
				table.insert(peers, member)
			end
		end
		table.sort(peers)
		local current = if byActor[actor] then trades[byActor[actor]] else nil
		local last = finished[actor]
		if #peers == 0 and not current and not last then
			return nil
		end
		return {
			peers = peers,
			trade = if current then Trade.copy(current) else nil,
			last = if last then { tradeId = last.tradeId, status = last.status, reason = last.reason } else nil,
		}
	end
	function extension.recover(actor: string, _maximum: number): any
		local id = byActor[actor]
		local trade = if id then trades[id] else nil
		if trade and trade.status == "locked" then
			local result = settle(trade)
			return { status = if result.ok then "confirmed" else "recovering", pending = if result.ok then 0 else 1 }
		end
		return { status = "confirmed", pending = 0 }
	end
	function extension.releaseActor(actor: string): any
		local id = byActor[actor]
		local trade = if id then trades[id] else nil
		-- Disconnect cancels negotiation; a locked trade stays for recovery.
		if trade and trade.status == "open" then
			close(trade, "cancelled", "COUNTERPART_LEFT")
		end
		return { ok = true }
	end
	function extension.resumeActor(_actor: string): any
		return { ok = true }
	end
	return Session.registerLifecycle(extension)
end

function M.factory(ctx: any): any
	if not (ctx.world and ctx.world.directTrade) then
		return nil
	end
	return M.new({
		catalog = Catalog.new(ctx.content.items),
		personal = ctx.personalTransfer,
		members = ctx.members,
		now = ctx.now,
	})
end

return M
