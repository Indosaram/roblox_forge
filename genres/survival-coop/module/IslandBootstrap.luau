--!strict
-- IslandBootstrap: composes Allocation + IslandDirectory + Lease + Teleport + IslandRouter
-- for a server boot. Every engine service is injected through env so the module never
-- reads a global at require time and specs run on fakes.
--
-- Roles (decided by env.privateServerId):
--   reserved island server ("" ~= privateServerId): host(privateServerId) takes the
--     FencedStore lease, publishes the routing entry and heartbeats every 15s.
--   public entry server: route(userId) on every PlayerAdded.
-- Studio, placeId 0 or any missing service -> { mode = "single" }: nothing is composed
-- and players simply play on this server.
--
-- Players only ever see localization keys (KEY_FAILED / KEY_RETRY) through env.notify;
-- the router's internal reason strings go to env.log and never to the player.

local Allocation = require("../../../core/domain/island/Allocation")
local Topology = require("../../../core/domain/island/Topology")
local FencedStore = require("../../../core/infra/data/FencedStore")
local IslandDirectory = require("../../../core/infra/island/IslandDirectory")
local IslandRouter = require("../../../core/infra/island/IslandRouter")
local Lease = require("../../../core/infra/island/Lease")
local Teleport = require("../../../core/infra/island/Teleport")

local M = {}

M.KEY_FAILED = "island_route_failed"
M.KEY_RETRY = "island_route_retry"
M.HEARTBEAT_SECONDS = 15
M.LEASE_SECONDS = 60
M.RETRY_DELAY_SECONDS = 15
M.CAPACITY = Topology.POLICY_CAPACITY

export type Env = {
	players: any,
	teleportService: any,
	memoryStoreService: any,
	-- MemoryBackend-compatible backend backing the FencedStore lease (DataStore in production).
	backend: any,
	placeId: number,
	jobId: string,
	privateServerId: string?,
	-- Reserved-server access code when the host knows it; without it the island holds the
	-- lease but is not advertised in the directory.
	accessCode: string?,
	isStudio: boolean,
	-- Wall clock in seconds.
	now: () -> number,
	log: ((message: string) -> ())?,
	-- Engine glue (the pack server passes task-library wrappers; specs pass fakes).
	enum: any,
	encode: (any) -> string,
	newTeleportOptions: () -> any,
	notify: ((player: any, key: string) -> ())?,
	commit: ((playerId: number) -> (boolean, string?))?,
	sleep: (seconds: number) -> (),
	spawn: (fn: () -> ()) -> (),
	delay: (seconds: number, fn: () -> ()) -> (),
	-- Repeating timer; returns a cancel function.
	every: (seconds: number, fn: () -> ()) -> () -> (),
}

export type Result = {
	mode: "single" | "routed",
	stop: (() -> ())?,
}

-- Allocator adapter over core/domain/island/Allocation: the directory snapshot becomes
-- anonymous occupancy, one arrival is placed, and "new:" instances mean "reserve".
local function allocator(): IslandRouter.Allocator
	return {
		choose = function(islands, partySize, capacity): IslandRouter.Choice
			local cap = math.clamp(capacity, 1, Topology.POLICY_CAPACITY)
			local snapshot: { Allocation.Island } = {}
			for _, island in islands do
				local players: { string } = {}
				for index = 1, math.min(island.population, cap) do
					table.insert(players, island.islandId .. "#" .. index)
				end
				table.insert(snapshot, { id = island.islandId, kind = "landing", players = players })
			end
			local arrivals: { Allocation.Arrival } = {}
			for index = 1, partySize do
				table.insert(arrivals, { player = "arrival#" .. index, kind = "landing" })
			end
			local plan = Allocation.allocate(snapshot, arrivals, 1, { topology = Topology.new({ landing = cap }) })
			local target = plan.assignments[1]
			if target == nil or string.sub(target.island, 1, 4) == "new:" then
				return { kind = "new" }
			end
			return { kind = "existing", islandId = target.island }
		end,
	}
end

