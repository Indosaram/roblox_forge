--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local Runtime = require("../../../../genres/survival-coop/module/GatheringRuntime")
local Gathering = require("../../../../genres/survival-coop/module/Gathering")
local Bridge = require("../../../../genres/survival-coop/module/GatheringBridge")
local bridgeSpecs: { [string]: () -> () } = require("../../../../genres/survival-coop/module/GatheringBridge.spec")
local Content = require("../../../../core/domain/survival/Content")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Memory = require("../../../../core/infra/data/MemoryBackend")
local config =
	serde.decode("yaml", fs.readFile("cli/forge/fixtures/inventory-conservation/fixture-survival/econ.yml")).genre_contract
local inventory = config.configs["survival-coop"].inventory
inventory.carriedContainer = "bag"
inventory.content.nodes = { { id = "tree", respawnMillis = 1000, harvest = { { item = "wood", quantity = 3 } } } }
local content = assert(Content.canonicalize(inventory.content))
local now = 0
local function clock(): number
	return now
end
local function encode(value: any): string
	return serde.encode("json", value)
end
local backend = Memory.new()
for name, check in bridgeSpecs do
	check()
	print("PASS GatheringBridge: " .. name)
end
local function readKey(key: string): any
	local ok, value = backend.update(key, function(old)
		return old
	end)
	assert(ok, "durable read")
	return value
end
local session: Session.Session
local runtime: Runtime.Runtime?
local reachable = true
local bridge = Bridge.new({
	resolve = function()
		return runtime
	end,
})
local action = "survival-coop:gather"
local policy = {
	actions = { action },
	personal = { namespace = "personal", inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" } },
}
local function open()
	session = Session.new(
		{ packConfig = config, contracts = { Contract }, controls = {}, storeName = "GatherFixture", durable = policy },
		backend,
		{ sessionId = "owner", lockTimeout = 120, retries = 0, now = clock },
		{
			now = clock,
			roll = function()
				return 0
			end,
			emit = function() end,
			encode = encode,
			survivalGathering = bridge,
		},
		policy
	)
end
open()
assert(session.join("alice").ok and session.join("bob").ok, "two actors joined")
local initial = Gathering.new(
	"world",
	content,
	{ { id = "tree-1", catalogId = "tree", position = { x = 0, y = 0, z = 0 }, charges = 1, qualityMilli = 1000 } }
)
local function source()
	runtime = assert(Runtime.new({
		key = "nodes:world",
		initial = initial,
		content = content,
		now = clock,
		nowMillis = function()
			return now * 1000
		end,
		maxReceipts = 4096,
		resolvePersonal = function(actor)
			return session.personalTransfer(actor)
		end,
		access = function(req, bag)
			if req.sessionEpoch ~= (session.envelope(req.actorId).commands :: any).epoch then
				return nil
			end
			return {
				actorId = req.actorId,
				carriedContainer = bag.id,
				worldRevision = "world",
				equipment = function()
					return {}
				end,
				reachable = function()
					return reachable
				end,
			}
		end,
	}, Fenced.new(backend, { sessionId = "owner", leaseSeconds = 120, now = clock, budget = { encode = encode } })))
end
source()
local generation = readKey("nodes:world").generation
local gatherArgs: { any } = { "tree-1", 0 }
local request = { requestId = "harvest", sessionEpoch = 0, action = action, args = gatherArgs }
assert(
	not session.command(
		"alice",
		{ actorId = "bob", requestId = "forged", sessionEpoch = 0, action = action, args = request.args }
	).ok,
	"forged actor"
)
assert(
	not session.command("alice", { requestId = "epoch", sessionEpoch = 9, action = action, args = request.args }).ok,
	"forged epoch"
)
reachable = false
assert(not session.command("alice", request).ok, "trusted reach refusal")
reachable = true
local port = assert(session.personalTransfer("alice"))
local stale = port.profile()
assert(port.personal:inventoryLens():update(stale, function(data)
	for index = 1, 18 do
		data.inventory.items["filler" .. index] = {
			itemId = "filler" .. index,
			catalogId = "light",
			quantity = 1,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = {},
		}
	end
	return data
end))
local first = session.command("alice", request)
assert(first.data and first.data.status == "pending", tostring(first.reason))
local loser = session.command("bob", request)
assert(not loser.ok and loser.reason == "STALE_VERSION", "two-client final charge")
assert(readKey("nodes:world").generation == generation, "one shared source generation")
assert(session.snapshot("bob").survivalGathering.nodes["tree-1"].charges == 0, "source depletion snapshot")
local _, staleError = port.personal:commit(stale, stale.data.stateRevision, stale.data.envelope, nil)
assert(staleError == "STALE_PERSONAL_REVISION", "personal CAS excludes stale bag commit")
assert(session.close("alice").ok and session.close("bob").ok, "two actors closed")
now = 10
open()
source()
assert(session.join("alice").ok, "rejoin recovers pending bag")
local current = assert(session.personalTransfer("alice"))
assert(current.personal:inventoryLens():update(current.profile(), function(data)
	for index = 1, 18 do
		data.inventory.items["filler" .. index] = nil
	end
	return data
end))
session.advance(now)
local replay = session.command("alice", request)
assert(replay.ok, "restart binds original expiry: " .. tostring(replay.reason))
for _ = 1, 100 do
	now += 1
	assert(session.command("alice", request).ok, "100 exact repeats")
end
now += 1
local conflictArgs: { any } = { "other", 0 }
local conflicting = { requestId = "harvest", sessionEpoch = 0, action = action, args = conflictArgs }
local conflict = session.command("alice", conflicting)
assert(conflict.data and conflict.data.status == "conflict", "conflict distinct")
local total = 0
for _, item in session.snapshot("alice")["survival-coop"].inventory.bag.items do
	if item.catalogId == "wood" then
		total += item.quantity
	end
end
assert(total == 15, "exactly one gather yield")
assert(readKey("player-alice") == nil and readKey("player-bob") == nil, "no legacy namespace")
print(
	"PASS gathering-session: final charge, stable source generation, 100 repeats/conflict, restart expiry, automatic pending recovery, forged authority/reach, source snapshot, personal CAS, no legacy mutation"
)
