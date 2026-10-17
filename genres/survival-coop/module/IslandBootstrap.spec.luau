--!strict
-- Specs for IslandBootstrap on fakes: single-mode guard, host on reserved servers,
-- route on the entry server, and player-visible failures limited to localization keys.

local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local IslandBootstrap = require("./IslandBootstrap")
local serde = require("@lune/serde")

local SECRET = "internal-secret-server-id-7731"

type Fake = {
	env: any,
	notices: { { userId: number, key: string } },
	logs: { string },
	teleports: { { placeId: number, userId: number, code: string } },
	sortedMap: { [string]: any },
	pending: { () -> () },
	join: (userId: number) -> (),
	timers: { () -> () },
}

local function fake(overrides: { [string]: any }?, teleportError: string?): Fake
	local now = 0
	local connected: { (any) -> () } = {}
	local players: { any } = {}
	local sortedMap: { [string]: any } = {}
	local notices: { { userId: number, key: string } } = {}
	local logs: { string } = {}
	local teleports: { { placeId: number, userId: number, code: string } } = {}
	local pending: { () -> () } = {}
	local timers: { () -> () } = {}
	local reserved = 0
	local self: Fake
	local env: any = {
		players = {
			GetPlayers = function(): { any }
				return players
			end,
			GetPlayerByUserId = function(_, userId: number): any
				for _, player in players do
					if player.UserId == userId then
						return player
					end
				end
				return nil
			end,
			PlayerAdded = {
				Connect = function(_, fn: (any) -> ()): any
					table.insert(connected, fn)
					return {
						Disconnect = function() end,
					}
				end,
			},
		},
		teleportService = {
			ReserveServerAsync = function(_, _placeId: number): (string, string)
				reserved += 1
				return "code-" .. reserved, "isl-" .. reserved
			end,
			TeleportAsync = function(_, placeId: number, targets: { any }, options: any)
				if teleportError then
					error(teleportError)
				end
				table.insert(
					teleports,
					{ placeId = placeId, userId = targets[1].UserId, code = options.ReservedServerAccessCode }
				)
			end,
		},
		memoryStoreService = {
			GetSortedMap = function(_, _name: string): any
				return {
					GetAsync = function(_, key: string): any
						return sortedMap[key]
					end,
					SetAsync = function(_, key: string, value: any)
						sortedMap[key] = value
					end,
					RemoveAsync = function(_, key: string)
						sortedMap[key] = nil
					end,
					GetRangeAsync = function(_, _direction: any, _limit: number): any
						local rows = {}
						for key, value in sortedMap do
							table.insert(rows, { key = key, value = value })
						end
						return rows
					end,
				}
			end,
		},
		backend = MemoryBackend.new(),
		placeId = 4242,
		jobId = "job-1",
		privateServerId = "",
		isStudio = false,
		now = function(): number
			return now
		end,
		log = function(message: string)
			table.insert(logs, message)
		end,
		enum = { SortDirection = { Ascending = "asc" } },
		encode = function(value: any): string
			return serde.encode("json", value)
		end,
		newTeleportOptions = function(): any
			return {}
		end,
		notify = function(player: any, key: string)
			table.insert(notices, { userId = player.UserId, key = key })
		end,
		sleep = function() end,
		spawn = function(fn: () -> ())
			fn()
		end,
		delay = function(_seconds: number, fn: () -> ())
			table.insert(pending, fn)
		end,
		every = function(_seconds: number, fn: () -> ()): () -> ()
			table.insert(timers, fn)
			return function() end
		end,
	}
	for key, value in (overrides or {}) :: { [string]: any } do
		env[key] = value
	end
	self = {
		env = env,
		notices = notices,
		logs = logs,
		teleports = teleports,
		sortedMap = sortedMap,
		pending = pending,
		timers = timers,
		join = function(userId: number)
			local player = { UserId = userId }
			table.insert(players, player)
			for _, fn in connected do
				fn(player)
			end
		end,
	}
	return self
end

