--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local run = require("../../lib/run")
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local Runtime = require("../../../../genres/survival-coop/module/SettlementRuntime")
local Transfer = require("../../../../genres/survival-coop/module/TransferRuntime")
local Bridge = require("../../../../genres/survival-coop/module/TransferBridge")
local Settlement = require("../../../../core/domain/settlement/Settlement")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Catalog = require("../../../../core/domain/inventory/ItemCatalog")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Memory = require("../../../../core/infra/data/MemoryBackend")
local config =
	serde.decode("yaml", fs.readFile("cli/forge/fixtures/inventory-conservation/fixture-survival/econ.yml")).genre_contract
local function encode(value: any): string
	return serde.encode("json", value)
end
local input = if process.args[1] == "restore" then serde.decode("json", process.args[2]) else nil
local direction = if input then input.direction else process.args[1]
local boundary = if input then input.boundary else process.args[2]
local mode = process.args[3]
local cleanup = table.find({
	"SOURCE_FENCED",
	"DESTINATION_SOURCE_FINALIZED",
	"SOURCE_REMOVED",
	"DESTINATION_REMOVED",
	"GRANT_REMOVED",
	"CURSOR_CLEARED",
}, boundary) ~= nil
local now = if input then input.now + 120 else 0
config.configs["survival-coop"].inventory.containers.bag = if direction == "deposit"
	then { config.configs["survival-coop"].inventory.containers.bag[1] }
	else {}
local personalKey, id = "session-personal:1", "transfer:1:0:Transfer101"
local sourceKey = if direction == "deposit" then personalKey else "tribe"
local destinationKey = if direction == "deposit" then "tribe" else personalKey
local memory = Memory.new()
if input then
	for key, value in input.records do
		memory.update(key, function()
			return value
		end)
	end
end
local armed, stopped = false, false
local hits = 0
local events = {}
local checkpoint: (() -> ())? = nil
local function label(key: string, old: any, value: any): string?
	if not old or not value then
		return nil
	end
	local before = old.data.itemTransfers and old.data.itemTransfers.receipts[id]
	local after = value.data.itemTransfers and value.data.itemTransfers.receipts[id]
	local prior = old.data.transferGrants
	local nextGrant = value.data.transferGrants
	if nextGrant and nextGrant.entries[id] and (not prior or not prior.entries[id]) then
		return "GRANT_ACCEPTED"
	end
	if prior and prior.entries[id] and not nextGrant.entries[id] then
		return "GRANT_REMOVED"
	end
	if before and not after then
		return if key == sourceKey then "SOURCE_REMOVED" else "DESTINATION_REMOVED"
	end
	if after and (not before or before.phase ~= after.phase) then
		return (if key == sourceKey then "SOURCE_" else "DESTINATION_") .. after.phase
	end
	if key == sourceKey and now >= 300 and old.generation ~= value.generation then
		return "SOURCE_FENCED"
	end
	local oldCursor = prior and prior.cursors and prior.cursors[personalKey]
	local newCursor = nextGrant and nextGrant.cursors and nextGrant.cursors[personalKey]
	if oldCursor ~= newCursor then
		return if newCursor then "CURSOR_SELECTED" else "CURSOR_CLEARED"
	end
	return nil
end
local backend = {
	update = function(key: string, transform: Memory.Transform): (boolean, any)
		assert(not stopped, "producer attempted write after injected boundary")
		local hit = false
		local prior: any = nil
		local ok, value = memory.update(key, function(old: any)
			prior = old
			local candidate = transform(old)
			local name = label(key, old, candidate)
			if name then
				table.insert(events, name)
			end
			if armed and name == boundary then
				hits += 1
				hit = true
				return if mode == "failure" then old else candidate
			end
			return candidate
		end)
		if hit then
			assert(ok, "fault snapshot persisted")
			if mode == "failure" then
				assert(encode(prior) == encode(value), "failed publication preserves exact durable record")
			else
				assert(label(key, prior, value) == boundary, "committed snapshot has requested named state")
			end
		end
		if checkpoint then
			checkpoint()
		end
		if hit then
			stopped = true
			if mode == "crash" then
				error("NAMED_CRASH:" .. boundary)
			end
			return false, "NAMED_ACK_FAILURE:" .. boundary
		end
		return ok, value
	end,
}
local clock = function(): number
	return now
