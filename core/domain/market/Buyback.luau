--!strict
-- Harbor raw-material buyback (robango auxiliary-material spec, "Coins acquisition"): the harbor
-- NPC buys a fixed list of raw ids at a fixed low Coin price, up to a shared per-UTC-day unit cap.
-- It anchors player market prices from below. Pure: the caller passes the day and the state.
local M = {}

export type Policy = { prices: { [string]: number }, dailyUnits: number, daySeconds: number }
export type State = { day: number, sold: number }

function M.fresh(): State
	return { day = -1, sold = 0 }
end

--- UTC day index of an explicit unix time.
function M.day(policy: Policy, now: number): number
	return math.floor(now / policy.daySeconds)
end

--- Units still sellable today.
function M.remaining(policy: Policy, state: State?, now: number): number
	local today = M.day(policy, now)
	local sold = if state and state.day == today then state.sold else 0
	return math.max(0, policy.dailyUnits - sold)
end

--- Quote and next state for selling `quantity` of `catalogId`; nil + reason when refused.
function M.sell(
	policy: Policy,
	state: State?,
	catalogId: string,
	quantity: number,
	now: number
): (number?, State?, string?)
	local price = policy.prices[catalogId]
	if price == nil then
		return nil, nil, "NOT_BOUGHT"
	end
	if type(quantity) ~= "number" or quantity % 1 ~= 0 or quantity < 1 then
		return nil, nil, "INVALID_QUANTITY"
	end
	if quantity > M.remaining(policy, state, now) then
		return nil, nil, "DAILY_CAP"
	end
	local today = M.day(policy, now)
	local sold = if state and state.day == today then state.sold else 0
	return price * quantity, { day = today, sold = sold + quantity }, nil
end

return M
