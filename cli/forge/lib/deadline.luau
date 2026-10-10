--!strict
local task = require("@lune/task")

-- Bounded deadline that survives Lune 0.10.5 timer handling.
--
-- `task.delay` registers a timer-wheel entry that `task.cancel` marks as
-- cancelled but does not remove. In a process that spawned a child, the
-- scheduler stays alive until that entry's deadline passes, so a cancelled
-- 30-second deadline still delays process exit by 30 seconds. Polling with a
-- short wait bounds the leftover entry to one tick, so a disarmed deadline
-- never keeps the process alive.
local TICK = 0.05

local M = {}

export type Disarm = () -> ()

function M.arm(seconds: number, onExpire: () -> ()): Disarm
	assert(seconds > 0, "deadline requires a positive duration")
	local stop = false
	local thread = task.spawn(function()
		local started = os.clock()
		while not stop and os.clock() - started < seconds do
			task.wait(TICK)
		end
		if not stop then
			onExpire()
		end
	end)
	return function()
		if stop then
			return
		end
		stop = true
		task.cancel(thread)
	end
end

return M