local function present(env: any): boolean
	return type(env) == "table"
		and not env.isStudio
		and type(env.placeId) == "number"
		and env.placeId ~= 0
		and env.players ~= nil
		and env.teleportService ~= nil
		and env.memoryStoreService ~= nil
		and env.backend ~= nil
		and env.enum ~= nil
		and type(env.encode) == "function"
		and type(env.newTeleportOptions) == "function"
		and type(env.now) == "function"
		and type(env.jobId) == "string"
		and env.jobId ~= ""
end

local function compose(env: Env): IslandRouter.Router
	local reserved = function(placeId: number): (IslandRouter.Reservation?, string?)
		local ok, code, serverId = pcall(function()
			return env.teleportService:ReserveServerAsync(placeId)
		end)
		if not ok or type(code) ~= "string" or type(serverId) ~= "string" then
			return nil, tostring(code)
		end
		return { islandId = serverId, accessCode = code }, nil
	end
	local sleep = env.sleep
	local map = IslandDirectory.sortedMap(env.memoryStoreService:GetSortedMap("RobangoIslandDirectory"), env.enum)
	return IslandRouter.new({
		allocator = allocator(),
		directory = IslandDirectory.new(map, { ttlSeconds = M.LEASE_SECONDS, encode = env.encode }),
		lease = Lease.new({
			store = FencedStore.new(
				env.backend,
				{ sessionId = env.jobId, leaseSeconds = M.LEASE_SECONDS, now = env.now }
			),
			serverId = env.jobId,
			display = map,
		}),
		teleport = Teleport.new({
			port = Teleport.teleportService(env.teleportService, env.players, env.newTeleportOptions),
			commit = env.commit or function(): (boolean, string?)
				return true, nil
			end,
			sleep = sleep,
		}),
		reserve = reserved,
		placeId = env.placeId,
		capacity = M.CAPACITY,
	})
end

function M.start(env: Env): Result
	if not present(env) then
		return { mode = "single" }
	end
	local log: (string) -> () = env.log or function(_: string) end
	local spawn: (() -> ()) -> () = env.spawn
	local delay: (number, () -> ()) -> () = env.delay
	local every: (number, () -> ()) -> () -> () = env.every
	local notify: (any, string) -> () = env.notify or function(_: any, _: string) end
	local router = compose(env)
	local cleanup: { () -> () } = {}
	local privateServerId = env.privateServerId or ""

	if privateServerId ~= "" then
		local function population(): number
			return #env.players:GetPlayers()
		end
		local code = env.accessCode or ""
		local handle, hostErr = router:host(privateServerId, code, population())
		if hostErr ~= nil then
			log("island host: " .. hostErr)
		end
		local current = handle
		if current ~= nil then
			table.insert(
				cleanup,
				every(M.HEARTBEAT_SECONDS, function()
					if current == nil then
						return
					end
					local renewed, err = router:heartbeat(current, code, population())
					if err ~= nil then
						log("island heartbeat: " .. err)
					end
					current = renewed
				end)
			)
		end
	else
		local function attempt(player: any, retried: boolean)
			local ok, result = pcall(function()
				return router:route(player.UserId)
			end)
			if not ok then
				log("island route error: " .. tostring(result))
				notify(player, M.KEY_FAILED)
				return
			end
			if result.status == "arrived" then
				return
			end
			log("island route fallback: " .. tostring(result.reason))
			if result.attempts > 0 and not retried then
				notify(player, M.KEY_RETRY)
				delay(M.RETRY_DELAY_SECONDS, function()
					if env.players:GetPlayerByUserId(player.UserId) ~= nil then
						attempt(player, true)
					end
				end)
			else
				notify(player, M.KEY_FAILED)
			end
		end
		local function onPlayer(player: any)
			spawn(function()
				attempt(player, false)
			end)
		end
		local connection = env.players.PlayerAdded:Connect(onPlayer)
		table.insert(cleanup, function()
			connection:Disconnect()
		end)
		for _, player in env.players:GetPlayers() do
			onPlayer(player)
		end
	end

	return {
		mode = "routed",
		stop = function()
			for _, fn in cleanup do
				fn()
			end
			table.clear(cleanup)
		end,
	}
end

return M
