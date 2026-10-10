--!strict
-- Actual owner subprocess prerequisite; personal-source authorization is mechanism-only.
local serde = require("@lune/serde")
local process = require("@lune/process")
local run = require("../../lib/run")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Catalog = require("../../../../core/domain/inventory/ItemCatalog")
local Transfer = require("../../../../core/infra/data/ItemTransfer")
local FencedStore = require("../../../../core/infra/data/FencedStore")
local MemoryBackend = require("../../../../core/infra/data/MemoryBackend")
local Personal = require("../../../../core/infra/data/PersonalAggregate")
local Runtime = require("../../../../genres/survival-coop/module/SettlementRuntime")
local Settlement = require("../../../../core/domain/settlement/Settlement")
local GrantRuntime = require("../../../../genres/survival-coop/module/TransferRuntime")
local Bridge = require("../../../../genres/survival-coop/module/TransferBridge")
local direction = process.args[3] or "tribe-to-personal"
local personalKey, tribeKey = "personal-v1:owner", "tribe:qa-tribe"
local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000 } })
local request: Transfer.Request = {
	id = "Transfer101",
	actor = "owner",
	epoch = "0",
	expiresAt = 86400,
	source = if direction == "tribe-to-personal" then tribeKey else personalKey,
	destination = if direction == "tribe-to-personal" then personalKey else tribeKey,
	itemId = "wood-1",
	outputId = "Transfer101-wood",
	quantity = 3,
}

