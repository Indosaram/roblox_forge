--!strict
-- Same-server direct trade (ui.direct-trade). Negotiation (open / offer / confirm / cancel)
-- is server-local: both players are on this server by construction and a departure cancels
-- any unlocked trade. Once both confirm the same revision the trade locks and settles through
-- the personal records with per-step receipts in itemTransfers.receipts:
-- debit A, debit B, credit B<-A, credit A<-B. Each debit marker carries the escrow terms; B's
-- debit marker is the commit point. Without it an abort marker fences B and A is refunded;
-- with it both credits roll forward. A restarted server resolves half-settled trades from
-- these markers on join/recovery (recoverDurable), so both sides end consistent.
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
		-- Read-only settlement status by operationId (ui.transaction "Check status").
		{ id = "operation-status", args = { id }, origin = "client", rate = rate },
	}
end

-- config: { catalog, personal(actor) -> PersonalTransfer?, transact(actor, transform)?,
--   members() -> {string}, now() }
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
	-- One fenced personal write. The live owner (personalTransfer) is used when the actor is on
	-- this server; otherwise the trusted personalTransaction loads the record (crash recovery).
	local function write(actor: string, transform: (any) -> any): (boolean, string?)
		local port = config.personal(actor)
		if port then
			local updated, err = port.personal:update(port.profile(), transform)
			if not updated then
				return false, err
			end
			port.install(updated)
			return true, nil
		end
		if config.transact then
			local ok, reason = config.transact(actor, transform)
			return ok == true, if ok then nil else reason
		end
		return false, "PERSONAL_UNAVAILABLE"
	end
	-- One step guarded by its receipt marker (replays are no-ops). guard: a marker whose
	-- presence refuses the step (debit B vs abort B decide the trade exactly once).
	-- Returns ok, reason, refused (true when the domain refused rather than the store).
	local function step(
		actor: string,
		marker: string,
		transform: (any) -> (any?, string?),
		guard: string?,
		value: any?
	): (boolean, string?, boolean)
		local refused: string? = nil
		local ok, err = write(actor, function(view: any): any
			refused = nil
			local receipts = view.itemTransfers.receipts
			if receipts[marker] then
				return view
			end
			if guard and receipts[guard] then
				refused = "GUARDED"
				return view
			end
			local nextData, reason = transform(data(view))
			if not nextData then
				refused = reason
				return view
			end
			view.envelope.genres["survival-coop"].data = nextData
			receipts[marker] = value or { phase = "APPLIED" }
			return view
		end)
		if not ok then
			return false, err, false
		end
		return refused == nil, refused, refused ~= nil
	end
	-- Durable escrow terms carried by each debit marker (enough to finish or roll back).
	local function terms(trade: any): any
		return {
			tradeId = trade.tradeId,
			participants = table.clone(trade.participants),
			offers = Trade.copy(trade.offers),
			status = "locked",
		}
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
	local function credits(trade: any): (boolean, string?)
		local a, b = trade.participants[1], trade.participants[2]
		local prefix = "trade:" .. trade.tradeId .. ":"
		local ok, reason = step(b, prefix .. "credit", function(d)
			return Trade.credit(trade, b, a, d, config.catalog)
		end)
		if not ok then
			return false, reason
		end
		return step(a, prefix .. "credit", function(d)
			return Trade.credit(trade, a, b, d, config.catalog)
		end)
	end
	-- Closing markers on both records end recovery for this trade (written last, idempotent).
	local function finish(trade: any): (boolean, string?)
		local marker = "trade:" .. trade.tradeId .. ":closed"
		for _, actor in trade.participants do
			local ok, reason = step(actor, marker, function(d)
				return d
			end)
			if not ok then
				return false, reason
			end
		end
		return true, nil
	end
	-- Decide a trade whose first debit is durable: B's debit marker is the commit point. A
	-- missing one is fenced by an abort marker on B (refused if B already debited), then A is
	-- refunded; a present one rolls forward with both credits. Idempotent from either side.
	local function resolve(trade: any): (string?, string?)
		local a, b = trade.participants[1], trade.participants[2]
		local prefix = "trade:" .. trade.tradeId .. ":"
		local aborted, reason, refused = step(b, prefix .. "abort", function(d)
			return d
		end, prefix .. "debit", { phase = "ABORTED" })
		if aborted then
			local refunded, refundReason = step(a, prefix .. "refund", function(d)
				return Trade.credit(trade, a, a, d, config.catalog)
			end)
			if refunded then
				refunded, refundReason = finish(trade)
			end
			return if refunded then "cancelled" else nil, refundReason
		end
		if not refused then
			return nil, reason
		end
		local done, creditReason = credits(trade)
		if done then
			done, creditReason = finish(trade)
		end
		return if done then "settled" else nil, creditReason
	end
	-- Drive a locked trade forward from its recorded phase.
	local function settle(trade: any): any
		local a, b = trade.participants[1], trade.participants[2]
		local prefix = "trade:" .. trade.tradeId .. ":"
		local escrow = { phase = "ESCROWED", trade = terms(trade) }
		local recovering = { status = "recovering", operationId = trade.tradeId }
		trade.phase = trade.phase or "PREPARED"
		if trade.phase == "PREPARED" then
			local ok, reason, refused = step(a, prefix .. "debit", function(d)
				return Trade.debit(trade, a, d, config.catalog)
			end, nil, escrow)
			if not ok then
				if refused then
					close(trade, "cancelled", reason)
					return { ok = false, reason = reason }
				end
				return { ok = false, reason = reason, data = recovering }
			end
			trade.phase = "DEBITED_A"
		end
		if trade.phase == "DEBITED_A" then
			local ok, reason, refused = step(b, prefix .. "debit", function(d)
				return Trade.debit(trade, b, d, config.catalog)
			end, prefix .. "abort", escrow)
			if not ok and not refused then
				return { ok = false, reason = reason, data = recovering }
			end
			if not ok then
				-- B refused before any credit: fence B and refund A's escrow.
				local outcome, why = resolve(trade)
				if outcome == "cancelled" then
					close(trade, "cancelled", reason)
					return { ok = false, reason = reason }
				elseif outcome == nil then
					return { ok = false, reason = why, data = recovering }
				end
			end
			trade.phase = "DEBITED"
		end
		if trade.phase == "DEBITED" then
			local ok, reason = credits(trade)
			if ok then
				ok, reason = finish(trade)
			end
			if not ok then
				return { ok = false, reason = reason, data = recovering }
			end
		end
		close(trade, "settled", nil)
		return { ok = true, data = { operationId = trade.tradeId, status = "delivered" } }
	end
	-- Half-settled trades from a previous server (no in-memory record): every debit marker on
	-- the actor's record without a closed marker is resolved from its escrow terms, writing the
	-- counterpart's record through the trusted personal transaction when they are offline.
	local function recoverDurable(actor: string): number
		local port = config.personal(actor)
		if not port then
			return 0
		end
		local receipts = port.profile().data.itemTransfers.receipts
		local open = {}
		for key, receipt in receipts do
			local id = string.match(key, "^trade:(.+):debit$")
			local prefix = "trade:" .. tostring(id) .. ":"
			if
				id
				and trades[id] == nil
				and type(receipt) == "table"
				and type(receipt.trade) == "table"
				and receipts[prefix .. "closed"] == nil
			then
				table.insert(open, receipt.trade)
			end
		end
		table.sort(open, function(x, y)
			return x.tradeId < y.tradeId
		end)
		local pending = 0
		for _, escrowed in open do
			local outcome = resolve(escrowed)
			if outcome then
				finished[actor] = { tradeId = escrowed.tradeId, status = outcome }
			else
				pending += 1
			end
		end
		return pending
	end
	local function wallet(actor: string): any?
		local port = config.personal(actor)
		if not port then
			return nil
		end
		local d = data(port.profile().data)
		return { balance = d.balance or 0, bag = d.inventory.bag }
	end

	-- Read-only status of one of the actor's operations from durable records only: a trade id
	-- (in-memory trade, then the actor's trade receipt markers) or a durable command requestId
	-- (the committed command ledger outcome). Never stages, sends or debits anything.
	local function status(actor: string, operationId: string): (string?, string?)
		local live = trades[operationId]
		if live and live.offers[actor] ~= nil then
			return if live.status == "locked" then "settling" else "verifying", nil
		end
		local last = finished[actor]
		if last and last.tradeId == operationId then
			return if last.status == "settled" then "delivered" else "rejected", last.reason
		end
		local port = config.personal(actor)
		if not port then
			return nil, "PERSONAL_UNAVAILABLE"
		end
		local record = port.profile().data
		local receipts = record.itemTransfers.receipts
		local prefix = "trade:" .. operationId .. ":"
		if receipts[prefix .. "credit"] then
			return "delivered", nil
		elseif receipts[prefix .. "refund"] or receipts[prefix .. "abort"] then
			return "rejected", "TRADE_CLOSED"
		elseif receipts[prefix .. "debit"] then
			return "settling", nil
		end
		local generic = receipts[operationId]
		if type(generic) == "table" then
			local phase = generic.phase
			return if phase == "FINALIZED"
					or phase == "CREDITED"
					or phase == "APPLIED"
					or phase == "RETIRED"
				then "delivered"
				elseif phase == "CANCELLED" or phase == "ABORTED" then "rejected"
				else "settling",
				nil
		end
		local ledger = record.envelope.commands
		for _, epoch in (if ledger then ledger.epochs else nil) or {} do
			local outcome = epoch.outcomes[operationId]
			if outcome and type(outcome.result) == "table" then
				return if outcome.result.ok then "delivered" else "rejected", outcome.result.reason
			end
		end
		return nil, "UNKNOWN_OPERATION"
	end

	function extension.handles(action: string): boolean
		return action == "survival-coop:operation-status"
			or action == "survival-coop:trade-open"
			or action == "survival-coop:trade-offer"
			or action == "survival-coop:trade-confirm"
			or action == "survival-coop:trade-cancel"
	end
	function extension.command(actor: string, action: string, args: any, context: any, _origin: string, admit: any): any
		if context.actorId ~= actor then
			return { ok = false, reason = "FORBIDDEN" }
		end
		if action == "survival-coop:operation-status" then
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			local state, reason = status(actor, args[1])
			if not state then
				return { ok = false, reason = reason }
			end
			return { ok = true, data = { operationId = args[1], status = state, reason = reason } }
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
		local pending = 0
		if trade and trade.status == "locked" then
			local result = settle(trade)
			pending += if result.ok or trade.status ~= "locked" then 0 else 1
		end
		pending += recoverDurable(actor)
		return { status = if pending == 0 then "confirmed" else "recovering", pending = pending }
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
		transact = ctx.personalTransaction,
		members = ctx.members,
		now = ctx.now,
	})
end

return M
