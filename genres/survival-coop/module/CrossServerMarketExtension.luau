--!strict
local Domain = require("../../../core/domain/market/CrossServer")
local M = {}
-- Inject participant storage transactions here, never an online seller lookup.
-- Index ports must tolerate MemoryStore unavailability and return stale rows;
-- only the durable book decides whether a purchase is accepted.
function M.new(ports: Domain.Ports, now: () -> number): any
	local book = Domain.new(ports)
	return {
		id = "market",
		handles = function(action: string): boolean
			return action == "survival-coop:market-list"
				or action == "survival-coop:market-buy"
				or action == "survival-coop:market-cancel"
		end,
		command = function(
			actor: string,
			action: string,
			args: { any },
			context: any,
			_origin: string,
			admit: () -> any
		): any
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			if action == "survival-coop:market-list" then
				return book.list(actor, context.requestId, args[1], args[2], args[3], now())
			elseif action == "survival-coop:market-buy" then
				local quote = book.quote(args[1])
				if not quote then
					return { ok = false, reason = "pending" }
				end
				return book.buy(actor, context.requestId, args[1], args[2] or quote.price, now())
			elseif action == "survival-coop:market-cancel" then
				return book.cancel(actor, args[1], now())
			end
			return { ok = false, reason = "unknown_action" }
		end,
	}
end
return M
