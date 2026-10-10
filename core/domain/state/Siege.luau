--!strict
-- Siege: recurring team-siege windows that open for a fixed duration each period.

local Siege = {}

export type Schedule = { period: number, duration: number }
export type Phase = "idle" | "active"

local function checkPositive(value: number, label: string): ()
	if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
		error("invalid " .. label)
	end
end

function Siege.new(period: number, duration: number): Schedule
	checkPositive(period, "period")
	checkPositive(duration, "duration")
	if duration >= period then
		error("invalid duration")
	end
	return { period = period, duration = duration }
end

-- Active during [k * period, k * period + duration) for integer k >= 1, so the
-- schedule is idle at time zero and the first window opens at one period.
function Siege.phase(s: Schedule, now: number): (Phase, number)
	if type(now) ~= "number" or now ~= now then
		error("invalid now")
	end
	local k = math.floor(now / s.period)
	local start = k * s.period
	if k >= 1 and now < start + s.duration then
		return "active", start + s.duration - now
	end
	local nextStart = if now < s.period then s.period else (k + 1) * s.period
	return "idle", nextStart - now
end

return Siege
