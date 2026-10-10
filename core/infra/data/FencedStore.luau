--!strict
-- Opt-in aggregate storage. Use a separate key namespace from ProfileStore.
-- Backend.update must atomically replay transforms and return the committed value.
-- A failed/ambiguous ACK is never retried here: callers replay a durable receipt
-- in the same pure transform as their mutation, rather than repeat a blind debit.
local MemoryBackend = require("./MemoryBackend")
local EnvelopeBudget = require("./EnvelopeBudget")

export type Data = { [string]: any }
export type Transform = (Data) -> Data
export type Budget = { encode: (any) -> string, maxBytes: number? }
export type Options = {
	sessionId: string,
	leaseSeconds: number,
	now: () -> number,
	budget: Budget?,
	-- Runtime stores opt in: an update whose transform returns data identical
	-- to the persisted aggregate publishes nothing, so the write round-trip is
	-- skipped. The confirmation contract (revision must advance on a real
	-- candidate) stays intact because no candidate is built at all.
	suppressIdentityUpdates: boolean?,
}
export type Profile = {
	key: string,
	sessionId: string,
	generation: number,
	data: Data,
	leaseExpiresAt: number?,
	-- Set once a dedicated renew has committed: the first renew after any
	-- acquisition still performs a real fencing round-trip; only later
	-- refreshes of an already-healthy lease may be skipped locally.
	leaseRenewed: boolean?,
}

local MAX = 9007199254740991
local function integer(value: any, minimum: number): boolean
	return type(value) == "number" and value >= minimum and value <= MAX and value % 1 == 0
