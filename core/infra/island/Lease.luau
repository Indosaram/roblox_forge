--!strict
-- Lease: single write owner per island (plan D-6, §11.2).
--
-- Authority is the FencedStore lease on the island's DataStore key: every write
-- carries the generation token and is rejected once another server has
-- acquired (or the lease expired). The MemoryStore entry published here is a
-- display/routing hint only; its expiry or eviction never grants or revokes
-- ownership. Engine services are injected (FencedStore backend + display map).

local FencedStore = require("../data/FencedStore")

export type DisplayMap = {
	set: (key: string, value: any, ttlSeconds: number) -> (boolean, string?),
	get: (key: string) -> (boolean, any),
	remove: (key: string) -> (boolean, string?),
}

export type Delta = {
	-- Durable receipt id: replaying the same id is a no-op (idempotent).
	id: string,
	op: string,
	payload: { [string]: any }?,
}

export type Options = {
	store: FencedStore.Store,
	serverId: string,
	display: DisplayMap?,
	displayTtlSeconds: number?,
}

export type Handle = {
	islandId: string,
	profile: FencedStore.Profile,
}

local PREFIX = "island:"

local function validId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value + #PREFIX <= 50 and string.find(value, "^[%w_%-]+$") ~= nil
end

local function initial(data: FencedStore.Data): FencedStore.Data
	if data.deltas == nil then
		data.deltas = {}
		data.receipts = {}
	end
	return data
end

local Lease = {}
Lease.__index = Lease

export type Lease = typeof(setmetatable(
	{} :: {
		_opts: Options,
	},
	Lease
))

function Lease.new(opts: Options): Lease
	assert(type(opts.serverId) == "string" and #opts.serverId > 0, "invalid server id")
	local store: FencedStore.Store? = opts.store
	assert(store ~= nil, "store required")
	return setmetatable({ _opts = table.clone(opts) }, Lease)
end

function Lease.key(islandId: string): string
	return PREFIX .. islandId
end

function Lease._display(self: Lease, islandId: string, handle: Handle?)
	local display = self._opts.display
	if not display then
		return
	end
	-- Best effort: display failures never affect ownership.
	if handle then
		display.set(
			"lease:" .. islandId,
			{ serverId = self._opts.serverId, generation = handle.profile.generation },
			self._opts.displayTtlSeconds or 30
		)
	else
		display.remove("lease:" .. islandId)
	end
end

-- Acquire write ownership. Returns "locked" while another server's FencedStore
-- lease is live, regardless of what the display entry says.
function Lease.acquire(self: Lease, islandId: string): (Handle?, string?)
	if not validId(islandId) then
		return nil, "invalid island id"
	end
	local profile, err = self._opts.store:acquire(Lease.key(islandId), initial)
	if not profile then
		return nil, err
	end
	local handle = { islandId = islandId, profile = profile }
	self:_display(islandId, handle)
	return handle, nil
end

-- Append a delta under the fencing token. A stale owner gets "lease lost" and
-- nothing is written; the caller must re-route the delta to the current owner.
function Lease.write(self: Lease, handle: Handle, delta: Delta): (Handle?, string?)
	if type(delta.id) ~= "string" or #delta.id == 0 or type(delta.op) ~= "string" then
		return nil, "invalid delta"
	end
	local profile, err = self._opts.store:update(handle.profile, function(data: FencedStore.Data): FencedStore.Data
		data = initial(data)
		if not data.receipts[delta.id] then
			table.insert(data.deltas, { id = delta.id, op = delta.op, payload = delta.payload })
			data.receipts[delta.id] = #data.deltas
		end
		return data
	end)
	if not profile then
		return nil, err
	end
	return { islandId = handle.islandId, profile = profile }, nil
end

function Lease.renew(self: Lease, handle: Handle): (Handle?, string?)
	local profile, err = self._opts.store:renew(handle.profile)
	if not profile then
		return nil, err
	end
	local renewed = { islandId = handle.islandId, profile = profile }
	self:_display(handle.islandId, renewed)
	return renewed, nil
end

function Lease.release(self: Lease, handle: Handle): (boolean, string?)
	local profile, err = self._opts.store:release(handle.profile)
	if not profile then
		return false, err
	end
	self:_display(handle.islandId, nil)
	return true, nil
end

-- Display-only owner hint (non-authoritative; may be stale, expired or evicted).
function Lease.displayedOwner(self: Lease, islandId: string): string?
	local display = self._opts.display
	if not display then
		return nil
	end
	local ok, value = display.get("lease:" .. islandId)
	if ok and type(value) == "table" and type(value.serverId) == "string" then
		return value.serverId
	end
	return nil
end

return Lease
