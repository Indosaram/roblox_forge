--!strict
-- Specs for ProfileSchema: versioned migration steps and future-version rejection.

local ProfileSchema = require("./ProfileSchema")

return {
	["migration from version 1 applies the step"] = function()
		local data = ProfileSchema.migrate({ version = 1, coins = 5 }, 2, function()
			return { coins = 0, gems = 0 }
		end, {
			[1] = function(record)
				record.coins += 10
				return record
			end,
		})
		assert(data.version == 2, "version bumped to current")
		assert(data.coins == 15, "step applied to stored data")
		assert(data.gems == 0, "missing key filled from defaults")
	end,

	["future version errors"] = function()
		local ok, err = pcall(function()
			ProfileSchema.migrate({ version = 3 }, 2, function()
				return {}
			end, {})
		end)
		assert(not ok, "expected a future version error")
		assert(string.find(tostring(err), "future version") ~= nil, "message mentions future version")
	end,

	["rename migration reads the stored value before defaults are applied"] = function()
		local data = ProfileSchema.migrate({ version = 1, coins = 5 }, 2, function()
			return { gold = 0 }
		end, {
			[1] = function(record)
				record.gold = record.gold or record.coins
				record.coins = nil
				return record
			end,
		})
		assert(data.version == 2, "version bumped to current")
		assert(data.gold == 5, "rename migration preserves the stored value, got " .. tostring(data.gold))
	end,

	["fractional version is treated as corrupt and every step runs"] = function()
		local raw = { version = 0.5, ran = {} }
		local data = ProfileSchema.migrate(raw, 2, function()
			return { ran = {} }
		end, {
			[0] = function(record)
				table.insert(record.ran, 0)
				return record
			end,
			[1] = function(record)
				table.insert(record.ran, 1)
				return record
			end,
		})
		assert(data.version == 2, "fractional version still lands on current")
		assert(#data.ran == 2, "both steps ran for a fractional version, got " .. tostring(#data.ran))
		assert(#raw.ran == 0, "migration must not mutate the caller's raw payload")
	end,

	["NaN version is treated as corrupt and every step runs"] = function()
		local raw = { version = 0 / 0, ran = {} }
		local data = ProfileSchema.migrate(raw, 2, function()
			return { ran = {} }
		end, {
			[0] = function(record)
				table.insert(record.ran, 0)
				return record
			end,
			[1] = function(record)
				table.insert(record.ran, 1)
				return record
			end,
		})
		assert(data.version == 2, "NaN version still lands on current")
		assert(#data.ran == 2, "both steps ran for a NaN version, got " .. tostring(#data.ran))
		assert(#raw.ran == 0, "migration must not mutate the caller's raw payload")
	end,

	["a step that mutates a nested table does not mutate the caller's raw payload"] = function()
		local raw = { version = 0, inv = { "x" } }
		local data = ProfileSchema.migrate(raw, 1, function()
			return {}
		end, {
			[0] = function(record)
				table.insert(record.inv, "y")
				return record
			end,
		})
		assert(#data.inv == 2, "the returned data reflects the migration step")
		assert(#raw.inv == 1, "the caller's raw payload must be untouched, got " .. tostring(#raw.inv))
	end,
}