return {
	["single mode when placeId is 0: nothing is composed"] = function()
		local f = fake({ placeId = 0 })
		local result = IslandBootstrap.start(f.env)
		assert(result.mode == "single" and result.stop == nil, "placeId 0 -> single")
		f.join(1)
		assert(#f.teleports == 0 and #f.notices == 0 and next(f.sortedMap) == nil, "no routing side effects")
	end,

	["single mode in Studio or with a missing service"] = function()
		assert(IslandBootstrap.start(fake({ isStudio = true }).env).mode == "single", "studio")
		local noTeleport = fake()
		noTeleport.env.teleportService = nil
		assert(IslandBootstrap.start(noTeleport.env).mode == "single", "no teleport service")
		local missing = fake()
		missing.env.memoryStoreService = nil
		assert(IslandBootstrap.start(missing.env).mode == "single", "no memory store")
		local nobackend = fake()
		nobackend.env.backend = nil
		assert(IslandBootstrap.start(nobackend.env).mode == "single", "no backend")
	end,

	["reserved server hosts its island and heartbeats"] = function()
		local f = fake({ privateServerId = "isl-a", accessCode = "code-a" })
		local result = IslandBootstrap.start(f.env)
		assert(result.mode == "routed" and result.stop ~= nil, "routed")
		local entry = f.sortedMap["island:isl-a"]
		assert(entry and entry.accessCode == "code-a" and entry.population == 0, "host published routing entry")
		assert(#f.timers == 1, "one heartbeat timer")
		f.env.players:GetPlayers()
		f.timers[1]()
		assert(f.sortedMap["island:isl-a"] ~= nil and #f.logs == 0, "heartbeat keeps the entry, no errors")
		assert(#f.teleports == 0, "island server never routes players away")
	end,

	["entry server routes a joining player and reserves when no island exists"] = function()
		local f = fake()
		local result = IslandBootstrap.start(f.env)
		assert(result.mode == "routed", "routed")
		assert(#f.timers == 0, "entry server runs no heartbeat")
		f.join(77)
		assert(#f.teleports == 1, "player teleported")
		local hop = f.teleports[1]
		assert(hop.userId == 77 and hop.placeId == 4242 and hop.code == "code-1", "reserved server access code used")
		assert(#f.notices == 0, "success shows nothing")
	end,

	["entry server joins an existing hosted island through the directory"] = function()
		local f = fake()
		f.sortedMap["island:isl-live"] = { islandId = "isl-live", accessCode = "code-live", population = 3 }
		IslandBootstrap.start(f.env)
		f.join(5)
		assert(#f.teleports == 1 and f.teleports[1].code == "code-live", "existing island chosen by Allocation")
	end,

	["NEGATIVE: full islands are not chosen; a new one is reserved"] = function()
		local f = fake()
		f.sortedMap["island:isl-full"] = { islandId = "isl-full", accessCode = "code-full", population = 8 }
		IslandBootstrap.start(f.env)
		f.join(5)
		assert(f.teleports[1].code == "code-1", "full island skipped")
	end,

	["route failure shows localization keys only, never internal detail"] = function()
		local f = fake(nil, SECRET)
		IslandBootstrap.start(f.env)
		f.join(9)
		assert(#f.teleports == 0, "no teleport succeeded")
		assert(#f.notices == 1 and f.notices[1].key == IslandBootstrap.KEY_RETRY, "first failure -> retry key")
		assert(#f.pending == 1, "retry scheduled")
		f.pending[1]()
		assert(#f.notices == 2 and f.notices[2].key == IslandBootstrap.KEY_FAILED, "second failure -> failed key")
		for _, notice in f.notices do
			assert(
				notice.key == "island_route_failed" or notice.key == "island_route_retry",
				"only localization keys reach the player"
			)
			assert(string.find(notice.key, SECRET, 1, true) == nil, "no internal id in player message")
			assert(string.find(notice.key, "stack", 1, true) == nil, "no stack in player message")
		end
		local logged = table.concat(f.logs, "\n")
		assert(string.find(logged, SECRET, 1, true) ~= nil, "detail goes to the server log instead")
	end,

	["NEGATIVE: router raising is contained and surfaces the failed key"] = function()
		local f = fake()
		f.env.teleportService.ReserveServerAsync = function()
			error(SECRET)
		end
		IslandBootstrap.start(f.env)
		f.join(3)
		assert(#f.notices == 1 and f.notices[1].key == IslandBootstrap.KEY_FAILED, "reserve failure -> failed key")
		assert(#f.pending == 0, "no retry when nothing was attempted")
		assert(string.find(f.notices[1].key, SECRET, 1, true) == nil, "no internal detail in player message")
	end,

	["stop is idempotent"] = function()
		local f = fake()
		local result = IslandBootstrap.start(f.env)
		local stop = assert(result.stop, "routed mode returns stop")
		stop()
		stop()
	end,
}
