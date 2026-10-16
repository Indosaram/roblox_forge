--!strict
-- Specs for Events: registry integrity, emit validation, sink dispatch, and counts.

local Events = require("./Events")

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["NAMES has exactly 19 unique entries"] = function()
		assert(#Events.NAMES == 19, "expected exactly 19 names, got " .. #Events.NAMES)
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

	["survival events are registered with typed schemas"] = function()
		assert(#Events.SURVIVAL == 7, "seven survival events")
		for _, name in Events.SURVIVAL do
			assert(table.find(Events.NAMES, name) ~= nil, "survival event in NAMES: " .. name)
			local types = Events.TYPES[name]
			assert(types ~= nil, "typed schema for " .. name)
			for _, required in Events.SCHEMA[name] do
				assert(types[required] ~= nil, name .. " types its required field " .. required)
			end
		end
		assert(Events.TYPES.gather.ratePerMinute == "number", "gather carries a rate anomaly input")
		assert(Events.TYPES.travel.pathRepeatId == "string", "travel carries a path repetition id")
		assert(
			Events.TYPES.trade.transferGiven == "count" and Events.TYPES.trade.transferReceived == "count",
			"trade carries one-way transfer ratio inputs"
		)
	end,

	["survival emit validates payload types"] = function()
		local seen = 0
		local emitter = Events.new(function(_name: string, _fields: { [string]: any })
			seen += 1
		end)
		emitter:emit("gather", { actorId = "a", nodeId = "bush-1", quantity = 3, ratePerMinute = 12.5 })
		emitter:emit("trade", {
			actorId = "a",
			counterpartyId = "b",
			itemId = "wood",
			quantity = 2,
			transferGiven = 2,
			transferReceived = 0,
		})
		expectError(function()
			emitter:emit("gather", { actorId = "a", nodeId = "bush-1", quantity = -1 })
		end, "negative count")
		expectError(function()
			emitter:emit("gather", { actorId = "a", nodeId = "bush-1", quantity = 1.5 })
		end, "fractional count")
		expectError(function()
			emitter:emit("craft", { actorId = "", recipeId = "r", jobId = "j" })
		end, "empty string")
		expectError(function()
			emitter:emit("death", { actorId = "a", cause = "fall", atMillis = math.huge })
		end, "non-finite number")
		expectError(function()
			emitter:emit("tame", { actorId = "a", creatureId = "c" })
		end, "missing speciesId")
		assert(seen == 2, "only valid survival emits reach the sink, got " .. seen)
		local counts = emitter:counts()
		assert(counts.gather == 1 and counts.trade == 1, "valid emits are counted once")
		assert(counts.tame == nil and counts.craft == nil, "invalid emits are not counted")
	end,
}