end
local function identity(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum and not string.find(value, "%c")
end
local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = clone(item)
	end
	return copy
end
local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, item in a do
		if not deepEqual(item, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end
local function validate(record: any): string?
	if type(record) ~= "table" or record.version ~= 1 then
		return "unsupported record version"
	end
	if not integer(record.generation, 1) or not integer(record.revision, 0) or type(record.data) ~= "table" then
		return "invalid record"
	end
	local lease = record.lease
	if
		lease ~= nil
		and (type(lease) ~= "table" or not identity(lease.sessionId, 128) or not integer(lease.expiresAt, 0))
	then
		return "invalid lease"
	end
	return nil
end

local FencedStore = {}
FencedStore.__index = FencedStore
export type Store = typeof(setmetatable(
	{} :: {
		_backend: MemoryBackend.Backend,
		_opts: Options,
	},
	FencedStore
))

-- now is an authoritative server clock in integer seconds, never client input.
function FencedStore.new(backend: MemoryBackend.Backend, opts: Options): Store
	assert(identity(opts.sessionId, 128), "invalid session identity")
	assert(integer(opts.leaseSeconds, 1) and opts.leaseSeconds <= 86400, "invalid lease duration")
	local options = table.clone(opts)
	if opts.budget then
		assert(type(opts.budget.encode) == "function", "INVALID_BUDGET_ENCODER")
		local maximum = opts.budget.maxBytes
		assert(maximum == nil or (integer(maximum, 1) and maximum <= EnvelopeBudget.MAX_BYTES), "INVALID_BYTE_BUDGET")
		options.budget = table.clone(opts.budget)
	end
	return setmetatable({ _backend = backend, _opts = options }, FencedStore)
end

function FencedStore._commit(
	self: Store,
	key: string,
	profile: Profile?,
	transform: Transform,
	mode: string
): (Profile?, string?)
	if not identity(key, 50) then
		return nil, "invalid key"
	end
	if profile and (profile.sessionId ~= self._opts.sessionId or not integer(profile.generation, 1)) then
		return nil, "invalid token"
	end
	local reason: string? = nil
	local generation: number? = nil
	local revision: number? = nil
	local ok, persisted = self._backend.update(key, function(old: any): any
		-- These are invocation-local outcome bookkeeping, not published state.
		reason, generation, revision = nil, nil, nil
		local now = self._opts.now()
		if not integer(now, 0) or now > MAX - self._opts.leaseSeconds then
			reason = "invalid clock"
			return old
		end
		if old ~= nil then
			reason = validate(old)
			if reason then
				return old
			end
		end
		if profile then
			if
				old == nil
				or old.generation ~= profile.generation
				or old.lease == nil
				or old.lease.sessionId ~= profile.sessionId
				or now >= old.lease.expiresAt
			then
				reason = "lease lost"
				return old
			end
		elseif old and old.lease and old.lease.sessionId ~= self._opts.sessionId and now < old.lease.expiresAt then
			reason = "locked"
			return old
		end
		if old and (old.revision == MAX or (not profile and old.generation == MAX)) then
			reason = "counter exhausted"
			return old
		end
		local nextGeneration = if profile then profile.generation else (if old then old.generation + 1 else 1)
		local nextRevision = if old then old.revision + 1 else 1
		local data = transform(clone(if old then old.data else {}))
		assert(type(data) == "table", "transform must return aggregate data")
		if mode == "update" and old ~= nil and self._opts.suppressIdentityUpdates and deepEqual(data, old.data) then
			-- Identity transform: nothing changed, so there is nothing to publish.
			-- Acknowledge without a CAS candidate (the backend still performed its
			-- read; skipping the write keeps studio-local loopback under the
			-- HttpService request quota that periodic recovery sweeps otherwise burn).
			generation, revision = old.generation, old.revision
			return old
		end

		-- Read-through refresh: the backend read already happened, so the caller observes
		-- externally committed data. Publish a renew only when the lease is no longer
		-- healthy; identity content on a live lease must never become a durable write,
		-- because a per-frame caller would otherwise turn every read into a CAS storm.
		if mode == "refresh" and old ~= nil and deepEqual(data, old.data) then
			local lease = old.lease
			if
				lease ~= nil
				and lease.sessionId == self._opts.sessionId
				and now + self._opts.leaseSeconds / 2 <= lease.expiresAt
			then
				generation, revision = old.generation, old.revision
				return old
			end
		end
		local candidate = {
			version = 1,
			generation = nextGeneration,
			revision = nextRevision,
			data = clone(data),
			lease = if mode == "release"
				then nil
				else {
					sessionId = self._opts.sessionId,
					expiresAt = now + self._opts.leaseSeconds,
				},
		}
		local budget = self._opts.budget
		if budget then
			local measured = EnvelopeBudget.check(candidate, budget.encode, budget.maxBytes)
			if not measured.accepted then
				reason = measured.errorCode
				return old
			end
		end
		generation, revision = nextGeneration, nextRevision
		return candidate
	end)
	if not ok then
		return nil, if type(persisted) == "string" then persisted else "backend error"
	end
	if reason then
		return nil, reason
	end
	if
		generation == nil
		or revision == nil
		or validate(persisted) ~= nil
		or persisted.generation ~= generation
		or persisted.revision ~= revision
	then
		return nil, "unconfirmed commit"
	end
	return {
		key = key,
		sessionId = self._opts.sessionId,
		generation = generation,
		data = clone(persisted.data),
		leaseExpiresAt = if persisted.lease then persisted.lease.expiresAt else nil,
		-- Carry the renewal marker forward: an update (including an acknowledged
		-- identity suppression) must not reset its caller back into a state where
		-- the next snapshot performs a real renew write again.
		leaseRenewed = if profile then profile.leaseRenewed else nil,
	},
		nil
end

-- Each successful acquisition increments generation, including same-session reacquisition.
-- Both acquire and update callbacks must be pure, non-yielding, and replay-safe.
function FencedStore.acquire(self: Store, key: string, migrate: Transform): (Profile?, string?)
	return self:_commit(key, nil, migrate, "acquire")
end
function FencedStore.load(self: Store, key: string, migrate: Transform): (Profile?, string?)
	return self:acquire(key, migrate)
end
-- Mutation AND its durable receipt belong in the returned aggregate. Uses current
-- persisted data, never profile.data. Returned data is detached from persistence.
function FencedStore.update(self: Store, profile: Profile, transform: Transform): (Profile?, string?)
	return self:_commit(profile.key, profile, transform, "update")
end
function FencedStore.save(self: Store, profile: Profile, transform: Transform): (Profile?, string?)
	return self:update(profile, transform)
end
-- Renewals ride along on snapshot reads. A lease with more than half of its
-- duration left is already healthy: committing the refresh anyway would turn
-- every state push into a durable write (thousands of requests per minute on
-- studio-local loopback, which starves the transport for every other caller).
function FencedStore.renew(self: Store, profile: Profile): (Profile?, string?)
	if
		profile.leaseExpiresAt ~= nil
		and profile.leaseRenewed == true
		and profile.leaseExpiresAt - self._opts.now() > self._opts.leaseSeconds / 2
	then
		return profile
	end
	local refreshed, err = self:_commit(profile.key, profile, function(data: Data): Data
		return data
	end, "renew")
	if refreshed then
		refreshed.leaseRenewed = true
	end
	return refreshed, err
end
-- Read-through refresh for callers that need the current committed aggregate. The
-- backend read always happens, so an external commit is observed by the next call;
-- only the publish is skipped, and only while the lease is healthy. verify may
-- inspect the freshly read record but must not mutate it: a mutation would make the
-- content differ from the persisted record and force the identity write this path
-- exists to avoid.
function FencedStore.refresh(self: Store, profile: Profile, verify: Transform?): (Profile?, string?)
	return self:_commit(profile.key, profile, function(data: Data): Data
		if verify then
			verify(data)
		end
		return data
	end, "refresh")
end
function FencedStore.release(self: Store, profile: Profile): (Profile?, string?)
	return self:_commit(profile.key, profile, function(data)
		return data
	end, "release")
end
return FencedStore