end
local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000 } })
local warehouse = Inventory.new("warehouse", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
if direction == "withdraw" then
	warehouse = assert(Inventory.add(warehouse, catalog, {
		itemId = "wood",
		catalogId = "wood",
		quantity = 10,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = { origin = "initial" },
	}, warehouse.version))
end
local tribe = assert(Runtime.new(
	{
		key = "tribe",
		windowSeconds = 300,
		catalog = catalog,
		definitions = {},
		now = clock,
		verifyTransfer = function(actor, proof)
			return actor == "1" and proof == "server-spatial-proof"
		end,
		initial = {
			settlement = Settlement.new(
				{ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 },
				"1"
			),
			warehouse = warehouse,
		},
	},
	Fenced.new(backend, {
		sessionId = if input then "tribe-new" else "tribe-old",
		leaseSeconds = 120,
		now = clock,
		budget = {
			encode = encode,
		},
	})
))
local transfer: Transfer.Runtime? = nil
local action = "survival-coop:transfer-" .. direction
local bridge = Bridge.new({
	resolve = function()
		return transfer
	end,
	epoch = function(actor)
		return tribe.epoch(actor)
	end,
	request = function(actor, _action, args, context, _origin)
		local window = tribe.epochWindow(actor, context.sessionEpoch)
		local req, err = assert(transfer, "joined transfer runtime").resolveRequest({
			actor = actor,
			epoch = context.sessionEpoch,
			requestId = context.requestId,
			direction = direction,
			itemId = args[1],
			quantity = args[2],
			personalKey = personalKey,
		}, if window then window.expiresAt else nil)
		return req, 0, "server-spatial-proof", err
	end,
})
local policy = {
	actions = { "survival-coop:transfer-deposit", "survival-coop:transfer-withdraw" },
	personal = {
		namespace = "session-personal",
		inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" },
	},
}
local session = Session.new(
	{
		packConfig = config,
		contracts = { Contract },
		controls = {},
		storeName = "TransferSessionProof",
		durable = policy,
	},
	backend,
	{ sessionId = if input then "personal-new" else "personal-old", lockTimeout = 120, retries = 0, now = clock },
	{
		now = clock,
		roll = function()
			return 0
		end,
		emit = function() end,
		encode = encode,
		survivalTransfer = bridge,
	},
	policy
)
assert(session.join("1").ok, "real registered Session joins")
local access = assert(session.personalTransfer("1"), "trusted sole personal access")
transfer = Transfer.new({
	personal = access.personal,
	profile = access.profile,
	install = access.install,
	tribe = tribe.transferStore(),
	catalog = catalog,
	now = clock,
	maxReceipts = 4096,
})
local epoch = assert(session.commandEpoch("1", action), "real external epoch route")
local args: { any } = { "wood", 3 }
local request = {
	requestId = "Transfer101",
	sessionEpoch = 0,
	action = action,
	args = args,
}
assert(session.personalTransfer("not-joined") == nil, "unjoined actor access denied")
local function records(): any
	local result = {}
	for _, key in { personalKey, "tribe" } do
		local _, value = memory.update(key, function(old)
			return old
		end)
		result[key] = value
	end
	return result
end
local function conserve(final: boolean)
	local saved = records()
	local bags = {
		[personalKey] = saved[personalKey].data.envelope.genres["survival-coop"].data.inventory.bag,
		tribe = Inventory.save(saved.tribe.data.aggregate.warehouse),
	}
	local source, destination = bags[sourceKey], bags[destinationKey]
	local owned = 0
	for _, bag in bags do
		for _, item in bag.items do
			owned += item.quantity
		end
	end
	local receipt = saved[sourceKey].data.itemTransfers
	receipt = receipt and receipt.receipts[id]
	local credited = destination.items[id .. ":output"]
	local escrow = if receipt and receipt.phase == "ESCROWED" and not credited then 3 else 0
	assert(owned + escrow == 10, "owned plus uncredited escrow conserved at every persisted write")
	if receipt and (receipt.phase == "PREPARED" or receipt.phase == "ESCROWED" or receipt.phase == "FINALIZED") then
		local bag = Inventory.fromSave(source, catalog)
		assert(Inventory.available(bag, "wood") == 7, "reserved or escrowed units unavailable")
		assert(Inventory.consume(bag, "wood", 8, bag.version) == nil, "cannot double spend transferred units")
	end
	if final then
		assert(source.items.wood.quantity == 7 and credited.quantity == 3, "final seven/three")
		assert(credited.attributes.origin == "initial", "attributes retained")
	end
end
local barrierChecked = false
checkpoint = function()
	conserve(false)
	if armed and not barrierChecked then
		barrierChecked = true
		local before = encode(session.snapshot("1"))
		session.advance(now)
		assert(encode(session.snapshot("1")) == before, "advance cannot race suspended transfer")
		assert(not session.save("1").ok, "save serialized behind transfer")
		assert(not session.close("1").ok, "close serialized behind transfer")
		assert(not session.command("1", request).ok, "second command serialized")
		assert(not session.recoverTransfers("1", 1).ok, "recovery serialized")
	end
end
conserve(false)
local function finish(): any
	local response = session.command("1", request)
	for _ = 1, 8 do
		if response.ok then
			break
		end
		session.advance(now)
		response = session.command("1", request)
	end
	assert(response.ok and response.stateVersion ~= nil, response.reason)
	conserve(true)
	assert(
		assert(session.envelope("1").commands, "personal ledger exists").stateVersion == 0,
		"external transfer avoids personal command outcome"
	)
	local view = session.snapshot("1")["survival-coop"].inventory.bag
	assert(
		(if direction == "deposit" then view.items.wood.quantity else view.items[id .. ":output"].quantity)
			== (if direction == "deposit" then 7 else 3),
		"actual Session hydration"
	)
	for _ = 1, 3 do
		assert(encode((session.command("1", request))) == encode(response), "exact terminal Session result")
	end
	return response
end
if not input then
	if cleanup then
		finish()
		for _, tick in { 100, 200 } do
			now = tick
			session.recoverTransfers("1", 1)
		end
		now = 300
	end
	armed = true
	local ok, err = pcall(function()
		for _ = 1, 8 do
			if cleanup or boundary == "CURSOR_SELECTED" then
				if not cleanup and not table.find(events, "GRANT_ACCEPTED") then
					session.command("1", request)
				end
				session.recoverTransfers("1", 1)
			else
				session.command("1", request)
			end
			if stopped then
				break
			end
		end
	end)
	assert(
		hits == 1 and stopped,
		"named fault never hit: " .. boundary .. " events=" .. encode(events) .. " error=" .. tostring(err)
	)
	if mode == "crash" then
		assert(not ok and string.find(tostring(err), "NAMED_CRASH", 1, true), "committed crash observed")
	else
		assert(ok, tostring(err))
	end
	conserve(cleanup)
	local result = run.exec("lune", {
		"run",
		"cli/forge/fixtures/item-transfer-recovery/session",
		"restore",
		encode({ records = records(), direction = direction, boundary = boundary, now = now, cleanup = cleanup }),
	})
	assert(result.ok, result.stderr .. result.stdout)
	print("PASS Session named " .. direction .. " " .. boundary .. " " .. mode)
elseif input.cleanup then
	for _ = 1, 8 do
		session.advance(now)
	end
	conserve(true)
	local saved = records()
	assert(next(saved.tribe.data.transferGrants.entries) == nil, "grant retired")
	for _, key in { personalKey, "tribe" } do
		assert(next(saved[key].data.itemTransfers.receipts) == nil, "receipts retired")
	end
	assert(saved.tribe.data.transferGrants.cursors[personalKey] == nil, "cursor reclaimed")
	local response = session.command("1", request)
	assert(
		not response.ok and response.reason == "REQUEST_EXPIRED",
		"retired request cannot remint: " .. encode(response)
	)
	for _ = 1, 3 do
		assert(encode((session.command("1", request))) == encode(response), "expired result stable")
	end
else
	local response = finish()
	if input.retained then
		assert(epoch == 1, "old epoch retained across rollover")
		assert(encode(response) == encode(input.response), "terminal result stable across fresh process and old epoch")
	else
		local result = run.exec("lune", {
			"run",
			"cli/forge/fixtures/item-transfer-recovery/session",
			"restore",
			encode({
				records = records(),
				direction = direction,
				boundary = boundary,
				now = 180,
				retained = true,
				response = response,
			}),
		})
		assert(result.ok, result.stderr .. result.stdout)
	end
end
