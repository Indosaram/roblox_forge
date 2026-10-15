--!strict
-- Actual Session death lifecycle and serialized recovery proof.
-- No alternate adapter, fake effect callback, or replacement command journal.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local run = require("../../lib/run")
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local Vitals = require("../../../../core/domain/survival/Vitals")
local DeathBundle = require("../../../../core/domain/survival/DeathBundle")
local Harness = require("../../lib/qaharness")
local Adapter = require("../../../../genres/survival-coop/module/CraftingAdapter")

-- Fixed-seed Park-Miller LCG: deterministic host GUIDs. The restore child uses a different seed so
-- its host identity stays distinct from the parent process, as random GUIDs were.
local lcgState = if process.args[1] == "restore" then 20261015 else 1790899200
local function nextInRange(low: number, high: number): number
	lcgState = (lcgState * 48271) % 2147483647
	return low + lcgState % (high - low + 1)
end

local function hostGuid(): string
	return string.gsub("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx", "[xy]", function(c)
		return string.format("%x", if c == "x" then nextInRange(0, 15) else nextInRange(8, 11))
	end)
end

local config = serde.decode("yaml", fs.readFile("cli/forge/fixtures/vitals-food-rest/fixture-survival/econ.yml"))
config.genre_contract.configs["survival-coop"].survivalDeath = true
local inventoryConfig = config.genre_contract.configs["survival-coop"].inventory
inventoryConfig.content.limits.slots = 4
table.insert(inventoryConfig.content.items, { id = "filler", name = "Fixture filler", stackMax = 1, weightMilli = 0 })
table.insert(inventoryConfig.containers.chest, {
	itemId = "filler-stack",
	catalogId = "filler",
	quantity = 1,
	qualityMilli = 1000,
	durabilityMilli = 0,
	attributes = {},
})
local hostId = hostGuid()
local nowMillis = 1790899200000
local wall = nowMillis / 1000
local initialVitals = Vitals.new(nowMillis)
local initialBundles = DeathBundle.new("1", hostId, "bag", nowMillis)
assert(initialVitals.clockMillis == nowMillis and initialBundles.clockMillis == nowMillis, "real Unix constructors")
local gate = Harness.barrier()
local loseDeathAck = false
local lostDeathWrites = 0
local playerX = 0
local fenced = process.args[1] == "fenced"
local policy: any = {
	actions = { "survival-coop:inventory-move", "survival-coop:rest" },
	serverActions = {
		"survival-coop:death-drop",
		"survival-coop:death-pickup",
		"survival-coop:death-expire",
		"survival-coop:server-vitals-tick",
		"survival-coop:respawn",
		"survival-coop:inventory-reserve",
		"survival-coop:vitals-damage",
		"survival-coop:rest-stop",
	},
	tickAction = "survival-coop:server-vitals-tick",
	windowSeconds = 10000,
	maxOutcomes = 64,
}
local function savedEnvelope(): any
	local records = gate.snapshot()
	return if fenced then records["death-personal:1"].data.envelope else records["player-1"].data
