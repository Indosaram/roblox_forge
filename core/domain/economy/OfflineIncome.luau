--!strict
-- OfflineIncome: capped, efficiency-scaled earnings accrued while the player is away.

local OfflineIncome = {}

local EPSILON = 1e-9

local function checkFinite(value: number, label: string): ()
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error("invalid " .. label)
	end
end

function OfflineIncome.compute(
	lastSeen: number,
	now: number,
	ratePerSecond: number,
	maxSeconds: number,
	efficiency: number
): number
	checkFinite(lastSeen, "lastSeen")
	checkFinite(now, "now")
	checkFinite(ratePerSecond, "ratePerSecond")
	checkFinite(maxSeconds, "maxSeconds")
	checkFinite(efficiency, "efficiency")
	if ratePerSecond < 0 then
		error("invalid ratePerSecond")
	end
	if maxSeconds < 0 then
		error("invalid maxSeconds")
	end
	if efficiency <= 0 or efficiency > 1 then
		error("invalid efficiency")
	end
	local elapsed = now - lastSeen
	if elapsed <= 0 then
		return 0
	end
	if elapsed > maxSeconds then
		elapsed = maxSeconds
	end
	return math.floor(ratePerSecond * elapsed * efficiency + EPSILON)
end

return OfflineIncome
