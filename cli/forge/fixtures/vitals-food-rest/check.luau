--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local Harness = require("../../lib/qaharness")
local config = serde.decode("yaml", fs.readFile("cli/forge/fixtures/vitals-food-rest/fixture-survival/econ.yml"))
local base = 1790899200
local wall = base
local persistentWall = base
local gate = Harness.barrier()
local playerPosition = { x = 0, y = 0, z = 0 }
local fires = { near = { x = 3, y = 0, z = 4 }, far = { x = 13, y = 0, z = 0 } }
local options =
	{ packConfig = config.genre_contract, contracts = { Contract }, controls = {}, storeName = "vitals-proof" }
local function sessionAt(id: string)
	return Session.new(options, gate.backend, {
		sessionId = id,
		lockTimeout = 120,
		retries = 0,
		now = function()
			return persistentWall
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
			campfire = function(playerId: string, fireId: string): { reachable: boolean }?
				local fire = fires[fireId]
				if playerId ~= "1" or not fire then
					return nil
				end
				local dx, dy, dz = playerPosition.x - fire.x, playerPosition.y - fire.y, playerPosition.z - fire.z
				return { reachable = dx * dx + dy * dy + dz * dz <= 12 * 12 }
			end,
		},
	}, { actions = { "survival-coop:food", "survival-coop:rest" }, windowSeconds = 10000, maxOutcomes = 64 })
end
local session = sessionAt("first")
assert(session.join("1").ok, "join")
local function command(requestId: string, action: string, args: { any })
	return session.command(
		"1",
		{ requestId = requestId, sessionEpoch = 0, action = "survival-coop:" .. action, args = args }
	)
end
local function view(): any
	return session.snapshot("1")["survival-coop"]
end
assert(not command("far", "rest", { "far" }).ok, "far fire refuses")
assert(not view().vitals.resting, "refused rest immutable")
assert(command("near", "rest", { "near" }).ok, "near fire starts rest")
assert(view().vitals.resting, "server geometry accepted")
local forgedReach: { any } = { "far", true }
assert(not session.dispatch("1", "survival-coop:rest", forgedReach).ok, "client cannot provide reachability")
wall = base + 180
persistentWall = wall
session.advance(wall)
gate.fail(1)
assert(not command("eat", "food", { "ration-stack" }).ok, "backend failure refused")
assert(view().inventory.bag.items["ration-stack"].quantity == 3, "failed save keeps food")
assert(view().vitals.hungerMilli == 90000, "failed save keeps vitals")
for _ = 1, 100 do
	assert(command("eat", "food", { "ration-stack" }).ok, "food retry")
end
assert(view().inventory.bag.items["ration-stack"].quantity == 2, "one food debit")
assert(view().vitals.hungerMilli == 100000, "food restoration")
assert(session.close("1").ok, "disconnect saves")
gate = Harness.barrier(serde.decode("json", serde.encode("json", gate.snapshot())))
wall = 0
session = sessionAt("restart")
assert(session.join("1").ok, "restart rebase joins")
assert(view().vitals.hungerMilli == 100000 and view().vitals.activeMillis == 180000, "offline freeze and rebase")
assert(view().vitals.clockMillis == 0 and not view().vitals.resting, "new origin and stopped rest")
for _ = 1, 100 do
	assert(command("eat", "food", { "ration-stack" }).ok, "durable JSON replay")
end
assert(view().inventory.bag.items["ration-stack"].quantity == 2, "restart does not debit twice")
assert(not command("health", "food", { "medicine-stack" }).ok, "full health refuses")
assert(view().inventory.bag.items["medicine-stack"].quantity == 2, "full health preserves food")
wall = 2400
persistentWall = base + 2400
session.advance(wall)
assert(view().vitals.healthMilli == 0, "starvation reaches death")
assert(not session.dispatch("1", "survival-coop:respawn", { 100000, 50000, 80000 }).ok, "client respawn denied")
assert(session.dispatchServer("1", "survival-coop:respawn", { 100000, 50000, 80000 }).ok, "server respawn values")
assert(view().vitalsMovementMilli == 800, "fatigue affects authoritative movement projection")
assert(not session.dispatchServer("1", "survival-coop:respawn", { 100000, 50000, 0 }).ok, "duplicate revival denied")
assert(command("rest-fatigued", "rest", { "near" }).ok, "rest fatigued actor")
wall += 1
persistentWall += 1
session.advance(wall)
assert(view().vitals.fatigueMilli == 78000 and view().vitalsMovementMilli == 1000, "rest reduces actual fatigue")
assert(session.close("1").ok, "final close")
for _, path in { "Vitals.spec", "Consumption.spec" } do
	local specs: { [string]: () -> () } = if path == "Vitals.spec"
		then require("../../../../core/domain/survival/Vitals.spec")
		else require("../../../../core/domain/survival/Consumption.spec")
	for name, test in specs do
		test()
		print("PASS " .. name)
	end
end
local harnessSpecs: { [string]: () -> () } = require("../../lib/qaharness.spec")
for name, test in harnessSpecs do
	test()
	print("PASS " .. name)
end
print("PASS real Session food/rest geometry, failed save, 100 retries and JSON restart")
