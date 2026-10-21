--!strict
local Schema = require("./Schema")

local tests = {}

tests["closed objects validate nested fields and refuse unknown authority fields"] = function()
	local descriptor = Schema.tuple({
		Schema.object({
			plot = Schema.string({ maxLen = 128 }),
			position = Schema.optional(
				Schema.object({ x = Schema.number(), y = Schema.number(), z = Schema.number() })
			),
		}),
	})
	assert(Schema.check(descriptor, { { plot = "plot-1" } }), "optional position")
	assert(Schema.check(descriptor, { { plot = "plot-1", position = { x = 0, y = 2, z = 0 } } }), "nested position")
	assert(not Schema.check(descriptor, { { plot = "plot-1", owner = "forged" } }), "unknown owner refused")
	assert(not Schema.check(descriptor, { { position = { x = 0, y = 2, z = 0 } } }), "required field refused")
	assert(
		not Schema.check(descriptor, { { plot = "plot-1", position = { x = 0, y = 2, z = math.huge } } }),
		"infinite coordinate refused"
	)
end

tests["number accepts number"] = function()
	local t = Schema.tuple({ Schema.number() })
	assert(Schema.check(t, { 1 }), "1 should be a valid number")
	assert(Schema.check(t, { -3.5 }), "-3.5 should be a valid number")
end

tests["number rejects non-number"] = function()
	local t = Schema.tuple({ Schema.number() })
	local ok, msg = Schema.check(t, { "x" })
	assert(not ok, "a string is not a number")
	assert(msg == "arg 1: expected number", msg)
end

tests["number enforces min and max"] = function()
	local t = Schema.tuple({ Schema.number({ min = 0, max = 10 }) })
	assert(Schema.check(t, { 0 }), "0 is within range")
	assert(Schema.check(t, { 10 }), "10 is within range")
	local ok, msg = Schema.check(t, { 11 })
	assert(not ok and msg == "arg 1: out of range", tostring(msg))
	ok, msg = Schema.check(t, { -1 })
	assert(not ok and msg == "arg 1: out of range", tostring(msg))
end

tests["number enforces integer"] = function()
	local t = Schema.tuple({ Schema.number({ integer = true }) })
	assert(Schema.check(t, { 4 }), "4 is an integer")
	local ok, msg = Schema.check(t, { 4.5 })
	assert(not ok and msg == "arg 1: expected integer", tostring(msg))
end

tests["number rejects NaN"] = function()
	local t = Schema.tuple({ Schema.number() })
	assert(not Schema.check(t, { 0 / 0 }), "NaN must be rejected")
end

tests["number rejects infinity"] = function()
	local t = Schema.tuple({ Schema.number() })
	assert(not Schema.check(t, { math.huge }), "+inf must be rejected")
	assert(not Schema.check(t, { -math.huge }), "-inf must be rejected")
end

tests["string accepts and enforces maxLen"] = function()
	local t = Schema.tuple({ Schema.string({ maxLen = 3 }) })
	assert(Schema.check(t, { "abc" }), "3 chars is within maxLen")
	local ok, msg = Schema.check(t, { "abcd" })
	assert(not ok and msg == "arg 1: too long", tostring(msg))
end

tests["string enforces pattern"] = function()
	local t = Schema.tuple({ Schema.string({ pattern = "^%d+$" }) })
	assert(Schema.check(t, { "123" }), "digits match the pattern")
	local ok, msg = Schema.check(t, { "12a" })
	assert(not ok and msg == "arg 1: pattern mismatch", tostring(msg))
end

tests["boolean accepts booleans"] = function()
	local t = Schema.tuple({ Schema.boolean() })
	assert(Schema.check(t, { true }), "true is a boolean")
	assert(Schema.check(t, { false }), "false is a boolean")
	local ok, msg = Schema.check(t, { 1 })
	assert(not ok and msg == "arg 1: expected boolean", tostring(msg))
end

tests["enum accepts members and rejects others"] = function()
	local t = Schema.tuple({ Schema.enum({ "a", "b" }) })
	assert(Schema.check(t, { "a" }), "a is a member")
	local ok, msg = Schema.check(t, { "c" })
	assert(not ok and msg == "arg 1: not in enum", tostring(msg))
end

tests["optional accepts nil"] = function()
	local t = Schema.tuple({ Schema.optional(Schema.number()) })
	assert(Schema.check(t, { nil }), "nil is allowed for an optional")
	assert(Schema.check(t, { 5 }), "a number is allowed for an optional")
end

tests["optional validates its inner type"] = function()
	local t = Schema.tuple({ Schema.optional(Schema.number()) })
	local ok, msg = Schema.check(t, { "x" })
	assert(not ok and msg == "arg 1: expected number", tostring(msg))
end

tests["missing required arg is rejected"] = function()
	local t = Schema.tuple({ Schema.number() })
	local ok, msg = Schema.check(t, {})
	assert(not ok and msg == "arg 1: expected number", tostring(msg))
end

tests["too many args are rejected"] = function()
	local t = Schema.tuple({ Schema.number() })
	local ok, msg = Schema.check(t, { 1, 2 })
	assert(not ok and msg == "too many args", tostring(msg))
end

tests["args are reported by position"] = function()
	local t = Schema.tuple({ Schema.number(), Schema.string() })
	assert(Schema.check(t, { 1, "a" }), "a valid pair should pass")
	local ok, msg = Schema.check(t, { 1, 2 })
	assert(not ok and msg == "arg 2: expected string", tostring(msg))
end

tests["unknown remote is rejected"] = function()
	local registry = Schema.define({ ping = Schema.tuple({ Schema.number() }) })
	local ok, msg = registry:validate("nope", { 1 })
	assert(not ok and msg == "unknown remote: nope", tostring(msg))
end

tests["known remote validates its tuple"] = function()
	local registry = Schema.define({ ping = Schema.tuple({ Schema.number() }) })
	assert(registry:validate("ping", { 1 }), "a valid ping should pass")
	local ok, msg = registry:validate("ping", { "x" })
	assert(not ok and msg == "arg 1: expected number", tostring(msg))
end

return tests