local function context(snapshot: any?, clock: number, session: string): any
	local c: any = { now = clock, calls = 0, failAt = 0, lostAck = false, failures = 0 }
	c.memory = MemoryBackend.new()
	if snapshot then
		for key, record in snapshot do
			c.memory.update(key, function(): any
				return record
			end)
		end
	end
	c.backend = {
		update = function(key: string, transform: MemoryBackend.Transform): (boolean, any)
			c.calls += 1
			if c.calls == c.failAt then
				c.failures += 1
				-- Evaluate the real callback, then either discard or commit its
				-- candidate through MemoryBackend before reporting failure.
				c.memory.update(key, function(old: any): any
					local candidate = transform(old)
					return if c.lostAck then candidate else old
				end)
				return false, "INJECTED_ACK_FAILURE"
			end
			return c.memory.update(key, transform)
		end,
	}

	local options: FencedStore.Options = {
		sessionId = session,
		leaseSeconds = 30,
		now = function(): number
			return c.now
		end,
		budget = {
			encode = function(value: any): string
				return serde.encode("json", value)
			end,
		},
	}
	local function bag(id: string, quantity: number): Inventory.State
		local value = Inventory.new(id, { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		if quantity > 0 then
			value = assert(Inventory.add(value, catalog, {
				itemId = "wood-1",
				catalogId = "wood",
				quantity = quantity,
				qualityMilli = 1000,
				durabilityMilli = 0,
				attributes = { origin = "forest" },
			}, value.version))
		end
		return value
	end
	c.personal = Personal.new(c.backend, {
		namespace = "personal-v1",
		store = options,
		inventoryPath = { "genres", "survival", "inventory", "bag" },
		validateEnvelope = function(value: any): boolean
			return type(value) == "table" and pcall(Inventory.fromSave, value.genres.survival.inventory.bag, catalog)
		end,
	})
	local personal = assert(c.personal:load("owner", function(): any
		return {
			version = 1,
			genres = {
				survival = {
					inventory = { bag = Inventory.save(bag("bag", if direction == "tribe-to-personal" then 0 else 10)) },
					vitals = { health = 90 },
					jobs = { pin = 1 },
				},
				other = { coins = 12 },
			},
		}
	end))
	c.runtime = assert(Runtime.new({
		key = tribeKey,
		catalog = catalog,
		definitions = {},
		now = options.now,
		initial = {
			settlement = Settlement.new(
				{ tribeId = "qa-tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 },
				"owner"
			),
			warehouse = bag("warehouse", if direction == "tribe-to-personal" then 10 else 0),
		},
		verifyTransfer = function(actor: string, proof: any): boolean
			return actor == "owner" and proof == "server-fixture-proof"
		end,
	}, FencedStore.new(c.backend, options)))
	if not snapshot then
		assert(c.runtime.epoch("owner") == 0, "real tribe actor epoch issued")
	end
	local tribe = c.runtime.transferStore()
	local lens = c.personal:inventoryLens()
	local router: Transfer.StorePort = {
		update = function(_self, token, transform)
			if token.key == personalKey then
				return lens:update(token, transform)
			end
			return tribe:update(token, transform)
		end,
		acquire = function(_self, key, transform)
			if key == personalKey then
				return lens:acquire(key, transform)
			end
			return tribe:acquire(key, transform)
		end,
	}
	local projected = assert(lens:update(personal, function(data)
		return data
	end))
	c.source = if direction == "tribe-to-personal" then tribe.profile() else projected
	c.destination = if direction == "tribe-to-personal" then projected else tribe.profile()
	local revision = tribe.profile().data.authority.membershipRevision
	c.coordinator = Transfer.new(router, catalog, {
		maxReceipts = 4096,
		now = options.now,
		authorize = function(req, proof, data): boolean
			if direction == "tribe-to-personal" then
				return tribe.authority(data, req.actor, 0, revision, proof)
			end
			-- Mechanism only: does NOT claim live cross-owner membership validation.
			return req.actor == "owner" and proof == "server-fixture-proof"
		end,
	})
	c.step = function(cleanup: boolean): Transfer.Result
		local result = if cleanup
			then c.coordinator:cleanup(c.source, c.destination, request)
			else c.coordinator:advance(c.source, c.destination, request, "server-fixture-proof")
		c.source, c.destination = result.source, result.destination
		return result
	end
	c.grants = GrantRuntime.new({
		personal = c.personal,
		profile = function()
			return personal
		end,
		install = function(value)
			personal = value
		end,
		tribe = tribe,
		catalog = catalog,
		now = options.now,
		maxReceipts = 4096,
	})
	c.command = function()
		return c.grants.command(request, revision, "server-fixture-proof", "client")
	end
	c.bridge = Bridge.new({
		resolve = function()
			return c.grants
		end,
		epoch = function()
			return 0, nil
		end,
		request = function()
			return request, revision, "server-fixture-proof", nil
		end,
	})
	c.snapshot = function(): any
		local records = {}
		for _, key in { request.source, request.destination } do
			local ok, record = c.memory.update(key, function(old: any): any
				return old
			end)
			assert(ok, "snapshot backend confirmed")
			records[key] = record
		end
		return records
	end
	return c
end

local function conserve(c: any, final: boolean)
	local records = c.snapshot()
	local function projected(key: string): any
		local data = records[key].data
		return {
			inventory = if key == personalKey
				then data.envelope.genres.survival.inventory.bag
				else data.aggregate.warehouse,
			itemTransfers = data.itemTransfers,
		}
	end
	local source, destination = projected(request.source), projected(request.destination)
	local personal = source.inventory.items["wood-1"].quantity
	local output = destination.inventory.items[request.outputId]
	local tribe = if output then output.quantity else 0
	local receipt = source.itemTransfers and source.itemTransfers.receipts[request.id]
	local uncreditedEscrow = if receipt and receipt.phase == "ESCROWED" and not output then 3 else 0
	assert(personal + tribe + uncreditedEscrow == 10, "count credited ownership once, not source liability")
	if final then
		assert(
			personal == 7 and tribe == 3 and output.attributes.origin == "forest",
			"Transfer101 exact final inventory"
		)
	end
end

if process.args[1] == "restore" then
	local input = serde.decode("json", process.args[2])
	local c = context(input.records, 60, "restored")
	for _ = 1, 8 do
		local results = c.grants.recover(1)
		if #results == 0 then
			results = { c.command() }
		end
		conserve(c, false)
		if results[1].status == "confirmed" then
			break
		end
		assert(results[1].error == nil, results[1].error)
	end
	conserve(c, true)
	local replay = c.command()
	assert(replay.status == "confirmed", "same request replay")
	local response = c.bridge.command(
		"owner",
		"survival-coop:transfer-deposit",
		{},
		{ actorId = "owner", requestId = "Transfer101", sessionEpoch = 0 },
		"client",
		nil
	)
	assert(
		response.ok and response.stateVersion == replay.stateVersion and response.stateVersion > 0,
		"bridge terminal mutation version"
	)
	local again = c.bridge.command(
		"owner",
		"survival-coop:transfer-deposit",
		{},
		{ actorId = "owner", requestId = "Transfer101", sessionEpoch = 0 },
		"client",
		nil
	)
	assert(serde.encode("json", response) == serde.encode("json", again), "exact terminal bridge replay")
	c = context(c.snapshot(), 86400, "cleanup")
	assert(c.grants.retire(request), "grant and receipt retirement")
	local records = c.snapshot()
	assert(next(records[tribeKey].data.transferGrants.entries) == nil, "grant retired")
	print("PASS grant restart " .. direction .. " " .. input.label)
else
	local count = 0
	do
		local c = context(nil, 0, "cursor")
		local original = table.clone(request)
		request.quantity = 1
		for index = 1, 3 do
			request.id = "cursor-" .. index
			request.outputId = "cursor-output-" .. index
			assert(c.command().phase == "PREPARED", "cursor fixture reservation")
			if index < 3 then
				for _ = 1, 3 do
					c.command()
				end
			end
		end
		for _ = 1, 12 do
			c.grants.recover(1)
		end
		local records = c.snapshot()
		assert(
			records[request.source].data.itemTransfers.receipts[request.id].phase == "FINALIZED",
			"completed entries cannot starve later pending with bound one"
		)
		for key, value in original do
			(request :: any)[key] = value
		end
		print("PASS persisted recovery cursor advances past completed grants")
	end
	for _, accepted in { false, true } do
		local c = context(nil, 0, "authorization")
		if accepted then
			assert(c.command().phase == "PREPARED", "grant accepted before reservation")
		end
		c.memory.update(tribeKey, function(old: any): any
			old.data.aggregate.settlement.roles.owner = nil
			old.data.aggregate.settlement.membershipRevision += 1
			return old
		end)
		local response = c.command()
		if accepted then
			assert(response.phase == "ESCROWED", "accepted authorization survives later revocation")
			for _ = 1, 4 do
				c.grants.recover(1)
			end
			conserve(c, true)
		else
			assert(response.error == "UNAUTHORIZED", "revoked before acceptance denies")
			local records = c.snapshot()
			assert(next(records[tribeKey].data.transferGrants.entries) == nil, "denied request has no grant")
			conserve(c, false)
		end
	end
	for _, prepared in { false, true } do
		local c = context(nil, 0, "expiry")
		if prepared then
			c.command()
		else
			c.failAt = c.calls + 3
			c.command()
		end
		c = context(c.snapshot(), 86400, "expiry-recovery")
		local results = c.grants.recover(1)
		assert(#results == 1 and results[1].error == "REQUEST_EXPIRED", "expired unescrowed grant cannot debit")
		assert(c.grants.retire(request), "expired absent or cancelled source permits fenced grant retirement")
		assert(next(c.snapshot()[tribeKey].data.transferGrants.entries) == nil, "unused grant reclaimed")
		conserve(c, false)
	end
	print("PASS grant revocation-before/after-acceptance and expired absent/prepared retirement")
	for boundary = 1, 14 do
		for _, lost in { false, true } do
			local c = context(nil, 0, "producer")
			c.failAt, c.lostAck = c.calls + boundary, lost
			for _ = 1, 6 do
				c.command()
				if c.failures == 1 then
					break
				end
			end
			assert(c.failures == 1, "exact failed callback reached")
			local result = run.exec("lune", {
				"run",
				"cli/forge/fixtures/item-transfer-recovery/grants",
				"restore",
				serde.encode("json", { records = c.snapshot(), label = tostring(boundary) .. "/" .. tostring(lost) }),
				direction,
			})
			assert(result.ok, result.stderr .. result.stdout)
			print(result.stdout)
			count += 1
		end
	end
	print("grant-router " .. direction .. ": " .. count .. " passed, 0 failed")
end
