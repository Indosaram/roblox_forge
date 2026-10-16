--!strict
-- Exposure (climate) gauge rules. Pure fixed point; the caller owns the clock.
--
-- The gauge counts 0..MAX where 0 is comfortable and MAX is fully exposed.
-- Four biome tiers (0 temperate .. 3 extreme) set a base rise rate in milli per
-- second. Clothing resistance (0..1000) removes that fraction of the rise.
-- Tier 0, resting at a campfire, or a fully mitigated tier recovers instead.
-- The same linear `step` advances the stamina gauge, so both stay exact under
-- any heartbeat partition: remainders carry the sub-milli fraction.
local M = {}

M.MAX = 100000
M.MAX_TIER = 3
M.MAX_RESISTANCE_MILLI = 1000
M.TIER_NAMES = { "temperate", "harsh", "severe", "extreme" }

local function integer(value: any, maximum: number): boolean
	return type(value) == "number" and value == value and value >= 0 and value <= maximum and value % 1 == 0
end

function M.validTier(tier: any): boolean
	return integer(tier, M.MAX_TIER)
end

function M.validResistance(resistanceMilli: any): boolean
	return integer(resistanceMilli, M.MAX_RESISTANCE_MILLI)
end

--- Sums per-item resistance scores and clamps to the policy maximum.
function M.combine(scores: { number }): number
	local total = 0
	for _, score in scores do
		assert(M.validResistance(score), "invalid resistance score")
		total += score
	end
	return math.min(total, M.MAX_RESISTANCE_MILLI)
end

--- Rise per second after clothing mitigation, floored to whole milli.
function M.mitigated(baseMilliPerSecond: number, resistanceMilli: number): number
	assert(M.validResistance(resistanceMilli), "invalid resistance")
	return math.floor(baseMilliPerSecond * (M.MAX_RESISTANCE_MILLI - resistanceMilli) / M.MAX_RESISTANCE_MILLI)
end

--- Signed rate in milli per second: positive rises, negative recovers.
--- `riseByTier[tier]` (tiers 1..3) is the unmitigated base rise for that tier.
function M.rate(
	riseByTier: { number },
	recoverMilliPerSecond: number,
	tier: number,
	resistanceMilli: number,
	warm: boolean
): number
	assert(M.validTier(tier), "invalid exposure tier")
	if tier == 0 or warm then
		return -recoverMilliPerSecond
	end
	local rise = M.mitigated(riseByTier[tier], resistanceMilli)
	return if rise > 0 then rise else -recoverMilliPerSecond
end

--- Milliseconds until a rising gauge first reads MAX. 0 when it already does
--- and still rises; math.huge when it never gets there at this rate.
function M.timeToFull(value: number, remainder: number, ratePerSecond: number): number
	if ratePerSecond <= 0 then
		return math.huge
	end
	local need = M.MAX - value
	if need <= 0 then
		return 0
	end
	return math.max(0, math.ceil((need * 1000 - remainder) / ratePerSecond))
end

--- Advances a linear gauge by `dtMillis` at `ratePerSecond` (milli per second).
--- Clamps to 0..MAX and drops the remainder at a clamp.
function M.step(value: number, remainder: number, ratePerSecond: number, dtMillis: number): (number, number)
	if ratePerSecond == 0 or dtMillis <= 0 then
		return value, remainder
	end
	if ratePerSecond > 0 then
		local total = remainder + dtMillis * ratePerSecond
		local nextValue = value + math.floor(total / 1000)
		if nextValue >= M.MAX then
			return M.MAX, 0
		end
		return nextValue, total % 1000
	end
	local total = remainder + dtMillis * -ratePerSecond
	local nextValue = value - math.floor(total / 1000)
	if nextValue <= 0 then
		return 0, 0
	end
	return nextValue, total % 1000
end

return M
