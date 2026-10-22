--!strict
-- Owner-only home relocation between authored destination spots. Structures keep their
-- land-relative positions and storage moves as one packed record, so the move itself never
-- credits, debits or rerolls anything. Access grants and property history are preserved.
-- Destinations are RECONSTRUCTED configuration (HomeContent.rules.moveDestinations).
local Home = require("./HomeState")
local M = {}

M.HISTORY_LIMIT = 10

function M.location(state: any, rules: any): string
	return state.location or rules.moveDestinations[1]
end

-- ctx: { rules, now, pendingTransfers }. pendingTransfers counts unsettled storage transfers
-- (the safe-transfer lock: a home never moves while an item is between records).
function M.apply(state: any, actor: string, homeId: string, args: any, ctx: any): (any?, string?)
	if homeId ~= state.homeId then
		return nil, "WRONG_HOME_TOKEN"
	end
	if actor ~= state.owner then
		return nil, "FORBIDDEN"
	end
	local destination = args.destination
	if type(destination) ~= "string" or not table.find(ctx.rules.moveDestinations, destination) then
		return nil, "UNKNOWN_DESTINATION"
	end
	if destination == M.location(state, ctx.rules) then
		return nil, "SAME_DESTINATION"
	end
	if (ctx.pendingTransfers or 0) > 0 then
		return nil, "TRANSFER_LOCKED"
	end
	local out = Home.copy(state)
	local history = out.moveHistory or {}
	table.insert(history, { from = M.location(state, ctx.rules), to = destination, at = ctx.now })
	while #history > M.HISTORY_LIMIT do
		table.remove(history, 1)
	end
	out.location, out.moveHistory = destination, history
	out.revision += 1
	return out, nil
end

return M
