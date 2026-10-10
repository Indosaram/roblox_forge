--!strict
-- Local serialized backend only. The parent kills this process after a committed
-- phase but before update returns, then a different process replays the request.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local Profile = require("../ProfileStore")
local Schema = require("../../../domain/state/ProfileSchema")
local Fenced = require("../FencedStore")
local Transfer = require("../ItemTransfer")
local Inventory = require("../../../domain/inventory/Inventory")
local Catalog = require("../../../domain/inventory/ItemCatalog")
local path, mode, barrier = process.args[1], process.args[2], process.args[3]
local records = serde.decode("json", fs.readFile(path))
local restarting = mode == "replay"
local now = if restarting then 60 else 31
local backend = {
	update = function(key: string, transform: (any) -> any): (boolean, any)
		local old = records[key]
		local candidate = transform(if old then serde.decode("json", serde.encode("json", old)) else nil)
		records[key] = candidate
		fs.writeFile(path, serde.encode("json", records))
		local receipts = candidate and candidate.data and candidate.data.itemTransfers
		local receipt = receipts and receipts.receipts.Transfer101
		if not restarting and receipt and receipt.phase == barrier then
			stdio.write("COMMITTED:" .. barrier .. "\n")
			stdio.readLine()
			error("parent must terminate at commit barrier")
		end
		return true, serde.decode("json", serde.encode("json", candidate))
	end,
}
local profile = Profile.new(backend, {
	sessionId = if restarting then "replay" else "producer",
	lockTimeout = 30,
	retries = 3,
	now = function()
		return now
	end,
})
local loaded = assert(profile:load("legacy", function(raw)
	return Schema.migrate(raw, 1, function()
		return { coins = 0, items = {} }
	end, {})
end))
assert(loaded.data.coins == 27 and loaded.data.items.wood == 10, "upgrade preserves quantities")
local outcome = loaded.data.commands.epochs["1"].outcomes["buy-1"]
assert(outcome.binding == "buy" and outcome.result.stateVersion == 4, "committed outcome preserved")
assert(profile:release(loaded), "release upgrade without losing outcomes")
local catalog = Catalog.new({ { id = "wood", stackMax = 100, weightMilli = 1000 } })
local store = Fenced.new(backend, {
	sessionId = if restarting then "replay" else "producer",
	leaseSeconds = 20,
	now = function()
		return now
	end,
})
local function load(key: string, quantity: number): Fenced.Profile
	return assert(store:acquire(key, function(data)
		if data.inventory then
			return data
		end
		local bag = Inventory.new(key, { slots = 20, softWeightMilli = 90000, hardWeightMilli = 90000 })
		if quantity > 0 then
			bag = assert(Inventory.add(bag, catalog, {
				itemId = "wood",
				catalogId = "wood",
				quantity = quantity,
				qualityMilli = 1000,
				durabilityMilli = 0,
				attributes = {},
			}, bag.version))
		end
		return { inventory = Inventory.save(bag), coins = 27 }
	end))
end
local source, destination = load("source", 10), load("destination", 0)
if restarting then
	assert(source.generation == 2 and destination.generation == 2, "restart fences prior leases")
end
-- typeof(setmetatable) stores are opaque to plain table types, so the port
-- delegates onto the same store with the store itself as method self.
local port: Transfer.StorePort = {
	update = function(_: Transfer.StorePort, fencedProfile: Fenced.Profile, transform: Fenced.Transform)
		return store:update(fencedProfile, transform)
	end,
	acquire = function(_: Transfer.StorePort, key: string, migrate: Fenced.Transform)
		return store:acquire(key, migrate)
	end,
}
local transfer = Transfer.new(port, catalog, {
	maxReceipts = 10,
	now = function()
		return now
	end,
	authorize = function()
		return not restarting -- escrow must recover forward even after revocation
	end,
})
local request = {
	id = "Transfer101",
	actor = "1",
	epoch = "1",
	expiresAt = 1000,
	source = "source",
	destination = "destination",
	itemId = "wood",
	outputId = "output",
	quantity = 3,
}
for _ = 1, 5 do
	local result = transfer:advance(source, destination, request, nil)
	source, destination = result.source, result.destination
	assert(result.error == nil, result.error)
end
assert(restarting, "producer must not pass the commit barrier")
assert(source.data.inventory.items.wood.quantity == 7, "source debited once")
assert(destination.data.inventory.items.output.quantity == 3, "destination credited once")
assert(source.data.coins == 27 and destination.data.coins == 27, "unrelated currency preserved")
assert(source.data.itemTransfers.receipts.Transfer101.phase == "FINALIZED", "durable finality")
local replay = transfer:advance(source, destination, request, nil)
assert(replay.status == "confirmed" and replay.stateVersion == 1, "replay same committed outcome")
assert(store:release(source) and store:release(destination), "owned leases released")
print("REPLAY_OK")
