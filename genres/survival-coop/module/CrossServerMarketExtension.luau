--!strict
local Domain = require("../../../core/domain/market/CrossServer")
local Eligibility = require("../../../core/domain/market/Market")
local M = {}
-- Inject participant storage transactions here, never an online seller lookup.
-- Index ports must tolerate MemoryStore unavailability and return stale rows;
-- only the durable book decides whether a purchase is accepted.
function M.new(ports: Domain.Ports, now: () -> number, personal: any?, catalogIds: { string }?, account: any?): any
	local book = Domain.new(ports)
	local filters: { [string]: string } = {}
	local pages: { [string]: number } = {}
	local function eligible(actor: string): (boolean, string?)
		if not account then
			return true, nil
		end
		local facts = account(actor, now())
		if not facts then
			return false, "INVALID_ACCOUNT"
		end
		return Eligibility.eligible({ _config = Eligibility.DEFAULTS } :: any, facts, now())
	end
	return {
		id = "market",
		handles = function(action: string): boolean
			return action == "survival-coop:market-list"
				or action == "survival-coop:market-buy"
				or action == "survival-coop:market-cancel"
				or action == "survival-coop:market-browse"
				or action == "survival-coop:market-claim"
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
			if action == "survival-coop:market-list" or action == "survival-coop:market-buy" then
				local allowed, reason = eligible(actor)
				if not allowed then
					return { ok = false, reason = reason }
				end
			end
			if action == "survival-coop:market-list" then
				return book.list(actor, context.requestId, args[1], args[2], args[3], now())
			elseif action == "survival-coop:market-buy" then
				return book.buy(actor, context.requestId, args[1], args[2], now())
			elseif action == "survival-coop:market-cancel" then
				return book.cancel(actor, args[1], now())
			elseif action == "survival-coop:market-browse" and personal then
				filters[actor], pages[actor] = args[1], args[2]
				return { ok = true }
			elseif action == "survival-coop:market-claim" and personal then
				return personal.claim(actor, args[1])
			end
			return { ok = false, reason = "unknown_action" }
		end,
		snapshot = if personal
			then function(actor: string): any
				local state = personal.snapshot(actor, pages[actor] or 1)
				if not state then
					return nil
				end
				state.catalogIds = catalogIds or {}
				state.eligible, state.ineligibleReason = eligible(actor)
				state.filter = filters[actor] or (catalogIds or {})[1]
				state.listings = if state.filter then book.search(state.filter) else {}
				state.listed = {}
				for id in state.active do
					local listing = book.quote(id)
					if listing then
						table.insert(state.listed, listing)
					end
				end
				return state
			end
			else nil,
		recover = if personal
			then function(_actor: string): any
				local count = 0
				for _, id in (ports :: any).pending() do
					local result = book.recover(id, now())
					if not result.ok then
						count += 1
					end
				end
				return { status = if count == 0 then "confirmed" else "recovering", pending = count }
			end
			else nil,
	}
end
return M
