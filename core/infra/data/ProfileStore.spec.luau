--!strict
-- Specs for ProfileStore: session locking, stale takeover, retries, and persistence.

local ProfileSchema = require("../../domain/state/ProfileSchema")
local MemoryBackend = require("./MemoryBackend")
local ProfileStore = require("./ProfileStore")

local function defaults(): { [string]: any }
	return { coins = 0 }
end

local function migrate(raw: any): { [string]: any }
	return ProfileSchema.migrate(raw, 1, defaults, {})
end

local function opts(sessionId: string, now: () -> number)
	return { sessionId = sessionId, lockTimeout = 30, retries = 3, now = now, wait = function() end }
end

-- UpdateAsync can discard an earlier transform result and commit only the last.
-- The backend deliberately preserves that contract, including the final record.
local function replaySpec(): ()
	for _, operation in { "load", "save", "release", "releaseLock" } do
		for _, finalConflict in { false, true } do
			local mine = { data = { coins = 7 }, lock = { session = "mine", at = 0 } }
			local other = { data = { coins = 9 }, lock = { session = "other", at = 0 } }
			local persisted: any = nil
			local calls = 0
			local backend = {
				update = function(_key: string, transform: (any) -> any): (boolean, any)
					calls += 1
					transform(if finalConflict then mine else other)
					persisted = transform(if finalConflict then other else mine)
					return true, persisted
				end,
			}
			local store = ProfileStore.new(backend, {
				sessionId = "mine",
				lockTimeout = 30,
				retries = 0,
				now = function()
					return 0
				end,
			})
			local result: any, err: string?
			if operation == "load" then
				result, err = store:load("k", migrate)
			else
				result, err = store[operation](store, { key = "k", data = { coins = 42 } })
			end
			assert(calls == 1, "replay is within one update, not a retry")
			if finalConflict then
				assert(
					(operation == "load" and result == nil) or result == false,
					"never report an uncommitted success"
				)
				assert(err == "locked" and persisted == other, "final conflicting record stays unchanged")
			else
				assert(
					result ~= nil and result ~= false and err == nil,
					"final committed callback succeeds after conflict"
				)
				assert(
					persisted.data.coins == (if operation == "load" or operation == "releaseLock" then 7 else 42),
					"committed data"
				)
				if operation == "release" or operation == "releaseLock" then
					assert(persisted.lock == nil, "release commits lock removal")
				else
					assert(persisted.lock.session == "mine", "load/save commits owned lock")
				end
				if operation == "load" then
					assert(result.data.coins == persisted.data.coins, "returned profile is the committed data")
				end
			end
		end
	end
end

local function failedCommitSpec(): ()
	for _, operation in { "load", "save", "release", "releaseLock" } do
		for _, recover in { false, true } do
			local persisted: any = { data = { coins = 7 }, lock = { session = "mine", at = 0 } }
			local calls, waits = 0, 0
			local backend = {
				update = function(_key: string, transform: (any) -> any): (boolean, any)
					calls += 1
					local candidate = transform(persisted)
					if calls == 1 or not recover then
						return false, "commit failed"
					end
					persisted = candidate
					return true, persisted
				end,
			}
			local store = ProfileStore.new(backend, {
				sessionId = "mine",
				lockTimeout = 30,
				retries = 1,
				now = function()
					return 0
				end,
				wait = function(attempt: number)
					assert(attempt == 1, "retry backoff contract")
					waits += 1
				end,
			})
			local result: any, err: string?
			if operation == "load" then
				result, err = store:load("k", migrate)
			else
				result, err = store[operation](store, { key = "k", data = { coins = 42 } })
			end
			assert(calls == 2 and waits == 1, "failed commits still retry and back off")
			if recover then
				assert(result ~= nil and result ~= false and err == nil, "only a committed retry reports success")
			else
				assert(
					(operation == "load" and result == nil) or result == false,
					"callback alone cannot report success"
				)
				assert(err == "commit failed", "backend error retained after exhausted retries")
				assert(
					persisted.data.coins == 7 and persisted.lock.session == "mine",
					"failed write/release is uncommitted"
				)
			end
		end
	end
end