end
local function newSession(serverId: string, revision: string)
	policy.personal = if fenced
		then { namespace = "death-personal", inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" } }
		else nil
	return Session.new({
		packConfig = config.genre_contract,
		contracts = { Contract },
		controls = {},
		storeName = "death-session-proof",
		durable = policy,
	}, {
		update = function(key, transform)
			local ok, value = gate.backend.update(key, transform)
			local envelope = if type(value) == "table" and type(value.data) == "table"
				then (if fenced then value.data.envelope else value.data)
				else nil
			local slice = if envelope and envelope.genres then envelope.genres["survival-coop"] else nil
			local death = if slice then slice.data.death else nil
			if ok and loseDeathAck and death and death.bundles.lastSequence == 1 then
				loseDeathAck = false
				lostDeathWrites += 1
				return false, "fixture: committed death acknowledgement lost"
			end
			return ok, value
		end,
	}, {
		sessionId = serverId,
		lockTimeout = 10000,
		retries = 0,
		now = function()
			return wall
		end,
	}, {
		now = function()
			return wall
		end,
		roll = function()
			return 0
		end,
		emit = function(_) end,
		survivalSpatial = {
			campfire = function(_, fireId)
				return if fireId == "near" then { reachable = playerX * playerX <= 144 } else nil
			end,
		},
		encode = function(value)
			return serde.encode("json", value)
		end,
		survivalDeath = {
			worldRevision = revision,
			equipment = function(_)
				return { ["stone-stack"] = true }
			end,
			position = function(_)
				return { x = 3, y = 0, z = 4 }
			end,
			reachable = function(_, position)
				return (position.x - playerX) ^ 2 + position.y ^ 2 + position.z ^ 2 <= 144
			end,
		},
	}, policy)
end
if process.args[1] == "restore" then
	local payload = serde.decode("json", process.args[2])
	fenced = payload.fenced
	gate = Harness.barrier(payload.backend)
	wall = payload.wall
	local restored = newSession(hostGuid(), "fixture-world-v1")
	assert(restored.join("1").ok, "fresh process reacquires actual profile")
	for _ = 1, 100 do
		local replay = restored.commandServer("1", payload.request)
		assert(replay.ok and replay.stateVersion == payload.stateVersion, "fresh process exact death replay")
	end
	local view = restored.snapshot("1")["survival-coop"]
	assert(view.deathBundles.lastSequence == 1 and view.deathBundles.bundles["death:1"] ~= nil, "one stable drop ID")
	assert(view.inventory.bag.items["stone-stack"].quantity == 1, "fresh process retains equipment")
	assert(view.inventory.bag.reservations.job["ration-stack"] == 1, "fresh process retains reservation")
	local saved = restored.envelope("1").genres["survival-coop"].data
	local position = saved.death.locations["death:1"]
	assert(position.x == 3 and position.y == 0 and position.z == 4, "fresh process retains death coordinates")
	assert(restored.close("1").ok, "fresh process releases profile")
	print("PASS fresh-process actual Session death replay100 equipment reservations locations and stable drop")
	return
end
local session = newSession(hostId, "fixture-world-v1")
assert(session.join("1").ok, "real profile joins")
local commandServer = session.commandServer
assert(type(commandServer) == "function", "PENDING_INTEGRATION: Session.commandServer is unavailable")
local function snapshot(): any
	return session.snapshot("1")["survival-coop"]
end
local function equal(left: any, right: any)
	assert(type(left) == type(right), "candidate type changed")
	if type(left) ~= "table" then
		assert(left == right, "candidate changed before durable commit")
		return
	end
	for key, value in left do
		equal(value, right[key])
	end
	for key in right do
		assert(left[key] ~= nil, "unexpected candidate field")
	end
end
local epoch = session.commandEpoch("1")
assert(epoch ~= nil, "server issues command epoch")
local function server(requestId: string, action: string, args: { any })
	return session.commandServer(
		"1",
		{ requestId = requestId, sessionEpoch = epoch, action = "survival-coop:" .. action, args = args }
	)
end
assert(
	server("reserve", "inventory-reserve", { "bag", "job", "ration-stack", 1, snapshot().inventory.bag.version }).ok,
	"real reservation"
)
local request = {
	requestId = "death-drop:1:1",
	sessionEpoch = epoch,
	action = "survival-coop:vitals-damage",
	args = { 100000 },
}
local before = snapshot()
-- Do not session.advance here: the adapter must stage the death-causing elapsed
-- interval with the drop rather than publish dead vitals before a failed save.
wall += 1800
gate.fail(1)
local failed = commandServer("1", request)
assert(not failed.ok, "death commit failure refused: " .. tostring(failed.reason))
equal(snapshot(), before)
loseDeathAck = true
local ambiguous = commandServer("1", request)
assert(not ambiguous.ok and lostDeathWrites == 1, "committed backend loses death acknowledgement")
local persistedDeath = savedEnvelope().genres["survival-coop"].data
assert(persistedDeath.death.bundles.lastSequence == 1, "death really persisted before lost acknowledgement")
equal(snapshot(), before)
local committed = commandServer("1", request)
assert(committed.ok, "death candidate commits on retry")
local after = snapshot()
assert(after.vitals.healthMilli == 0, "death-causing advance committed")
assert(after.deathBundles.lastSequence == 1, "one persisted actual death")
assert(after.inventory.bag.items["stone-stack"].quantity == 1, "equipped retained")
assert(after.inventory.bag.items["ration-stack"].quantity == 1, "reserved quantity retained")
assert(after.inventory.bag.reservations.job["ration-stack"] == 1, "reservation ownership retained")
for _ = 1, 100 do
	local replay = commandServer("1", request)
	equal(replay, committed)
end
equal(snapshot(), after)
assert(not session.dispatch("1", request.action, { 100000 }).ok, "client cannot submit damage")
assert(not session.dispatchServer("1", request.action, { 100000 }).ok, "non-durable bypass refused")
assert(session.close("1").ok, "close with live bundle")
local child = run.exec("lune", {
	"run",
	"cli/forge/fixtures/vitals-food-rest/death-session",
	"restore",
	serde.encode("json", {
		backend = gate.snapshot(),
		wall = wall,
		request = request,
		stateVersion = committed.stateVersion,
		fenced = fenced,
	}),
})
assert(child.ok, child.stdout .. child.stderr)
print(child.stdout)
gate = Harness.barrier(serde.decode("json", serde.encode("json", gate.snapshot())))
local retainedHost = hostGuid()
session = newSession(retainedHost, "fixture-world-v1")
assert(session.join("1").ok, "new host restores active bundle")
epoch = session.commandEpoch("1")
assert(server("active-rebind", "server-vitals-tick", {}).ok, "active bundle host rebind")
assert(
	snapshot().deathBundles.serverId == retainedHost and snapshot().deathBundles.bundles["death:1"] ~= nil,
	"active bundle preserved on same-world rebind"
)
assert(server("revive", "respawn", { 100000, 100000, 80000 }).ok, "durable respawn")
assert(
	session.command("1", { requestId = "rest", sessionEpoch = epoch, action = "survival-coop:rest", args = { "near" } }).ok,
	"rest begins"
)
local resting = snapshot().vitals
gate.fail(1)
assert(not server("stop", "rest-stop", {}).ok, "stop save failure")
equal(snapshot().vitals, resting)
local stopped = server("stop", "rest-stop", {})
assert(stopped.ok, "durable stop")
for _ = 1, 100 do
	equal(server("stop", "rest-stop", {}), stopped)
end
assert(
	not snapshot().vitals.resting
		and snapshot().vitals.fatigueMilli == resting.fatigueMilli
		and snapshot().vitals.clockMillis == resting.clockMillis,
	"stop has no fatigue cost or clock change"
)
assert(not session.dispatch("1", "survival-coop:rest-stop", {}).ok, "client stop denied")
local function move(requestId: string, source: string, target: string, itemId: string)
	local view = snapshot()
	local args: { any } =
		{ source, target, itemId, 1, "filler-stack", view.inventory[source].version, view.inventory[target].version }
	return session.command("1", {
		requestId = requestId,
		sessionEpoch = epoch,
		action = "survival-coop:inventory-move",
		args = args,
	})
end
assert(move("fill", "chest", "bag", "filler-stack").ok, "fill carried capacity with actual inventory move")
local capacityBefore = snapshot()
assert(not server("full-pickup", "death-pickup", { "death:1" }).ok, "capacity rejects whole bundle")
equal(snapshot(), capacityBefore)
assert(move("unfill", "bag", "chest", "filler-stack").ok, "free carried capacity")
playerX = 100
assert(not server("far-pickup", "death-pickup", { "death:1" }).ok, "geometric reach refused")
playerX = 0
local picked = server("pickup", "death-pickup", { "death:1" })
assert(picked.ok, "whole bundle picked up")
for _ = 1, 100 do
	equal(server("pickup", "death-pickup", { "death:1" }), picked)
end
assert(snapshot().deathBundles.bundles["death:1"] == nil, "bundle removed exactly once")
wall += 2400
gate.fail(1)
local liveBefore = snapshot()
session.advance(wall)
equal(snapshot(), liveBefore)
session.advance(wall)
assert(
	snapshot().vitals.healthMilli == 0 and snapshot().deathBundles.lastSequence == 2,
	"scheduled death commits atomically"
)
local expiry = snapshot().deathBundles.bundles["death:2"].expiresMillis
wall = expiry / 1000
gate.fail(1)
assert(not session.close("1").ok, "expiry commit failure blocks close")
assert(
	#session.members() == 1 and snapshot().deathBundles.bundles["death:2"] ~= nil,
	"failed expiry stays joined unchanged"
)
assert(session.close("1").ok, "expiry retry precedes close")
gate = Harness.barrier(serde.decode("json", serde.encode("json", gate.snapshot())))
local mismatch = newSession(hostGuid(), "different-world")
assert(not mismatch.join("1").ok, "world revision mismatch refuses without loss")
session = newSession(hostGuid(), "fixture-world-v1")
assert(session.join("1").ok, "same world new locked host restores")
epoch = session.commandEpoch("1")
assert(server("rebind", "server-vitals-tick", {}).ok, "new locked host rebind commits")
assert(snapshot().deathBundles.bundles["death:2"] == nil, "expiry survives JSON reconstruction")
assert(session.close("1").ok, "release committed profile")
local durable = serde.decode("json", serde.encode("json", gate.snapshot()))
assert(next(durable) ~= nil, "real committed backend serializes")
local hydration = Adapter.new(config.genre_contract.configs["survival-coop"], {
	now = function()
		return wall
	end,
	roll = function()
		return 0
	end,
	emit = function(_)
		error("hydrate must not emit")
	end,
	survivalDeath = {
		worldRevision = "fixture-world-v1",
		equipment = function(_)
			return {}
		end,
		position = function(_)
			return { x = 0, y = 0, z = 0 }
		end,
		reachable = function(_, _)
			return false
		end,
	},
})
assert(hydration.join("1").ok, "hydration target joins")
local hydrate = hydration.hydrate
assert(hydrate ~= nil, "adapter supports committed hydration")
local committedData = savedEnvelope().genres["survival-coop"].data
assert(hydrate("1", committedData).ok, "hydrate actual committed aggregate")
equal(hydration.save("1"), committedData)
local bad = table.clone(committedData)
bad.vitals = table.clone(committedData.vitals)
bad.vitals.healthMilli = 0 / 0
assert(not hydrate("1", bad).ok, "invalid hydration refused")
equal(hydration.save("1"), committedData)
-- A fresh, faster-starving configured actor dies inside newcomer protection.
gate = Harness.barrier()
inventoryConfig.content.vitals.hungerMillisPerUnit = 1000
inventoryConfig.content.vitals.starvationMillisPerUnit = 1000
session = newSession(hostGuid(), "fixture-world-v1")
assert(session.join("1").ok, "newcomer joins")
wall += 200
gate.fail(1)
assert(not session.close("1").ok, "lethal close fails before detach")
assert(#session.members() == 1 and snapshot().vitals.healthMilli == 100000, "failed lethal close preserves live state")
assert(session.close("1").ok, "lethal close retries atomic death")
local newcomer = savedEnvelope().genres["survival-coop"].data
assert(newcomer.vitals.healthMilli == 0 and newcomer.death.bundles.lastSequence == 1, "newcomer death persisted once")
assert(next(newcomer.death.bundles.bundles) == nil, "newcomer has no bundle")
assert(
	newcomer.inventory.bag.items["ration-stack"].quantity == 3
		and newcomer.inventory.bag.items["medicine-stack"].quantity == 2
		and newcomer.inventory.bag.items["stone-stack"].quantity == 1,
	"newcomer bag retained"
)
print("PASS atomic Session death, equipment/reservations, pickup replay, scheduled death/expiry, JSON host rebind")
