--!strict
-- Specs for Distance: reach checks and movement plausibility.

local Distance = require("./Distance")

return {
	["withinReach accepts points inside the radius"] = function()
		assert(Distance.withinReach({ x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }, 5), "on the boundary")
		assert(Distance.withinReach({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, 5), "same point")
		assert(Distance.withinReach({ x = 1, y = 2, z = 3 }, { x = 2, y = 3, z = 4 }, 2), "inside")
	end,

	["withinReach rejects points outside the radius"] = function()
		assert(Distance.withinReach({ x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }, 4.9) == false, "just outside")
		assert(Distance.withinReach({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 10 }, 5) == false, "far on z")
	end,

	["movementPlausible accepts movement within the speed budget"] = function()
		assert(Distance.movementPlausible({ x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 }, 1, 10), "exact budget")
		assert(Distance.movementPlausible({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, 1, 10), "standing still")
	end,

	["movementPlausible rejects movement beyond the speed budget"] = function()
		assert(
			Distance.movementPlausible({ x = 0, y = 0, z = 0 }, { x = 11, y = 0, z = 0 }, 1, 10) == false,
			"faster than allowed"
		)
		assert(
			Distance.movementPlausible({ x = 0, y = 0, z = 0 }, { x = 5, y = 5, z = 0 }, 0.5, 10) == false,
			"three dimensions exceed the budget"
		)
	end,

	["movementPlausible rejects non-positive dt"] = function()
		assert(Distance.movementPlausible({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, 0, 10) == false, "zero dt")
		assert(
			Distance.movementPlausible({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, -1, 10) == false,
			"negative dt"
		)
	end,
}
