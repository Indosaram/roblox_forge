--!strict
-- Specs for Production: fractional accrual, no long-run drift, and validation.

local Production = require("./Production")

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["new accumulator starts empty"] = function()
		local acc = Production.new()
		assert(acc.carry == 0, "carry starts at 0")
	end,

	["accrue floors fractional output and carries the remainder"] = function()
		local acc = Production.new()
		assert(Production.accrue(acc, 1.5, 0.1) == 0, "no whole coin yet")
		assert(math.abs(acc.carry - 0.15) < 1e-9, "carry 0.15, got " .. tostring(acc.carry))
	end,

	["accrue emits whole coins at integer rates"] = function()
		local acc = Production.new()
		assert(Production.accrue(acc, 10, 2) == 20, "20 coins")
		assert(acc.carry == 0, "no carry")
	end,

	["ten fractional ticks produce exactly one coin with carry 0.5"] = function()
		local acc = Production.new()
		local total = 0
		for _ = 1, 10 do
			total += Production.accrue(acc, 1.5, 0.1)
		end
		assert(total == 1, "exactly one coin, got " .. tostring(total))
		assert(math.abs(acc.carry - 0.5) < 1e-9, "carry 0.5, got " .. tostring(acc.carry))
	end,

	["one thousand small ticks produce exactly three coins"] = function()
		local acc = Production.new()
		local total = 0
		for _ = 1, 1000 do
			total += Production.accrue(acc, 0.3, 0.01)
		end
		assert(total == 3, "exactly three coins, got " .. tostring(total))
	end,

	["accrue rejects invalid rate or dt"] = function()
		local acc = Production.new()
		expectError(function()
			Production.accrue(acc, -1, 1)
		end, "negative rate")
		expectError(function()
			Production.accrue(acc, 0 / 0, 1)
		end, "NaN rate")
		expectError(function()
			Production.accrue(acc, math.huge, 1)
		end, "infinite rate")
		expectError(function()
			Production.accrue(acc, 1, -1)
		end, "negative dt")
		expectError(function()
			Production.accrue(acc, 1, 0 / 0)
		end, "NaN dt")
		expectError(function()
			Production.accrue(acc, 1, math.huge)
		end, "infinite dt")
	end,
}
