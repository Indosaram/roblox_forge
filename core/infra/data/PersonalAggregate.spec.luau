--!strict
local Personal = require("./PersonalAggregate")
local Fenced = require("./FencedStore")
local Memory = require("./MemoryBackend")
local Transfer = require("./ItemTransfer")
local Inventory = require("../../domain/inventory/Inventory")
local Catalog = require("../../domain/inventory/ItemCatalog")
local serde = require("@lune/serde")
local function encode(value: any): string
	return serde.encode("json", value)
end
local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000 } })

local function initial(): any
	local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	bag = assert(Inventory.add(bag, catalog, {
		itemId = "wood",
		catalogId = "wood",
		quantity = 10,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = {},
	}, bag.version))
	return {
		version = 1,
		genres = {
			survival = { inventory = { bag = Inventory.save(bag) }, vitals = { health = 90 }, jobs = { pin = 1 } },
			other = { coins = 12 },
		},
		commands = { epochs = { ["1"] = { outcomes = {} } } },
	}
end
local function valid(value: any): boolean
	return type(value) == "table"
		and value.version == 1
		and type(value.genres) == "table"
		and pcall(Inventory.fromSave, value.genres.survival.inventory.bag, catalog)
end
local function fixture(): any
	local c: any = { now = 0, fail = false, lost = false }
	c.memory = Memory.new()
	c.backend = {
		update = function(key: string, transform: Memory.Transform): (boolean, any)
			if c.barrier then
				local barrier = c.barrier
				c.barrier = nil
				c.memory.update(key, function(old: any): any
					transform(old)
					return old
				end)
				barrier()
			end
			if c.fail then
				c.fail = false
				c.memory.update(key, function(old: any): any
					local candidate = transform(old)
					return if c.lost then candidate else old
				end)
				return false, "ACK_FAILURE"
			end
			return c.memory.update(key, transform)
		end,
	}
	c.options = {
		namespace = "personal-v1",
		store = {
			budget = { encode = encode },
			sessionId = "a",
			leaseSeconds = 30,
			now = function(): number
				return c.now
			end,
		},
		validateEnvelope = valid,
		inventoryPath = { "genres", "survival", "inventory", "bag" },
	}
	c.personal = Personal.new(c.backend, c.options)
	c.token = assert(c.personal:load("1", initial))
	c.lens = c.personal:inventoryLens()
	return c
end
local function reserve(c: any)
	local profile, err = c.lens:update(c.token, function(data: any): any
		local bag = Inventory.fromSave(data.inventory, catalog)
		local reserved = assert(Inventory.reserve(bag, "Transfer101", { wood = 3 }, bag.version))
		data.inventory = Inventory.save(reserved)
		data.itemTransfers.receipts.Transfer101 = { phase = "PREPARED" }
		return data
	end)
	assert(profile, err)
