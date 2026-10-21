--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Fenced = require("./FencedStore")
local Memory = require("./MemoryBackend")

local function fixture()
	local memory = Memory.new()
	local calls, fail = 0, false
	local module = luau.load(fs.readFile("core/infra/data/DataStoreBackend.luau"), {
		environment = {
			-- A task library used to enable the old write-behind path. No queued
			-- callback is executed: the assertion requires the write itself to commit.
			task = { delay = function() end, spawn = function() end },
			game = {
				GetService = function()
					return {
						GetDataStore = function()
							return {
								UpdateAsync = function(_, key, transform)
									calls += 1
									assert(not fail, "WRITE_FAILED")
									local ok, value = memory.update(key, transform)
									assert(ok, "memory commit")
									return value
								end,
							}
						end,
					}
				end,
			},
		},
	})()
	return module.new("spec"), memory, function()
		return calls
	end, function(value)
		fail = value
	end
end

return {
	["DataStoreBackend acknowledges only durable commits and surfaces flush failure"] = function()
		local backend, memory, calls, fail = fixture()
		local store = Fenced.new(backend, {
			sessionId = "origin",
			leaseSeconds = 60,
			now = function()
				return 0
			end,
		})
		local token = assert(store:acquire("actor", function()
			return { items = 10 }
		end))
		token = assert(store:update(token, function(data)
			data.items = 9
			return data
		end))
		local _, record = memory.update("actor", function(old)
			return old
		end)
		assert(record.data.items == 9 and calls() == 2, "acknowledged item mutation must be durable")
		fail(true)
		local updated = store:update(token, function(data)
			data.items = 8
			return data
		end)
		assert(updated == nil, "failed durable write cannot acknowledge a local candidate")
	end,
	["DataStoreBackend stale lease cannot execute transform or overwrite destination"] = function()
		local backend = fixture()
		local now = 0
		local function store(owner)
			return Fenced.new(backend, {
				sessionId = owner,
				leaseSeconds = 60,
				now = function()
					return now
				end,
			})
		end
		local origin, destination = store("origin"), store("destination")
		local stale = assert(origin:acquire("actor", function()
			return { items = 10 }
		end))
		now = 61
		local current = assert(destination:acquire("actor", function(data)
			return data
		end))
		local transforms = 0
		local updated, reason = origin:update(stale, function(data)
			transforms += 1
			data.items = 0
			return data
		end)
		assert(updated == nil and reason == "lease lost" and transforms == 0, "stale transform must not execute")
		assert(not origin:release(stale), "stale release cannot unlock destination")
		assert(destination:renew(current), "destination ownership survives stale callback")
	end,
}
