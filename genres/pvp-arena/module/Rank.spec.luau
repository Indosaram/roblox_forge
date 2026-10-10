--!strict
-- Specs for Rank: standard Elo updates, conservation without floor, and zero floor.

local Rank = require("./Rank")

local function close(a: number, b: number, message: string): ()
	assert(math.abs(a - b) < 1e-9, message .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

return {
	["equal ratings win awards k/2"] = function()
		local newA, newB = Rank.update(1000, 1000, 1, 20)
		close(newA, 1010, "winner gains k/2")
		close(newB, 990, "loser drops k/2")
	end,

	["equal ratings loss subtracts k/2"] = function()
		local newA, newB = Rank.update(1000, 1000, 0, 20)
		close(newA, 990, "loser drops k/2")
		close(newB, 1010, "winner gains k/2")
	end,

	["equal ratings draw changes nothing"] = function()
		local newA, newB = Rank.update(1000, 1000, 0.5, 32)
		close(newA, 1000, "A unchanged on draw")
		close(newB, 1000, "B unchanged on draw")
	end,

	["rating sum is conserved without the floor"] = function()
		local newA, newB = Rank.update(1200, 800, 1, 30)
		close(newA + newB, 2000, "sum conserved")
	end,

	["rating floors at zero"] = function()
		local newA, newB = Rank.update(0, 0, 0, 100)
		close(newA, 0, "loser floored at zero")
		close(newB, 50, "winner gains k/2")
	end,
}