end
return {
	["personal budget required and transfer receipt overflow preserves sole owner"] = function()
		local c = fixture()
		local options = table.clone(c.options)
		options.store = table.clone(options.store)
		options.store.budget = nil
		assert(not pcall(Personal.new, c.backend, options), "personal guard mandatory")
		local _, before = c.memory.update(c.token.key, function(old)
			return old
		end)
		options.store.budget = { encode = encode, maxBytes = #encode(before) }
		local guarded = Personal.new(c.backend, options)
		local lens = guarded:inventoryLens()
		local rejected, err = lens:update(c.token, function(data)
			data.itemTransfers.receipts.large = { phase = "PREPARED", binding = string.rep("r", 256) }
			return data
		end)
		assert(not rejected and err == "PERSISTED_VALUE_TOO_LARGE", "receipt bytes counted in final wrapper")
		local _, after = c.memory.update(c.token.key, function(old)
			return old
		end)
		assert(encode(before) == encode(after), "overflow preserves entire persisted record")
		assert(c.token.data.stateRevision == 0 and c.token.data.inventory == nil, "no token mutation or mirror")
	end,
	["same generation transfer mutation rejects obsolete whole envelope"] = function()
		local c = fixture()
		local candidate = c.token.data.envelope
		candidate.genres.other.coins = 99
		reserve(c)
		local current, err = c.personal:commit(c.token, 0, candidate)
		assert(current and err == "STALE_PERSONAL_REVISION", "CAS rejects stale same-generation candidate")
		assert(
			current.generation == c.token.generation and current.data.stateRevision == 1,
			"generation alone unchanged"
		)
		assert(
			current.data.envelope.genres.other.coins == 12
				and current.data.itemTransfers.receipts.Transfer101.phase == "PREPARED",
			"other state and receipt preserved"
		)
		assert(
			current.data.envelope.genres.survival.inventory.bag.reservations.Transfer101.wood == 3,
			"reservation preserved"
		)
		assert(current.data.inventory == nil, "no persisted inventory mirror")
	end,
	["callback replay sees concurrent revision and cannot publish candidate"] = function()
		local c = fixture()
		c.barrier = function()
			reserve(c)
		end
		local current, err = c.personal:commit(c.token, 0, initial())
		assert(
			current and err == "STALE_PERSONAL_REVISION" and current.data.stateRevision == 1,
			"last callback authoritative"
		)
	end,
	["lost ACK replays matching ledger outcome before stale CAS"] = function()
		for _, lost in { false, true } do
			local c = fixture()
			local candidate = initial()
			candidate.genres.other.coins = 9
			candidate.commands.epochs["1"].outcomes.req =
				{ binding = "buy", expiresAt = 20, result = { ok = true, stateVersion = 1 } }
			local request = { epoch = 1, requestId = "req", binding = "buy" }
			c.fail, c.lost = true, lost
			local failed, err, _, failedCommit = c.personal:commit(c.token, 0, candidate, request)
			assert(not failed and err == "ACK_FAILURE" and not failedCommit, "unconfirmed commit cannot publish")
			local current, reason, outcome, committed = c.personal:commit(c.token, 0, candidate, request)
			assert(committed == not lost, "only confirmed new write permits notification")
			assert(
				current and not reason and outcome.ok and current.data.stateRevision == 1,
				"replay or first commit once"
			)
			candidate.genres.other.coins = 500
			local replayed, replayError, _, replayCommitted = c.personal:commit(c.token, 0, candidate, request)
			assert(not replayCommitted, "known replay never repeats notification")
			assert(
				replayed and not replayError and replayed.data.envelope.genres.other.coins == 9,
				"obsolete candidate ignored"
			)
			request.binding = "changed"
			local _, conflict = c.personal:commit(c.token, 0, candidate, request)
			assert(conflict == "REQUEST_CONFLICT", "binding conflict before CAS")
		end
	end,
	["expired known outcome cannot ACK before stale CAS including callback replay"] = function()
		for _, replayCallback in { false, true } do
			local c = fixture()
			local candidate = initial()
			candidate.commands.epochs["1"].outcomes.req =
				{ binding = "buy", expiresAt = 10, result = { ok = true, stateVersion = 1 } }
			local request = { epoch = 1, requestId = "req", binding = "buy" }
			assert(c.personal:commit(c.token, 0, candidate, request), "initial outcome committed")
			if replayCallback then
				c.now = 9
				c.barrier = function()
					c.now = 10
				end
			else
				c.now = 10
			end
			candidate.genres.other.coins = 999
			local current, err, outcome = c.personal:commit(c.token, 0, candidate, request)
			assert(current and err == "REQUEST_EXPIRED" and outcome == nil, "expired receipt never ACKs")
			assert(
				current.data.stateRevision == 1 and current.data.envelope.genres.other.coins == 12,
				"expired replay never mutates"
			)
		end
	end,
	["refresh noops and releases preserve actual current data"] = function()
		local c = fixture()
		reserve(c)
		local current = assert(c.personal:refresh(c.token))
		assert(current.data.stateRevision == 1, "refresh does not mutate application revision")
		local same = assert(c.lens:update(c.token, function(data: any): any
			return data
		end))
		assert(same.data.inventory.reservations.Transfer101.wood == 3, "lens sees current")
		c.token.data.envelope.genres.other.coins = 999
		assert(c.personal:releaseLock(c.token), "release current data only")
		local restored = assert(c.personal:load("1", initial))
		assert(
			restored.data.stateRevision == 1 and restored.data.envelope.genres.other.coins == 12,
			"release never blind saves"
		)
		assert(c.personal:refresh(c.token) == nil, "old generation fenced")
	end,
	["namespaces newer versions and lease expiry fail closed"] = function()
		local c = fixture()
		local wrong = table.clone(c.token)
		wrong.key = "player-1"
		local _, err = c.personal:commit(wrong, 0, initial())
		assert(err == "PERSONAL_NAMESPACE", "legacy namespace not touched")
		c.now = 30
		assert(c.personal:refresh(c.token) == nil, "expired writer rejected")
		c.memory.update(c.token.key, function(old: any): any
			old.data.version = 2
			return old
		end)
		assert(not pcall(c.personal.load, c.personal, "1", initial), "newer aggregate rejected")
	end,
	["real transfer routes sole personal bag and preserves other fields"] = function()
		local c = fixture()
		local tribe = Fenced.new(c.memory, c.options.store)
		local destination = assert(tribe:acquire("tribe-1", function(data)
			data.inventory = Inventory.save(
				Inventory.new("warehouse", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
			)
			return data
		end))
		local lens: Personal.Lens = c.lens
		local router: Transfer.StorePort = {
			update = function(_self, token, transform)
				if token.key == c.token.key then
					return lens:update(token, transform)
				end
				return tribe:update(token, transform)
			end,
			acquire = function(_self, key, transform)
				if key == c.token.key then
					return lens:acquire(key, transform)
				end
				return tribe:acquire(key, transform)
			end,
		}
		local coordinator = Transfer.new(router, catalog, {
			maxReceipts = 10,
			now = function(): number
				return c.now
			end,
			authorize = function(req, proof, _data): boolean
				return req.actor == proof.actor
			end,
		})
		local request = {
			id = "Transfer101",
			actor = "1",
			epoch = "1",
			expiresAt = 100,
			source = c.token.key,
			destination = destination.key,
			itemId = "wood",
			outputId = "wood-transfer",
			quantity = 3,
		}
		local source = c.token
		for _ = 1, 4 do
			local result = coordinator:advance(source, destination, request, { actor = "1" })
			assert(result.error == nil, result.error)
			source, destination = result.source, result.destination
		end
		local saved = assert(c.personal:refresh(source)).data
		assert(saved.envelope.genres.survival.inventory.bag.items.wood.quantity == 7, "single personal owner debited")
		assert(destination.data.inventory.items["wood-transfer"].quantity == 3, "tribe credited once")
		assert(
			saved.envelope.genres.survival.vitals.health == 90
				and saved.envelope.genres.survival.jobs.pin == 1
				and saved.envelope.genres.other.coins == 12
				and saved.inventory == nil,
			"unrelated state preserved without mirror"
		)
		assert(saved.stateRevision == 3, "only prepare escrow and finalization mutate personal revision")
	end,
	["refresh observes external commits without publishing an identity write"] = function()
		local c = fixture()
		local _, before = c.memory.update(c.token.key, function(old)
			return old
		end)
		local token = assert(c.personal:refresh(c.token))
		assert(token.data.stateRevision == c.token.data.stateRevision, "refresh preserves the aggregate revision")
		local _, quiet = c.memory.update(c.token.key, function(old)
			return old
		end)
		assert(quiet.revision == before.revision, "identity refresh publishes no durable write")
		-- An external commit must be observed by the very next refresh.
		c.memory.update(c.token.key, function(old: any): any
			old.data.envelope.genres.other.coins = 77
			old.revision += 1
			return old
		end)
		local fresh = assert(c.personal:refresh(token))
		assert(fresh.data.envelope.genres.other.coins == 77, "refresh reads current committed state")
		local _, observed = c.memory.update(c.token.key, function(old)
			return old
		end)
		assert(observed.revision == before.revision + 1, "reading an external commit publishes nothing")
		-- A lease past half its life still renews on refresh, so fencing is preserved.
		c.now += 20
		local renewed = assert(c.personal:refresh(fresh))
		assert(renewed.leaseExpiresAt ~= nil, "refresh renews a stale lease")
		local _, durable = c.memory.update(c.token.key, function(old)
			return old
		end)
		assert(durable.revision == before.revision + 2, "renewal publishes exactly one durable write")
	end,
}
