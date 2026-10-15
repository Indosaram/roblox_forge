--!strict
local Profile = require("./profile")

-- Fake clock: each call returns the next scripted second value.
local function scripted(values: { number }): () -> number
	local index = 0
	return function()
		index += 1
		local value = values[index]
		assert(value ~= nil, "fake clock exhausted")
		return value
	end
end

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-9
end

return {
	["span records exact durations and returns the function results"] = function()
		local p = Profile.new({ clock = scripted({ 0, 0.25, 1, 1.5, 2, 2.125 }) })
		local a, b = p:span("load", function()
			return 1, "two"
		end)
		assert(a == 1 and b == "two", "span forwards every result")
		p:span("load", function() end)
		p:span("render", function() end)
		local rows = p:report()
		assert(#rows == 2, "two names")
		assert(rows[1].name == "load" and rows[1].count == 2, "load first with count 2")
		assert(near(rows[1].totalMs, 750) and near(rows[1].maxMs, 500), "load totals 750ms max 500ms")
		assert(rows[2].name == "render" and rows[2].count == 1, "render second")
		assert(near(rows[2].totalMs, 125) and near(rows[2].maxMs, 125), "render 125ms")
	end,

	["start and stop pair per name and nest"] = function()
		local p = Profile.new({ clock = scripted({ 0, 1, 3, 10 }) })
		p:start("a")
		p:start("a")
		p:stop("a") -- inner: 3 - 1 = 2s
		p:stop("a") -- outer: 10 - 0 = 10s
		local row = p:report()[1]
		assert(row.count == 2 and near(row.totalMs, 12000) and near(row.maxMs, 10000), "nested spans accumulate")
	end,

	["stop without start errors"] = function()
		local p = Profile.new({ clock = scripted({ 0, 1 }) })
		local ok, err = pcall(function()
			p:stop("never")
		end)
		assert(not ok and string.find(tostring(err), "without a matching start", 1, true), "stop must error")
		p:start("x")
		p:stop("x")
		local ok2 = pcall(function()
			p:stop("x")
		end)
		assert(not ok2, "second stop errors")
	end,

	["a span that errors still records and rethrows"] = function()
		local p = Profile.new({ clock = scripted({ 0, 0.5 }) })
		local ok, err = pcall(function()
			p:span("boom", function()
				error("bad", 0)
			end)
		end)
		assert(not ok and err == "bad", "error propagates unchanged")
		local row = p:report()[1]
		assert(row.name == "boom" and row.count == 1 and near(row.totalMs, 500), "duration recorded")
	end,

	["report sorts by total descending with name tiebreak"] = function()
		local p = Profile.new({ clock = scripted({ 0, 1, 1, 2, 2, 5 }) })
		p:span("b", function() end)
		p:span("a", function() end)
		p:span("c", function() end)
		local rows = p:report()
		assert(rows[1].name == "c" and rows[2].name == "a" and rows[3].name == "b", "c(3s) then a,b tie by name")
	end,

	["text renders an aligned table honoring limit"] = function()
		local p = Profile.new({ clock = scripted({ 0, 2, 2, 3 }) })
		p:span("slow", function() end)
		p:span("fast", function() end)
		local full = string.split(p:text(), "\n")
		assert(#full == 3, "header plus two rows")
		assert(full[1] == "name    count       totalMs         maxMs", "header: " .. full[1])
		assert(full[2] == "slow        1      2000.000      2000.000", "row: " .. full[2])
		assert(full[3] == "fast        1      1000.000      1000.000", "row: " .. full[3])
		assert(#string.split(p:text(1), "\n") == 2, "limit 1 keeps header plus one row")
	end,

	["json carries schemaVersion 1 and the report rows"] = function()
		local p = Profile.new({ clock = scripted({ 0, 0.001 }) })
		p:span("x", function() end)
		local doc = p:json()
		assert(doc.schemaVersion == 1, "schemaVersion")
		assert(#doc.spans == 1 and doc.spans[1].name == "x" and near(doc.spans[1].totalMs, 1), "rows present")
	end,
}
