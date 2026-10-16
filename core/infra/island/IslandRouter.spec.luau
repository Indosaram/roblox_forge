--!strict
-- Specs for IslandRouter composition: allocator-driven placement onto existing
-- or freshly reserved islands, lease-gated hosting, heartbeat withdrawal on
-- lease loss, and origin fallback when routing or teleport fails.

local FencedStore = require("../data/FencedStore")
local MemoryBackend = require("../data/MemoryBackend")
local IslandDirectory = require("./IslandDirectory")
local IslandRouter = require("./IslandRouter")
local Lease = require("./Lease")
local Teleport = require("./Teleport")
local serde = require("@lune/serde")

-- Minimal stand-in for core/domain/island/Allocation: fill the fullest island
-- that still has room, otherwise ask for a new one.
local fillFirst: IslandRouter.Allocator = {
	choose = function(islands, partySize, capacity): IslandRouter.Choice
		local best: IslandRouter.IslandView? = nil
		for _, island in islands do
			if island.population + partySize <= capacity and (best == nil or island.population > best.population) then
				best = island
			end
		end
		if best then
			return { kind = "existing", islandId = best.islandId }
		end
		return { kind = "new" }
	end,
}

type World = {
	backend: MemoryBackend.Memory,
	map: IslandDirectory.MemoryMap,
	advance: (number) -> (),
	router: (serverId: string, teleportOk: boolean?) -> (IslandRouter.Router, { string }),
}

local function world(): World
	local now = 0
	local function clock(): number
		return now
	end
	local backend = MemoryBackend.new()
	local map = IslandDirectory.memoryMap(clock)
	local reserved = 0
	return {
		backend = backend,
		map = map,
		advance = function(seconds: number)
			now += seconds
		end,
		router = function(serverId: string, teleportOk: boolean?)
			local codes: { string } = {}
			local directory = IslandDirectory.new(map, {
				ttlSeconds = 60,
				encode = function(value)
					return serde.encode("json", value)
				end,
			})
			local router = IslandRouter.new({
				allocator = fillFirst,
				directory = directory,
				lease = Lease.new({
					store = FencedStore.new(backend, { sessionId = serverId, leaseSeconds = 30, now = clock }),
					serverId = serverId,
					display = map,
				}),
				teleport = Teleport.new({
					port = {
						teleport = function(_placeId, _ids, accessCode): (boolean, string?)
							table.insert(codes, accessCode)
							return teleportOk ~= false, if teleportOk == false then "down" else nil
						end,
					},
					commit = function(): (boolean, string?)
						return true, nil
					end,
					sleep = function() end,
				}),
				reserve = function(): (IslandRouter.Reservation?, string?)
					reserved += 1
					return { islandId = "isl-" .. reserved, accessCode = "code-" .. reserved }, nil
				end,
				placeId = 4242,
				capacity = 2,
			})
			return router, codes
		end,
	}
end

return {
	["routes onto a hosted island until full, then reserves a new one"] = function()
		local w = world()
		local host = w.router("island-srv")
		local handle = assert(host:host("isl-a", "code-a", 1))
		local origin, codes = w.router("origin")
		local first = origin:route(1)
		assert(first.status == "arrived" and first.islandId == "isl-a" and codes[1] == "code-a", "joins hosted island")
		assert(host:heartbeat(handle, "code-a", 2), "owner heartbeat refreshes population")
		local second = origin:route(2)
		assert(second.status == "arrived" and second.islandId == "isl-1", "full island -> reserved server")
		assert(codes[2] == "code-1", "teleport used the reserved access code")
	end,

	["NEGATIVE: second server cannot host an island it does not own"] = function()
		local w = world()
		local a = w.router("srv-a")
		local b = w.router("srv-b")
		assert(a:host("isl-a", "code-a", 0))
		local handle, err = b:host("isl-a", "code-evil", 0)
		assert(handle == nil and err == "locked", "lease refuses the intruder")
		local _, value = w.map.get("island:isl-a")
		assert(value.accessCode == "code-a", "intruder never overwrote the routing entry")
	end,

	["heartbeat after lease loss withdraws the island from routing"] = function()
		local w = world()
		local a = w.router("srv-a")
		local b = w.router("srv-b")
		local handle = assert(a:host("isl-a", "code-a", 0))
		w.advance(31)
		assert(b:host("isl-a", "code-b", 0), "takeover after expiry")
		local renewed, err = a:heartbeat(handle, "code-a", 0)
		assert(renewed == nil and err == "lease lost", "stale owner detects loss")
		local _, value = w.map.get("island:isl-a")
		assert(value == nil, "stale owner removed the advertisement")
	end,

	["teleport failure falls back to origin"] = function()
		local w = world()
		local origin, codes = w.router("origin", false)
		local result = origin:route(1)
		assert(result.status == "fallback" and result.attempts == 3, "falls back after retries")
		assert(#codes == 3, "three attempts made")
	end,
}