return {
	["old writer cannot downgrade newer payload under the same lock"] = function()
		for _, operation in { "save", "release", "releaseLock" } do
			local record = { version = 1, data = { version = 2, coins = 91 }, lock = { session = "mine", at = 0 } }
			local store = ProfileStore.new(
				{
					update = function(_key, transform)
						assert(transform(record) == record, "newer payload and lease must remain untouched")
						return true, record
					end,
				},
				opts("mine", function()
					return 0
				end)
			)
			local ok, err = (store :: any)[operation](store, { key = "k", data = { version = 1, coins = 7 } })
			assert(not ok and err == "unsupported record version", "old writer fails closed")
		end
	end,
	["unsupported wrappers cannot load save release or reset on callback replay"] = function()
		for _, operation in { "load", "save", "release", "releaseLock" } do
			for _, finalUnsupported in { false, true } do
				local mine = { data = { version = 1, coins = 7 }, lock = { session = "mine", at = 0 } }
				local future = { version = 2, data = { version = 1, coins = 91 }, lock = mine.lock }
				local persisted: any = nil
				local calls = 0
				local store = ProfileStore.new(
					{
						update = function(_key, transform)
							calls += 1
							transform(if finalUnsupported then mine else future)
							persisted = transform(if finalUnsupported then future else mine)
							return true, persisted
						end,
					},
					opts("mine", function()
						return 0
					end)
				)
				local result: any, err: string?
				if operation == "load" then
					result, err = store:load("k", function(raw)
						assert(raw.coins == 7, "newer wrapper must never invoke migration")
						return migrate(raw)
					end)
				else
					result, err = (store :: any)[operation](store, { key = "k", data = { version = 1, coins = 42 } })
				end
				assert(calls == 1, "unsupported schema is not transient")
				if finalUnsupported then
					assert(not result and err == "unsupported record version" and persisted == future, "fail closed")
				else
					assert(result and not err and persisted.version == 1, "last callback upgrades legacy wrapper")
				end
			end
		end
	end,
	["backend failure after callback never reports success and preserves retries"] = failedCommitSpec,
	["callback replay uses only the final invocation for load save and release"] = replaySpec,
	["load of a new key returns defaults"] = function()
		local backend = MemoryBackend.new()
		local store = ProfileStore.new(
			backend,
			opts("s1", function()
				return 0
			end)
		)
		local profile, err = store:load("player-1", migrate)
		assert(err == nil, "no error: " .. tostring(err))
		assert(profile ~= nil, "profile returned")
		if profile == nil then
			return
		end
		assert(profile.data.coins == 0, "default coins")
		assert(profile.data.version == 1, "default version")
	end,

	["save then release then load returns the saved data"] = function()
		local backend = MemoryBackend.new()
		local store = ProfileStore.new(
			backend,
			opts("s1", function()
				return 0
			end)
		)
		local profile = store:load("k", migrate)
		assert(profile ~= nil, "loaded")
		if profile == nil then
			return
		end
		profile.data.coins = 42
		assert(store:save(profile) == true, "save succeeded")
		assert(store:release(profile) == true, "release succeeded")

		local reloaded, err = store:load("k", migrate)
		assert(err == nil, "reload has no error")
		assert(reloaded ~= nil, "reloaded")
		if reloaded == nil then
			return
		end
		assert(reloaded.data.coins == 42, "saved data persisted")
	end,

	["mutating the data returned by load does not silently persist without a write"] = function()
		local backend = MemoryBackend.new()
		local store = ProfileStore.new(
			backend,
			opts("s1", function()
				return 0
			end)
		)
		local profile = store:load("k", migrate)
		assert(profile ~= nil, "loaded")
		if profile == nil then
			return
		end
		profile.data.coins = 99

		-- Load again through a second session sharing the same backend storage.
		-- Under a real DataStore, another read never observes a mutation the
		-- first session made to its own local copy before that copy is written
		-- back. MemoryBackend must clone on store so it matches that semantic.
		local storeB = ProfileStore.new(backend, {
			sessionId = "s2",
			lockTimeout = 0,
			retries = 3,
			now = function()
				return 1000
			end,
			wait = function() end,
		})
		local viaB = storeB:load("k", migrate)
		assert(viaB ~= nil, "second session takes over the stale lock and loads")
		if viaB == nil then
			return
		end
		assert(
			viaB.data.coins == 0,
			"an unwritten mutation on session A's copy must not be visible via the backend, got "
				.. tostring(viaB.data.coins)
		)
	end,

	["a second session is refused while locked"] = function()
		local backend = MemoryBackend.new()
		local clock = function()
			return 0
		end
		local storeA = ProfileStore.new(backend, opts("s1", clock))
		local storeB = ProfileStore.new(backend, opts("s2", clock))

		assert(storeA:load("k", migrate) ~= nil, "first session locks")
		local profile, err = storeB:load("k", migrate)
		assert(profile == nil, "second session refused")
		assert(err == "locked", "locked error")
	end,

	["an active session that keeps saving renews its lock and resists takeover"] = function()
		local backend = MemoryBackend.new()
		local now = 0
		local clock = function()
			return now
		end
		local storeA = ProfileStore.new(backend, opts("s1", clock))
		local storeB = ProfileStore.new(backend, opts("s2", clock))

		local profile = storeA:load("k", migrate)
		assert(profile ~= nil, "first session locks")
		if profile == nil then
			return
		end

		now = 20
		assert(storeA:save(profile) == true, "save at t=20 renews the lock")
		now = 40
		assert(storeA:save(profile) == true, "save at t=40 renews the lock again")

		now = 45
		local secondProfile, err = storeB:load("k", migrate)
		assert(secondProfile == nil, "a second session must be refused: lock was renewed at t=40")
		assert(err == "locked", "locked error, got " .. tostring(err))
	end,

	["a stale lock older than lockTimeout is taken over"] = function()
		local backend = MemoryBackend.new()
		local now = 0
		local clock = function()
			return now
		end
		local storeA = ProfileStore.new(backend, opts("s1", clock))
		local storeB = ProfileStore.new(backend, opts("s2", clock))

		assert(storeA:load("k", migrate) ~= nil, "first session locks")
		now = 100
		local profile, err = storeB:load("k", migrate)
		assert(err == nil, "stale lock taken over")
		assert(profile ~= nil, "second session loads")
	end,

	["retries succeed after failNext(2) with retries=3"] = function()
		local backend = MemoryBackend.new()
		backend.failNext(2)
		local store = ProfileStore.new(
			backend,
			opts("s1", function()
				return 0
			end)
		)
		local profile, err = store:load("k", migrate)
		assert(err == nil, "no error after retries")
		assert(profile ~= nil, "loaded after retries")
	end,

	["failNext(5) with retries=3 returns an error"] = function()
		local backend = MemoryBackend.new()
		backend.failNext(5)
		local store = ProfileStore.new(
			backend,
			opts("s1", function()
				return 0
			end)
		)
		local profile, err = store:load("k", migrate)
		assert(profile == nil, "no profile returned")
		assert(err ~= nil, "an error is returned")
	end,

	["retry attempts back off with growing delay before each retry"] = function()
		local backend = MemoryBackend.new()
		backend.failNext(3)
		local delays: { number } = {}
		local store = ProfileStore.new(backend, {
			sessionId = "s1",
			lockTimeout = 30,
			retries = 3,
			now = function()
				return 0
			end,
			wait = function(attempt: number)
				table.insert(delays, attempt)
			end,
		})
		local profile, err = store:load("k", migrate)
		assert(err == nil, "no error after retries")
		assert(profile ~= nil, "loaded after retries")
		assert(#delays == 3, "backoff is called once per retry attempt, got " .. tostring(#delays))
		assert(
			delays[1] == 1 and delays[2] == 2 and delays[3] == 3,
			"attempts pass the attempt that just failed, got " .. table.concat(delays, ",")
		)
	end,

	["omitting wait is a no-op default, safe under a backend that keeps failing"] = function()
		local backend = MemoryBackend.new()
		backend.failNext(5)
		local store = ProfileStore.new(backend, {
			sessionId = "s1",
			lockTimeout = 30,
			retries = 3,
			now = function()
				return 0
			end,
			-- wait intentionally omitted: this must not error (there is no `task`
			-- global under Lune) and must not block; it should just retry and
			-- report the backend error once retries are exhausted.
		})
		local profile, err = store:load("k", migrate)
		assert(profile == nil, "no profile after exhausting retries")
		assert(err ~= nil, "an error is returned instead of erroring out")
	end,
}
