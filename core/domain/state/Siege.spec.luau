--!strict
-- Specs for Siege: window boundaries and parameter validation.

local Siege = require("./Siege")

return {
	["phase is idle at time zero"] = function()
		local schedule = Siege.new(10, 2)
		local phase, untilChange = Siege.phase(schedule, 0)
		assert(phase == "idle", "time zero should be idle")
		assert(untilChange == 10, "idle until the first period")
	end,

	["phase is active at exactly one period"] = function()
		local schedule = Siege.new(10, 2)
		local phase, untilChange = Siege.phase(schedule, 10)
		assert(phase == "active", "one period should open the window")
		assert(untilChange == 2, "active until the window closes")
	end,

	["phase is idle again at period plus duration"] = function()
		local schedule = Siege.new(10, 2)
		local phase, untilChange = Siege.phase(schedule, 12)
		assert(phase == "idle", "window end should be idle")
		assert(untilChange == 8, "idle until the next period")
	end,

	["new rejects invalid parameters"] = function()
		assert(not (pcall(function()
			Siege.new(0, 1)
		end)), "zero period")
		assert(not (pcall(function()
			Siege.new(10, 0)
		end)), "zero duration")
		assert(not (pcall(function()
			Siege.new(10, 10)
		end)), "duration equal to period")
	end,
}
