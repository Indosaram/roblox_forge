--!strict
local FencedStore = require("./FencedStore")
local MemoryBackend = require("./MemoryBackend")
local serde = require("@lune/serde")

local function initial(data: FencedStore.Data): FencedStore.Data
	if data.coins == nil then
		data.coins = 10
		data.receipts = {}
	end
	return data
end
local function debit(data: FencedStore.Data): FencedStore.Data
	if not data.receipts.transfer then
		data.coins -= 3
		data.receipts.transfer = { amount = 3, result = "accepted" }
	end
	return data
end
local function store(backend: MemoryBackend.Backend, clock: () -> number, session: string?): FencedStore.Store
	return FencedStore.new(backend, { sessionId = session or "a", leaseSeconds = 30, now = clock })
end

return {
	["full wrapper budget checks acquire update release and callback replay"] = function()
		local memory = MemoryBackend.new()
		local observed: any = nil
		local overflow = false
		local budget = {
			maxBytes = 200,
			encode = function(value: any): string
				observed = value
				assert(
					value.version == 1 and value.generation and value.revision and value.data,
					"whole wrapper measured"
				)
				return if overflow then string.rep("x", 201) else serde.encode("json", value)
			end,
		}
		local opts = {
			sessionId = "a",
			leaseSeconds = 30,
			now = function(): number
				return 0
			end,
			budget = budget,
		}
		local a = FencedStore.new(memory, opts)
		overflow = true
		local missing, reason = a:acquire("k", initial)
		assert(not missing and reason == "PERSISTED_VALUE_TOO_LARGE", "oversized acquire refused")
		local _, absent = memory.update("k", function(old)
			return old
		end)
		assert(absent == nil, "refusal does not create wrapper")
		overflow = false
		local token = assert(a:acquire("k", initial))
		overflow = true
		for _, operation in { "update", "release", "renew" } do
			local result, err = (a :: any)[operation](a, token, debit)
			assert(not result and err == "PERSISTED_VALUE_TOO_LARGE", "each final candidate checked")
		end
		assert(observed.lease ~= nil, "renew wrapper includes lease")
		local _, durable = memory.update("k", function(old)
			return old
		end)
		assert(durable.revision == 1 and durable.data.coins == 10 and durable.lease ~= nil, "no candidate published")
		local replay = FencedStore.new({
			update = function(key, transform)
				overflow = false
				memory.update(key, function(old)
					transform(old)
					return old
				end)
				overflow = true
				return memory.update(key, transform)
			end,
		}, opts)
		local rejected, err = replay:update(token, debit)
		assert(not rejected and err == "PERSISTED_VALUE_TOO_LARGE", "last callback rejection wins")
		overflow = false
		assert(a:release(token), "release fits")
		assert(observed.lease == nil, "release measured actual lease-free wrapper")
	end,
	["actual wrapper overhead and encoder failure cannot publish"] = function()
		local memory = MemoryBackend.new()
		local data = initial({})
		local a = FencedStore.new(memory, {
			sessionId = "a",
			leaseSeconds = 30,
			now = function(): number
				return 0
			end,
			budget = {
				maxBytes = #serde.encode("json", data),
				encode = function(value: any): string
					return serde.encode("json", value)
				end,
			},
		})
		local token, err = a:acquire("k", function()
			return data
		end)
		assert(not token and err == "PERSISTED_VALUE_TOO_LARGE", "data-only budget misses wrapper overhead")
		local broken = FencedStore.new(memory, {
			sessionId = "a",
			leaseSeconds = 30,
			now = function(): number
				return 0
			end,
			budget = {
				encode = function(): string
					error("ENCODER_FAILURE")
				end,
			},
		})
		assert(not pcall(broken.acquire, broken, "k", initial), "encoder errors propagate")
		local _, value = memory.update("k", function(old)
			return old
		end)
		assert(value == nil, "encoder failure did not publish")
	end,
	["same session reacquisition fences old tokens and increments after release"] = function()
		local backend = MemoryBackend.new()
		local a = store(backend, function()
			return 0
		end)
		local first = assert(a:load("k", initial))
		local second = assert(a:acquire("k", initial))
		assert(second.generation == first.generation + 1, "reacquisition increments generation")
		for _, operation in { "update", "save", "renew", "release" } do
			local result, err = (a :: any)[operation](a, first, debit)
			assert(result == nil and err == "lease lost", "stale writer rejected")
		end
		assert(a:release(second))
		assert(assert(a:acquire("k", initial)).generation == second.generation + 1, "release retains generation")
	end,
	["expiry blocks every old write even without a new owner and renew cannot resurrect"] = function()
		local now = 0
		local a = store(MemoryBackend.new(), function()
			return now
		end)
		local token = assert(a:acquire("k", initial))
		now = 20
		assert(a:renew(token))
		now = 50
		for _, operation in { "update", "save", "renew", "release" } do
			local result, err = (a :: any)[operation](a, token, debit)
			assert(result == nil and err == "lease lost", "stale writer rejected")
		end
		assert(assert(a:acquire("k", initial)).generation == 2, "expired acquisition increments generation")
	end,
	["copy on write commits mutation receipt together using current data"] = function()
		local a = store(MemoryBackend.new(), function()
			return 0
		end)
		local token = assert(a:acquire("k", initial))
		token.data.coins = 999
		local result = assert(a:update(token, debit))
		assert(result.data.coins == 7 and result.data.receipts.transfer.amount == 3, "receipt and debit committed")
		result.data.receipts.transfer.amount = 99
		local replay = assert(a:save(token, debit))
		assert(replay.data.coins == 7 and replay.data.receipts.transfer.amount == 3, "replay cannot double debit")
		assert(a:release(token))
		assert(a:renew(token) == nil, "released lease cannot renew")
	end,
	["commit barrier replays expired old writer against new owner"] = function()
		local memory = MemoryBackend.new()
		local now = 0
		local clock = function()
			return now
		end
		local b = store(memory, clock, "b")
		local barrier: (() -> ())? = nil
		local backend = {
			update = function(key: string, transform: MemoryBackend.Transform): (boolean, any)
				if barrier then
					local event = barrier
					barrier = nil
					-- First candidate is discarded, exactly as UpdateAsync on conflict.
					memory.update(key, function(old)
						transform(old)
						return old
					end)
					event()
				end
				return memory.update(key, transform)
			end,
		}
		local a = store(backend, clock)
		local old = assert(a:acquire("k", initial))
		local newer: FencedStore.Profile? = nil
		barrier = function()
			now = 30
			newer = assert(b:acquire("k", initial))
			assert(b:update(assert(newer, "takeover completed"), function(data)
				data.coins = 20
				return data
			end))
		end
		local result, err = a:update(old, debit)
		assert(result == nil and err == "lease lost", "stale writer rejected")
		local current = assert(newer, "takeover completed")
		local committed = assert(b:renew(current))
		assert(
			committed.generation == 2 and committed.data.coins == 20 and next(committed.data.receipts) == nil,
			"new owner data survives discarded old candidate"
		)
	end,
	["last transform and returned durable result are authoritative"] = function()
		for _, operation in { "acquire", "update", "save", "renew", "release" } do
			for _, finalConflict in { false, true } do
				local mine: any = {
					version = 1,
					generation = 2,
					revision = 8,
					data = initial({}),
					lease = { sessionId = "a", expiresAt = 30 },
				}
				local other: any = {
					version = 1,
					generation = 3,
					revision = 9,
					data = initial({}),
					lease = { sessionId = "b", expiresAt = 30 },
				}
				local persisted: any = nil
				local a = store({
					update = function(_key, transform)
						transform(if finalConflict then mine else other)
						persisted = transform(if finalConflict then other else mine)
						return true, persisted
					end,
				}, function()
					return 0
				end)
				local token = { key = "k", sessionId = "a", generation = 2, data = {} }
				local result, err = (a :: any)[operation](a, if operation == "acquire" then "k" else token, initial)
				if finalConflict then
					assert(result == nil and err ~= nil and persisted == other, "final conflict is authoritative")
				else
					assert(
						result and err == nil and result.data.coins == persisted.data.coins,
						"only final persisted result returned"
					)
					assert(persisted.revision == 9, "discarded callback cannot advance revision")
				end
			end
		end
	end,
	["backend failure and lost ACK replay never double debit or publish candidate"] = function()
		for _, lostAck in { false, true } do
			local memory = MemoryBackend.new()
			local fail = false
			local a = store({
				update = function(key, transform)
					if fail then
						fail = false
						memory.update(key, function(old)
							local candidate = transform(old)
							return if lostAck then candidate else old
						end)
						return false, "lost ACK"
					end
					return memory.update(key, transform)
				end,
			}, function()
				return 0
			end)
			local token = assert(a:acquire("k", initial))
			fail = true
			local result, err = a:update(token, debit)
			assert(result == nil and err == "lost ACK" and token.data.coins == 10, "failed ACK cannot publish success")
			local replay = assert(a:update(token, debit))
			assert(replay.data.coins == 7 and replay.data.receipts.transfer.amount == 3, "replay cannot double debit")
		end
	end,
	["unsupported wrapper malformed bounds and clocks refuse mutation"] = function()
		local memory = MemoryBackend.new()
		memory.update("k", function()
			return { version = 2, data = { coins = 19 } }
		end)
		local now = 0
		local a = store(memory, function()
			return now
		end)
		local result, err = a:acquire("k", initial)
		assert(result == nil and err == "unsupported record version", "newer wrapper refused")
		memory.update("k", function(old)
			assert(old.version == 2 and old.data.coins == 19, "no wrapper downgrade")
			return old
		end)
		for _, value in { -1, 0 / 0, math.huge, 1.5, 9007199254740991 } do
			now = value
			local profile, reason = a:acquire("fresh", initial)
			assert(profile == nil and reason == "invalid clock", "invalid authoritative time refused")
		end
		assert(a:acquire(string.rep("k", 51), initial) == nil, "key length bounded")
		for _, duration in { 0, -1, 0 / 0, math.huge, 1.5, 86401 } do
			assert(not pcall(FencedStore.new, memory, {
				sessionId = "a",
				leaseSeconds = duration,
				now = function()
					return 0
				end,
			}), "invalid lease duration refused")
		end
		assert(not pcall(FencedStore.new, memory, {
			sessionId = "",
			leaseSeconds = 1,
			now = function()
				return 0
			end,
		}), "empty session identity refused")
	end,
	["suppressed identity update skips the write only while the lease is healthy"] = function()
		local memory = MemoryBackend.new()
		local now = 0
		local a = FencedStore.new(memory, {
			sessionId = "a",
			leaseSeconds = 30,
			now = function()
				return now
			end,
			suppressIdentityUpdates = true,
		})
		local token = assert(a:acquire("k", initial))
		local identity = function(data)
			return data
		end
		token = assert(a:update(token, identity))
		local _, quiet = memory.update("k", function(old)
			return old
		end)
		assert(quiet.revision == 1, "healthy identity update publishes nothing")
		-- Past half the lease the identity update is the owner's renewal and must publish.
		now = 20
		token = assert(a:update(token, identity))
		local _, renewed = memory.update("k", function(old)
			return old
		end)
		assert(renewed.revision == 2 and renewed.lease.expiresAt == 50, "identity update renews a lapsing lease")
		-- An owner kept busy only by identity updates never loses its lease.
		now = 45
		assert(a:update(token, identity), "lease survives past the original expiry")
	end,
	["read-through refresh publishes only a lease renewal and never stale data"] = function()
		local memory = MemoryBackend.new()
		local now = 0
		local a = store(memory, function()
			return now
		end)
		local token = assert(a:acquire("k", initial))
		local _, acquired = memory.update("k", function(old)
			return old
		end)
		local refreshed = assert(a:refresh(token))
		assert(refreshed.data.coins == 10, "refresh returns current data")
		local _, quiet = memory.update("k", function(old)
			return old
		end)
		assert(quiet.revision == acquired.revision, "healthy lease identity refresh publishes nothing")
		-- An external commit is visible to the next read-through.
		memory.update("k", function(old)
			old.data.coins = 4
			old.revision += 1
			return old
		end)
		local current = assert(a:refresh(refreshed))
		assert(current.data.coins == 4, "refresh never serves stale data")
		-- Past half the lease the refresh must still renew the fence.
		now = 20
		local renewed = assert(a:refresh(current))
		assert(renewed.leaseExpiresAt == 50, "stale lease renewed on refresh")
		local _, durable = memory.update("k", function(old)
			return old
		end)
		assert(durable.revision == acquired.revision + 2 and durable.data.coins == 4, "one renewal write only")
	end,
}
