--!strict
-- Specs for HatchTimer: start math, readiness, remaining time, and validation.

local HatchTimer = require("./HatchTimer")

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["start records startedAt and readyAt"] = function()
		local timer = HatchTimer.start(100, 30)
		assert(timer.startedAt == 100, "startedAt")
		assert(timer.readyAt == 130, "readyAt")
	end,

	["not ready before readyAt"] = function()
		local timer = HatchTimer.start(0, 10)
		assert(HatchTimer.isReady(timer, 0) == false, "at start")
		assert(HatchTimer.isReady(timer, 9.999) == false, "just before ready")
	end,

	["ready at and after readyAt"] = function()
		local timer = HatchTimer.start(0, 10)
		assert(HatchTimer.isReady(timer, 10) == true, "at readyAt")
		assert(HatchTimer.isReady(timer, 25) == true, "after readyAt")
	end,

	["zero duration is ready immediately"] = function()
		local timer = HatchTimer.start(5, 0)
		assert(HatchTimer.isReady(timer, 5) == true, "ready at once")
		assert(HatchTimer.remaining(timer, 5) == 0, "no time left")
	end,

	["remaining counts down and never goes negative"] = function()
		local timer = HatchTimer.start(0, 10)
		assert(HatchTimer.remaining(timer, 3) == 7, "remaining mid")
		assert(HatchTimer.remaining(timer, 10) == 0, "remaining at ready")
		assert(HatchTimer.remaining(timer, 100) == 0, "remaining clamps to zero")
	end,

	["start rejects invalid durations"] = function()
		expectError(function()
			HatchTimer.start(0, -1)
		end, "negative duration")
		expectError(function()
			HatchTimer.start(0, 0 / 0)
		end, "NaN duration")
		expectError(function()
			HatchTimer.start(0, math.huge)
		end, "infinite duration")
	end,
}
