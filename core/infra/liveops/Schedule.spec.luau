--!strict

local Schedule = require("./Schedule")

local function events(): { { id: string, startsAt: number, endsAt: number, multipliers: { [string]: number }? } }
	return {
		{ id = "a", startsAt = 100, endsAt = 200, multipliers = { coin = 2 } },
		{ id = "b", startsAt = 150, endsAt = 300, multipliers = { coin = 3, xp = 5 } },
		{ id = "c", startsAt = 400, endsAt = 500 },
	}
end

return {
	["active: start is inclusive, end is exclusive"] = function()
		local schedule = Schedule.new(events())
		local atStart = schedule:active(100)
		assert(#atStart == 1, "expected one active event at start")
		assert(atStart[1].id == "a", "expected event a at its start")

		local atEnd = schedule:active(200)
		assert(#atEnd == 1, "expected one active event at end boundary")
		assert(atEnd[1].id == "b", "event a must be excluded at its end, b still active")
	end,

	["active: returns all overlapping events sorted by startsAt"] = function()
		local schedule = Schedule.new(events())
		local active = schedule:active(160)
		assert(#active == 2, "expected two overlapping events")
		assert(active[1].id == "a" and active[2].id == "b", "expected sort by startsAt")
	end,

	["active: empty when no event covers now"] = function()
		local schedule = Schedule.new(events())
		assert(#schedule:active(50) == 0, "expected no active events before any start")
		assert(#schedule:active(350) == 0, "expected no active events in the gap")
		assert(#schedule:active(500) == 0, "expected no active events at last end")
	end,

	["multiplier: stacks product across active events"] = function()
		local schedule = Schedule.new(events())
		assert(schedule:multiplier("coin", 160) == 6, "expected 2 * 3 for stacked coin")
		assert(schedule:multiplier("xp", 160) == 5, "expected xp from the single event that sets it")
	end,

	["multiplier: returns 1 when no active event sets the key"] = function()
		local schedule = Schedule.new(events())
		assert(schedule:multiplier("coin", 50) == 1, "expected neutral 1 with no active events")
		assert(schedule:multiplier("gems", 160) == 1, "expected neutral 1 when key is absent")
	end,

	["next: returns soonest event starting after now"] = function()
		local schedule = Schedule.new(events())
		local upcoming = schedule:next(100)
		assert(upcoming ~= nil and upcoming.id == "b", "expected b as the soonest upcoming")
		local later = schedule:next(160)
		assert(later ~= nil and later.id == "c", "expected c once b has started")
	end,

	["next: nil when no event starts in the future"] = function()
		local schedule = Schedule.new(events())
		assert(schedule:next(450) == nil, "expected nil after last start")
		assert(schedule:next(1000) == nil, "expected nil for a far-future now")
	end,

	["new: rejects endsAt not greater than startsAt"] = function()
		local ok = pcall(Schedule.new, { { id = "bad", startsAt = 200, endsAt = 100 } })
		assert(ok == false, "expected error for endsAt < startsAt")
		local equal = pcall(Schedule.new, { { id = "bad", startsAt = 100, endsAt = 100 } })
		assert(equal == false, "expected error for endsAt == startsAt")
	end,

	["new: rejects duplicate ids"] = function()
		local ok = pcall(Schedule.new, {
			{ id = "dup", startsAt = 0, endsAt = 10 },
			{ id = "dup", startsAt = 20, endsAt = 30 },
		})
		assert(ok == false, "expected error for duplicate ids")
	end,
}
