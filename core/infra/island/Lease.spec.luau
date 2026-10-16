--!strict
-- QA-LEASE-01: two servers race for one island -> exactly one owner. Negative:
-- after the MemoryStore display entry expires/is evicted, the old owner's
-- DataStore write is rejected by the FencedStore fencing token, and no accepted
-- delta is lost. Display entries never confer authority.

local FencedStore = require("../data/FencedStore")
local MemoryBackend = require("../data/MemoryBackend")
local IslandDirectory = require("./IslandDirectory")
local Lease = require("./Lease")

local LEASE_SECONDS = 30

type World = {
	backend: MemoryBackend.Memory,
	display: IslandDirectory.MemoryMap,
	advance: (number) -> (),
	server: (string) -> Lease.Lease,
}

local function world(): World
	local now = 0
	local function clock(): number
		return now
	end
	local backend = MemoryBackend.new()
	local display = IslandDirectory.memoryMap(clock)
	return {
		backend = backend,
		display = display,
		advance = function(seconds: number)
			now += seconds
		end,
		server = function(id: string): Lease.Lease
			return Lease.new({
				store = FencedStore.new(backend, { sessionId = id, leaseSeconds = LEASE_SECONDS, now = clock }),
				serverId = id,
				display = display,
				displayTtlSeconds = 10,
			})
		end,
	}
end

local function persisted(backend: MemoryBackend.Memory, islandId: string): any
	local _, record = backend.update(Lease.key(islandId), function(old)
		return old
	end)
	return record
end

return {
	["two servers acquiring the same island yield exactly one owner"] = function()
		local w = world()
		local a, b = w.server("srv-a"), w.server("srv-b")
		local ha, ea = a:acquire("isl-1")
		local hb, eb = b:acquire("isl-1")
		local owners = (if ha then 1 else 0) + (if hb then 1 else 0)
		assert(owners == 1, "exactly one owner, got " .. owners)
		assert(ha and ea == nil and hb == nil and eb == "locked", "second acquirer is locked out")
		assert(persisted(w.backend, "isl-1").lease.sessionId == "srv-a", "authoritative lease records owner")
	end,

	["display eviction does not grant ownership while the fenced lease lives"] = function()
		local w = world()
		local a, b = w.server("srv-a"), w.server("srv-b")
		assert(a:acquire("isl-1"))
		w.display.evict("lease:isl-1")
		assert(b:displayedOwner("isl-1") == nil, "display entry gone")
		local hb, err = b:acquire("isl-1")
		assert(hb == nil and err == "locked", "authority is FencedStore, not MemoryStore")
	end,

	["NEGATIVE: old owner write after display expiry is fenced and loses no delta"] = function()
		local w = world()
		local a, b = w.server("srv-a"), w.server("srv-b")
		local ha = assert(a:acquire("isl-1"))
		ha = assert(a:write(ha, { id = "d1", op = "place", payload = { x = 1 } }))
		ha = assert(a:write(ha, { id = "d2", op = "place", payload = { x = 2 } }))

		-- Display entry expires (TTL 10s), then the fenced lease lapses (30s).
		w.advance(11)
		assert(a:displayedOwner("isl-1") == nil, "display entry expired")
		w.advance(LEASE_SECONDS)
		local hb = assert(b:acquire("isl-1"))
		assert(hb.profile.generation == ha.profile.generation + 1, "takeover advances the fencing generation")

		local stale, err = a:write(ha, { id = "d3", op = "place", payload = { x = 3 } })
		assert(
			stale == nil and err == "lease lost",
			"old server write rejected by fencing token, got " .. tostring(err)
		)
		local renewed, renewErr = a:renew(ha)
		assert(renewed == nil and renewErr == "lease lost", "old server cannot resurrect its lease")

		-- The rejected delta is handed back to the caller and re-routed to the new owner.
		hb = assert(b:write(hb, { id = "d3", op = "place", payload = { x = 3 } }))
		local record = persisted(w.backend, "isl-1")
		local ids = {}
		for _, delta in record.data.deltas do
			table.insert(ids, delta.id)
		end
		assert(table.concat(ids, ",") == "d1,d2,d3", "delta loss 0, got " .. table.concat(ids, ","))
		assert(record.lease.sessionId == "srv-b", "new owner holds the authoritative lease")
	end,

	["replayed delta receipt is idempotent"] = function()
		local w = world()
		local a = w.server("srv-a")
		local h = assert(a:acquire("isl-1"))
		h = assert(a:write(h, { id = "d1", op = "place" }))
		h = assert(a:write(h, { id = "d1", op = "place" }))
		assert(#persisted(w.backend, "isl-1").data.deltas == 1, "duplicate receipt not appended twice")
	end,

	["release frees the island for the next server"] = function()
		local w = world()
		local a, b = w.server("srv-a"), w.server("srv-b")
		local h = assert(a:acquire("isl-1"))
		assert(a:release(h))
		assert(b:acquire("isl-1"), "released island is acquirable")
		assert(a:write(h, { id = "late", op = "place" }) == nil, "released token cannot write")
	end,
}
