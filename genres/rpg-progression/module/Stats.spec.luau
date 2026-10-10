--!strict
-- Specs for Stats: xp curve, level lookup, and stat-point accrual.

local Stats = require("./Stats")

local function newConfig(): Stats.Config
	return { base = 100, exp = 2, pointsPerLevel = 2 }
end

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["xpForLevel follows base * level ^ exp"] = function()
		local config = newConfig()
		assert(Stats.xpForLevel(config, 1) == 100, "level 1 needs 100")
		assert(Stats.xpForLevel(config, 2) == 400, "level 2 needs 400")
		assert(Stats.xpForLevel(config, 4) == 1600, "level 4 needs 1600")
	end,

	["levelForXp maps cumulative xp to the highest level"] = function()
		local config = newConfig()
		assert(Stats.levelForXp(config, 0) == 1, "0 xp is level 1")
		assert(Stats.levelForXp(config, 99) == 1, "below the first threshold")
		assert(Stats.levelForXp(config, 100) == 2, "the first threshold reaches level 2")
		assert(Stats.levelForXp(config, 499) == 2, "one short of level 3")
		assert(Stats.levelForXp(config, 500) == 3, "100 + 400 reaches level 3")
	end,

	["addXp reports the new level and levels gained and grants points"] = function()
		local state = Stats.new(newConfig())
		local level, gained = Stats.addXp(state, 500)
		assert(level == 3, "500 xp reaches level 3, got " .. tostring(level))
		assert(gained == 2, "two levels gained, got " .. tostring(gained))
		assert(state.points == 4, "two points per level")
		assert(state.xp == 0, "xp is consumed by the levels")
	end,

	["addXp keeps partial xp toward the next level"] = function()
		local state = Stats.new(newConfig())
		local level, gained = Stats.addXp(state, 250)
		assert(level == 2, "250 xp reaches level 2")
		assert(gained == 1, "one level gained")
		assert(state.xp == 150, "150 xp carries over, got " .. tostring(state.xp))
		assert(state.points == 2, "one level of points")
	end,

	["addXp without enough xp does not level up"] = function()
		local state = Stats.new(newConfig())
		local level, gained = Stats.addXp(state, 99)
		assert(level == 1, "still level 1")
		assert(gained == 0, "no level gained")
		assert(state.points == 0, "no points yet")
		assert(state.xp == 99, "xp accrues toward the next level")
	end,

	["invalid curve values and amounts are rejected"] = function()
		expectError(function()
			Stats.xpForLevel(newConfig(), 0)
		end, "level must be at least 1")
		expectError(function()
			Stats.new({ base = 0, exp = 2, pointsPerLevel = 2 })
		end, "base must be positive")
		expectError(function()
			Stats.new({ base = 100, exp = -1, pointsPerLevel = 2 })
		end, "exp must be positive")
		expectError(function()
			Stats.addXp(Stats.new(newConfig()), -1)
		end, "amount must not be negative")
	end,
}
