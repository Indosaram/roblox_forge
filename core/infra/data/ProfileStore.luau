--!strict
-- ProfileStore: session-locked, retrying profile persistence over an injectable backend.

local MemoryBackend = require("./MemoryBackend")

export type Backend = MemoryBackend.Backend
export type Migrate = (any) -> { [string]: any }

export type Options = {
	sessionId: string,
	lockTimeout: number,
	retries: number,
	now: () -> number,
	-- Optional backoff sleep called between retry attempts, with the attempt
	-- number (1-indexed) that just failed. Callers that want a real delay
	-- (for example production, via task.wait) must inject it explicitly.
	-- Defaults to no delay when omitted, which is also what keeps this module
	-- safe to run under Lune, where no `task` global exists.
	wait: ((attempt: number) -> ())?,
}

export type Profile = {
	key: string,
	data: { [string]: any },
}

-- Backoff between retries defaults to a no-op: callers that want a real
-- delay (production, via task.wait) inject it through `Options.wait`. This
-- keeps the module safe to run under Lune, where no `task` global exists.
local function backoff(self: Store, attempt: number): ()
	local waitFn = self._opts.wait
	if waitFn ~= nil then
		waitFn(attempt)
	end
end

local ProfileStore = {}
ProfileStore.__index = ProfileStore
ProfileStore.VERSION = 1

-- Missing version is the shipped legacy wrapper, not a different namespace.
-- Payload migration remains with the caller; fenced keys use a separate namespace.
local function supported(record: any): boolean
	return record == nil
		or (type(record) == "table" and (record.version == nil or record.version == ProfileStore.VERSION))
end

export type Store = typeof(setmetatable(
	{} :: {
		_backend: Backend,
		_opts: Options,
	},
	ProfileStore
))

function ProfileStore.new(backend: Backend, opts: Options): Store
	local self = setmetatable({ _backend = backend, _opts = opts }, ProfileStore)
	return self
end

-- Takes (or renews) the session lock on `key` and returns the migrated profile.
function ProfileStore.load(self: Store, key: string, migrate: Migrate): (Profile?, string?)
	local lastErr: string? = nil
	for attempt = 1, self._opts.retries + 1 do
		if attempt > 1 then
			backoff(self, attempt - 1)
		end
		local conflict = false
		local unsupported = false
		local ok, value = self._backend.update(key, function(old: any): any
			conflict = false
			unsupported = not supported(old)
			if unsupported then
				return old
			end
			local record: any = old
			if type(record) ~= "table" then
				record = {}
			end

			local now = self._opts.now()
			local lock = record.lock
			if type(lock) == "table" and lock.session ~= self._opts.sessionId then
				local at = lock.at
				if type(at) == "number" and now - at <= self._opts.lockTimeout then
					conflict = true
					return old
				end
			end

			return {
				version = ProfileStore.VERSION,
				data = migrate(record.data),
				lock = { session = self._opts.sessionId, at = now },
			}
		end)

		if unsupported then
			return nil, "unsupported record version"
		end
		if conflict then
			return nil, "locked"
		end
		if ok then
			return { key = key, data = value.data }, nil
		end
		lastErr = if type(value) == "string" then value else "backend error"
	end

	return nil, lastErr or "backend error"
end

function ProfileStore.save(self: Store, profile: Profile): (boolean, string?)
	return ProfileStore._write(self, profile, false)
end

function ProfileStore.release(self: Store, profile: Profile): (boolean, string?)
	return ProfileStore._write(self, profile, true)
end

-- Release ownership after failed final serialization without overwriting the
-- last durable record with an obsolete in-memory envelope.
function ProfileStore.releaseLock(self: Store, profile: Profile): (boolean, string?)
	return ProfileStore._write(self, profile, true, true)
end

-- Writes data only while the stored lock still belongs to this session.
function ProfileStore._write(
	self: Store,
	profile: Profile,
	clearLock: boolean,
	preserveData: boolean?
): (boolean, string?)
	local lastErr: string? = nil
	for attempt = 1, self._opts.retries + 1 do
		if attempt > 1 then
			backoff(self, attempt - 1)
		end
		local written = false
		local conflict = false
		local unsupported = false
		local ok, value = self._backend.update(profile.key, function(old: any): any
			written = false
			conflict = false
			unsupported = not supported(old)
			if unsupported then
				return old
			end
			local record: any = old
			if type(record) ~= "table" then
				conflict = true
				return old
			end
			-- A live old writer must not overwrite a payload upgraded in place,
			-- even if an operator retained its session lock during the upgrade.
			local storedVersion = if type(record.data) == "table" then record.data.version else nil
			local candidateVersion = profile.data.version
			if
				type(storedVersion) == "number"
				and (type(candidateVersion) ~= "number" or storedVersion > candidateVersion)
			then
				unsupported = true
				return old
			end

			local lock = record.lock
			if type(lock) ~= "table" or lock.session ~= self._opts.sessionId then
				conflict = true
				return old
			end

			written = true
			if clearLock then
				return { version = ProfileStore.VERSION, data = if preserveData then record.data else profile.data }
			end
			return {
				version = ProfileStore.VERSION,
				data = profile.data,
				lock = { session = lock.session, at = self._opts.now() },
			}
		end)

		if unsupported then
			return false, "unsupported record version"
		end
		if conflict then
			return false, "locked"
		end
		if ok and written then
			return true, nil
		end
		lastErr = if type(value) == "string" then value else "backend error"
	end

	return false, lastErr or "backend error"
end

return ProfileStore
