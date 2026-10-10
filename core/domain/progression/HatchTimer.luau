--!strict
-- HatchTimer: pure start, ready check, and remaining-time math for timed actions.

export type Timer = { startedAt: number, readyAt: number }

local HatchTimer = {}

function HatchTimer.start(now: number, duration: number): Timer
	if type(duration) ~= "number" or duration ~= duration or duration < 0 or duration == math.huge then
		error("invalid duration")
	end
	return { startedAt = now, readyAt = now + duration }
end

function HatchTimer.isReady(timer: Timer, now: number): boolean
	return now >= timer.readyAt
end

function HatchTimer.remaining(timer: Timer, now: number): number
	return math.max(0, timer.readyAt - now)
end

return HatchTimer
