--!strict
-- IslandRouter: composes Allocation + IslandDirectory + Lease + Teleport.
--
-- Origin side: route(playerId) asks the allocator for an island from the live
-- directory snapshot, reserves a new server when the allocator says so, and
-- teleports with commit-before-teleport + retry + origin fallback.
-- Island side: host(islandId, accessCode) takes write ownership through the
-- FencedStore lease (authoritative) and publishes the routing entry
-- (display-only). Only the lease owner advertises the island.
--
-- core/domain/island/Allocation is owned by another lane; until it lands the
-- router codes against the minimal Allocator type below, injected by callers.

local IslandDirectory = require("./IslandDirectory")
local Lease = require("./Lease")
local Teleport = require("./Teleport")

export type IslandView = {
	islandId: string,
	population: number,
}

export type Choice = { kind: "existing", islandId: string } | { kind: "new" }

export type Allocator = {
	choose: (islands: { IslandView }, partySize: number, capacity: number) -> Choice,
}

export type Reservation = { islandId: string, accessCode: string }

export type Options = {
	allocator: Allocator,
	directory: IslandDirectory.Directory,
	lease: Lease.Lease,
	teleport: Teleport.Teleport,
	-- TeleportService:ReserveServerAsync adapter; returns a fresh island id + access code.
	reserve: (placeId: number) -> (Reservation?, string?),
	placeId: number,
	capacity: number,
	listLimit: number?,
}

export type RouteResult = {
	playerId: number,
	status: "arrived" | "fallback",
	islandId: string?,
	reason: string?,
	attempts: number,
}

local IslandRouter = {}
IslandRouter.__index = IslandRouter

export type Router = typeof(setmetatable(
	{} :: {
		_opts: Options,
	},
	IslandRouter
))

function IslandRouter.new(opts: Options): Router
	assert(type(opts.capacity) == "number" and opts.capacity >= 1, "invalid capacity")
	assert(type(opts.reserve) == "function", "reserve required")
	return setmetatable({ _opts = opts }, IslandRouter)
end

local function fallback(playerId: number, reason: string, islandId: string?): RouteResult
	return { playerId = playerId, status = "fallback", islandId = islandId, reason = reason, attempts = 0 }
end

function IslandRouter.route(self: Router, playerId: number): RouteResult
	local opts = self._opts
	local rows, listErr = opts.directory:list(opts.listLimit or 200)
	if not rows then
		return fallback(playerId, "directory unavailable: " .. tostring(listErr))
	end
	local views: { IslandView } = {}
	for _, row in rows do
		table.insert(views, { islandId = row.islandId, population = row.population })
	end
	local choice = opts.allocator.choose(views, 1, opts.capacity)
	local islandId: string
	local accessCode: string
	if choice.kind == "existing" then
		local record, err = opts.directory:lookup(choice.islandId)
		if not record then
			return fallback(playerId, "island not routable: " .. tostring(err), choice.islandId)
		end
		islandId, accessCode = record.islandId, record.accessCode
	else
		local reservation, err = opts.reserve(opts.placeId)
		if not reservation then
			return fallback(playerId, "reserve failed: " .. tostring(err))
		end
		islandId, accessCode = reservation.islandId, reservation.accessCode
	end
	local result = opts.teleport:send(playerId, opts.placeId, accessCode)
	return {
		playerId = playerId,
		status = result.status,
		islandId = islandId,
		reason = result.reason,
		attempts = result.attempts,
	}
end

-- Island server boot/heartbeat: claim the lease, then advertise. A server that
-- cannot claim the lease never publishes a routing entry.
function IslandRouter.host(
	self: Router,
	islandId: string,
	accessCode: string,
	population: number
): (Lease.Handle?, string?)
	local handle, err = self._opts.lease:acquire(islandId)
	if not handle then
		return nil, err
	end
	local ok, publishErr = self._opts.directory:publish({
		islandId = islandId,
		accessCode = accessCode,
		population = population,
	})
	if not ok then
		-- Directory is best effort; ownership stands regardless.
		return handle, "directory publish failed: " .. tostring(publishErr)
	end
	return handle, nil
end

-- Renew the lease and refresh the directory entry. Losing the lease withdraws
-- the island from routing.
function IslandRouter.heartbeat(
	self: Router,
	handle: Lease.Handle,
	accessCode: string,
	population: number
): (Lease.Handle?, string?)
	local renewed, err = self._opts.lease:renew(handle)
	if not renewed then
		self._opts.directory:remove(handle.islandId)
		return nil, err
	end
	self._opts.directory:publish({ islandId = handle.islandId, accessCode = accessCode, population = population })
	return renewed, nil
end

return IslandRouter
