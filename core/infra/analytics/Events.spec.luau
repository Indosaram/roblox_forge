--!strict
-- Specs for Events: registry integrity, emit validation, sink dispatch, and counts.

local Events = require("./Events")

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["NAMES has exactly 12 unique entries"] = function()
		assert(#Events.NAMES == 12, "expected exactly 12 names, got " .. #Events.NAMES)
		local seen: { [string]: boolean } = {}
		for _, name in Events.NAMES do
			assert(type(name) == "string", "every name must be a string")
			assert(not seen[name], "duplicate name: " .. name)
			seen[name] = true
		end
	end,

	["every NAMES entry has a SCHEMA entry"] = function()
		for _, name in Events.NAMES do
			local schema = Events.SCHEMA[name]
			assert(schema ~= nil, "missing SCHEMA entry for " .. name)
		end
	end,

	["emit of unknown name errors"] = function()
		local emitter = Events.new(function(_name: string, _fields: { [string]: any }) end)
		expectError(function()
			emitter:emit("not_a_real_event", {})
		end, "unknown event")
	end,

	["emit missing a required field errors"] = function()
		local emitter = Events.new(function(_name: string, _fields: { [string]: any }) end)
		expectError(function()
			emitter:emit("egg_purchase", { eggId = "basic" })
		end, "missing price")
		expectError(function()
			emitter:emit("tutorial_step", {})
		end, "missing step")
		expectError(function()
			emitter:emit("robux_purchase", { productKey = "coins_100" })
		end, "missing price")
		assert(emitter:counts()["egg_purchase"] == nil, "failed emit must not count")
	end,

	["emit calls sink and increments counts"] = function()
		local seen: { { name: string, fields: { [string]: any } } } = {}
		local emitter = Events.new(function(name: string, fields: { [string]: any })
			table.insert(seen, { name = name, fields = fields })
		end)
		emitter:emit("egg_hatch", { eggId = "basic", kaijuId = "rex", rarity = "common" })
		emitter:emit("egg_hatch", { eggId = "basic", kaijuId = "rap", rarity = "rare" })
		assert(#seen == 2, "sink should be called once per emit, got " .. #seen)
		assert(seen[1].name == "egg_hatch", "sink receives the event name")
		assert(seen[1].fields.rarity == "common", "sink receives the fields")
		assert(seen[2].fields.kaijuId == "rap", "sink receives each emit's fields")
		local counts = emitter:counts()
		assert(counts["egg_hatch"] == 2, "egg_hatch count should be 2, got " .. tostring(counts["egg_hatch"]))
		assert(counts["session_start"] == nil, "unemitted event should not be counted")
	end,
}
