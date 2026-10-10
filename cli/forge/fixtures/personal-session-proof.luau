--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Session = require("../../../core/infra/genre/Session")
local MemoryBackend = require("../../../core/infra/data/MemoryBackend")
local Survival = require("../../../genres/survival-coop/module/Contract")
local Harness = require("../lib/qaharness")
local config =
	serde.decode("yaml", fs.readFile("cli/forge/fixtures/inventory-conservation/fixture-survival/econ.yml")).genre_contract
local policy = {
	actions = { "survival-coop:inventory-move" },
	personal = { namespace = "personal", inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" } },
}
local function request(): any
	local args: { any } = { "bag", "chest", "wood", 3, "part", 2, 2 }
	return {
		requestId = "move",
		sessionEpoch = 0,
		action = "survival-coop:inventory-move",
		args = args,
	}
end
local now = 0
local notifications = 0
local descriptor = table.clone(Survival)
descriptor.actions = table.clone(Survival.actions)
for index, action in descriptor.actions do
	if action.id == "inventory-move" then
		descriptor.actions[index] = table.clone(action)
		descriptor.actions[index].rate = { capacity = 1, refillPerSecond = 2 }
	end
end
local create = descriptor.create
descriptor.create = function(c, services)
	local instance = create(c, services)
	local join, stage = instance.join, instance.stageCommand
	instance.join = function(id, saved)
		local result = join(id, saved)
		if result.ok then
			services.emit({ genre = Survival.id, name = "DefenseBought", playerId = id, data = {} })
		end
		return result
	end
	instance.stageCommand = function(id, action, args, context)
		assert(stage ~= nil, "stage capability")
		local candidate = stage(id, action, args, context)
		if candidate then
			candidate.apply = function()
				error("fenced lane must not apply candidate")
			end
			candidate.notify = function()
				notifications += 1
			end
		end
		return candidate
	end
	return instance
end
local function fresh(backend, host, personalEnabled: boolean?)
	local selectedPolicy = if personalEnabled == false
		then { actions = table.clone(policy.actions) }
		else table.clone(policy)
	return Session.new(
		{
			packConfig = config,
			contracts = { descriptor },
			controls = {},
			storeName = "PersonalSpec",
			durable = selectedPolicy,
		},
		backend,
		{
			sessionId = host,
			lockTimeout = 120,
			retries = 0,
			now = function()
				return now
			end,
		},
		{
			now = function()
				return now
			end,
			roll = function()
				return 0
			end,
			emit = function()
				notifications += 1
			end,
			encode = function(value)
				return serde.encode("json", value)
			end,
		},
		selectedPolicy
	)
end
local gate = Harness.barrier()
local failInit = true
local calls = 0
local accessedKeys: { string } = {}
local backend = {
	update = function(key: string, transform: (any) -> any): (boolean, any)
		table.insert(accessedKeys, key)
		calls += 1
		if failInit and calls == 2 then
			return false, "initial commit failed"
		end
		local ok, value = gate.backend.update(key, transform)
		return ok, value
	end,
}
local session = fresh(backend, "first")
assert(not session.join("1").ok and #session.members() == 0, "failed initial save not published")
assert(notifications == 0, "failed initial join emits nothing")
failInit = false
assert(session.join("1").ok, "initial retry")
assert(session.snapshot("1")[Survival.id].inventory.bag.items.wood.quantity == 10, "single initialized bag")
assert(
	gate.snapshot()["personal:1"].data.envelope.genres[Survival.id].data.inventory.bag.items.wood.quantity == 10,
	"initial bag durable before join success"
)
-- Refresh first, then lose the command commit acknowledgement.
local armed = false
local lostBackend = {
	update = function(key: string, transform: (any) -> any): (boolean, any)
		local ok, value = gate.backend.update(key, transform)
		if armed and value.data.envelope.commands.stateVersion == 1 then
			armed = false
			return false, "lost ACK"
		end
		return ok, value
	end,
}
assert(session.close("1").ok, "release first")
session = fresh(lostBackend, "second")
assert(session.join("1").ok, "join second")
armed = true
local beforeLost = notifications
assert(not session.command("1", request()).ok, "lost ACK no success")
assert(session.snapshot("1")[Survival.id].inventory.bag.items.wood.quantity == 10, "unacknowledged stage not applied")
assert(session.command("1", request()).stateVersion == 1, "known outcome hydrate")
assert(notifications == beforeLost, "lost ACK replay never emits candidate notification")
assert(session.snapshot("1")[Survival.id].inventory.bag.items.wood.quantity == 7, "winning aggregate replaces stage")
local beforeReplays = gate.snapshot()["personal:1"].revision
for _ = 1, 100 do
	assert(session.command("1", request()).stateVersion == 1, "100 durable replays")
end
assert(gate.snapshot()["personal:1"].revision == beforeReplays, "100 durable replays published durable identity writes")
assert(session.close("1").ok, "release second")
local restored = fresh(Harness.barrier(serde.decode("json", serde.encode("json", gate.snapshot()))).backend, "third")
assert(restored.join("1").ok and restored.command("1", request()).stateVersion == 1, "JSON reconstruction")
assert(restored.snapshot("1")[Survival.id].inventory.bag.items.wood.quantity == 7, "no duplicate initial grant")
now = 121
assert(not restored.save("1").ok, "expired lease cannot save")
now = 0
local raceGate = Harness.barrier()
local interleave = false
local raceBackend = {
	update = function(key: string, transform: (any) -> any): (boolean, any)
		return raceGate.backend.update(key, function(old)
			local candidate = transform(old)
			if interleave and candidate.data.envelope.commands.stateVersion == 1 then
				interleave = false
				old.data.stateRevision += 1
				old.data.envelope.genres[Survival.id].data.inventory.bag.items.wood.quantity = 11
				return transform(old)
			end
			return candidate
		end)
	end,
}
local raced = fresh(raceBackend, "race-host")
assert(raced.join("1").ok, "race join")
interleave = true
local beforeRace = notifications
assert(raced.command("1", request()).reason == "STALE_PERSONAL_REVISION", "CAS conflict not success")
assert(
	raced.snapshot("1")[Survival.id].inventory.bag.items.wood.quantity == 11,
	"stale candidate discarded and current hydrated"
)
assert(raced.command("1", request()).stateVersion == 1, "one bounded restage next call")
local secondRequest = request()
secondRequest.requestId = "second-move"
assert(
	raced.command("1", secondRequest).reason == "rate limited",
	"restage retains admission without minting another token"
)
assert(notifications == beforeRace + 1, "only winning CAS notifies")
assert(
	raced.snapshot("1")[Survival.id].inventory.bag.items.wood.quantity == 8,
	"restage preserves concurrent inventory"
)
assert(raced.close("1").ok, "race release")
for _, key in accessedKeys do
	assert(not string.match(key, "^player%-"), "opt-in owner never accesses legacy player namespace")
end
assert(#accessedKeys > 0, "backend key access observed")
local legacy = fresh(MemoryBackend.new(), "legacy-host", false)
assert(legacy.join("legacy").ok, "absent opt-in legacy join")
assert(legacy.personalTransfer("legacy") == nil, "absent opt-in never creates personal transfer owner")
assert(legacy.close("legacy").ok, "absent opt-in legacy close")
print(
	"PASS personal Session initialization failure, sole bag, lost ACK hydration, 100 replay, JSON restart, expired lease"
)
print("PASS personal Session callback CAS interleave hydrates then restages without stale apply")
