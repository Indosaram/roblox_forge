--!strict
-- Pure validation for a pushed LiveOps `kind = "event"` broadcast (see
-- Broadcast.luau and renderLiveopsYml's starter `double-coins` event). No
-- Roblox APIs, so this runs under Lune specs to exercise the exact boundary
-- Server.luau's applyLiveopsEvent enforces before a broadcast can touch the
-- runtime coin multiplier.
--
-- Broadcast's JSON decoder round-trips whatever `tonumber` accepts (`1e999`
-- becomes inf, an out-of-range multiplier can be published straight to the
-- `forge-liveops` topic), so the multiplier and duration must be checked as
-- finite and bounded here rather than trusted as "some number > 0".

local LiveopsEvent = {}

-- A pushed event cannot multiply coin production by more than this, no matter
-- what a broadcast claims.
LiveopsEvent.MAX_MULTIPLIER = 10

-- A pushed event cannot run longer than one day.
LiveopsEvent.MAX_DURATION_SECONDS = 86400

-- The effective coin multiplier the Heartbeat tick may ever apply, even when
-- several valid (<= MAX_MULTIPLIER each) pushed events overlap in time.
-- Schedule.multiplier multiplies every active event's multiplier together, so
-- two valid 10x pushes stacked on top of each other would otherwise reach
-- 100x; this is the effective-schedule-multiplier cap the production
-- boundary (Server.luau's Heartbeat tick) enforces on the merged result.
LiveopsEvent.MAX_EFFECTIVE_MULTIPLIER = LiveopsEvent.MAX_MULTIPLIER

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--- Validates a pushed event's `data` table. Returns (multiplier,
--- durationSeconds) for a payload that may be applied to the runtime
--- schedule, or (nil, nil) for anything nonfinite, out of range, or the
--- wrong shape. durationSeconds must additionally be a whole number of
--- seconds (Broadcast/JSON has no separate integer type).
function LiveopsEvent.validate(data: { [string]: any }): (number?, number?)
	local multiplier = data.multiplier
	local durationSeconds = data.durationSeconds

	if not isFiniteNumber(multiplier) then
		return nil, nil
	end
	if multiplier <= 0 or multiplier > LiveopsEvent.MAX_MULTIPLIER then
		return nil, nil
	end

	if not isFiniteNumber(durationSeconds) then
		return nil, nil
	end
	if durationSeconds ~= math.floor(durationSeconds) then
		return nil, nil
	end
	if durationSeconds <= 0 or durationSeconds > LiveopsEvent.MAX_DURATION_SECONDS then
		return nil, nil
	end

	return multiplier, durationSeconds
end

--- Clamps the merged schedule's coin multiplier to MAX_EFFECTIVE_MULTIPLIER.
-- Each pushed event is already bounded at MAX_MULTIPLIER by `validate`, but
-- Schedule.multiplier multiplies every active event together, so two or more
-- valid pushes overlapping in time can still stack past the intended cap.
-- This clamps only the number the Heartbeat tick feeds into Loop.tick/
-- Production.accrue/Wallet.credit; Schedule itself (and its static-schedule
-- behavior) is untouched.
function LiveopsEvent.effectiveMultiplier(rawMultiplier: number): number
	return math.min(rawMultiplier, LiveopsEvent.MAX_EFFECTIVE_MULTIPLIER)
end

return LiveopsEvent
