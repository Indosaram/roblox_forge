--!strict
local Documents = require("./ActorDocumentStore")
local Memory = require("./MemoryBackend")

local function options(id: string): any
	return {
		sessionId = id,
		leaseSeconds = 30,
		now = function()
			return 0
		end,
	}
end

return {
	["handoff cannot drain while an actor transaction is active"] = function()
		local store = Documents.new(Memory.new(), options("a"), "expedition")
		assert(
			store.transaction("123", function(data)
				assert(not store.drain("123").ok, "in-flight mutation blocks handoff")
				assert(not store.releaseActor("123").ok, "in-flight mutation retains fence")
				data.count = 1
				return { ok = true }
			end).ok,
			"transaction committed"
		)
		assert(store.drain("123").ok, "committed transaction permits handoff")
		assert(store.close().ok, "lease released")
	end,
	["refused candidates cannot mutate durable documents and release fences another server"] = function()
		local backend = Memory.new()
		local a = Documents.new(backend, options("a"), "expedition")
		local b = Documents.new(backend, options("b"), "expedition")
		assert(
			a.transaction("123", function(data)
				data.count = 4
				return { ok = true }
			end).ok,
			"initial document committed"
		)
		assert(not a.transaction("123", function(data)
			data.count = 0
			return { ok = false, reason = "refused" }
		end).ok, "refused candidate rejected")
		assert(a.snapshot("123").count == 4, "refusal preserved durable value")
		assert(not b.transaction("123", function(data)
			data.count = 99
			return { ok = true }
		end).ok, "foreign lease rejected")
		assert(a.releaseActor("123").ok, "release acknowledged")
		assert(not a.transaction("123", function()
			return { ok = true }
		end).ok, "released actor cannot reacquire implicitly")
		assert(b.snapshot("123").count == 4, "new server reads conserved state")
		assert(b.close().ok, "new server released lease")
		assert(a.resumeActor("123").ok, "source resume reacquires lease")
		assert(a.snapshot("123").count == 4, "resume preserves durable state")
		assert(a.close().ok, "source closed")
	end,
	["failed commit acknowledgment never returns successful transform result"] = function()
		local memory = Memory.new()
		local fail = false
		local store = Documents.new({
			update = function(key, transform)
				local ok, value = memory.update(key, transform)
				return if fail then false else ok, value
			end,
		}, options("a"), "expedition")
		assert(store.snapshot("123"), "initial acquisition acknowledged")
		fail = true
		local result = store.transaction("123", function(data)
			data.count = 1
			return { ok = true }
		end)
		assert(not result.ok, "ambiguous commit cannot acknowledge success")
	end,
}
