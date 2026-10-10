--!strict
local M = {}
-- Seconds are binary64. Recover an integer millisecond boundary only when
-- converting that boundary back yields the identical seconds value and the
-- product is within one relative binary64 spacing. Genuine sub-ms values floor.
function M.millis(seconds: number): number
	local scaled = seconds * 1000
	local lower = math.floor(scaled)
	local upper = lower + 1
	if upper <= 2 ^ 53 - 1 and upper / 1000 == seconds and upper - scaled <= math.abs(scaled) * 2 ^ -52 then
		return upper
	end
	return lower
end
export type Clock = {
	now: () -> number,
	begin: () -> number,
	advanceTo: (number) -> number,
	advanceElapsed: (number) -> number,
}
function M.new(wall: () -> number): Clock
	local epoch = wall()
	local manual = false
	local base: number? = nil
	local function now(): number
		if not manual then
			epoch = math.max(epoch, wall())
		end
		return epoch
	end
	local function advanceTo(value: number): number
		assert(
			type(value) == "number" and value == value and math.abs(value) ~= math.huge and value >= epoch,
			"invalid QA clock"
		)
		manual, epoch = true, value
		return epoch
	end
	return {
		now = now,
		begin = function()
			assert(base == nil, "QA clock already begun")
			base = now()
			manual = true
			return epoch
		end,
		advanceTo = advanceTo,
		advanceElapsed = function(value: number)
			assert(base ~= nil and type(value) == "number" and value >= 0, "beginClock required / invalid elapsed time")
			return advanceTo((base :: number) + value)
		end,
	}
end
return M
