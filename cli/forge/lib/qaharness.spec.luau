--!strict
local qascenario = require("./qascenario")
local qaharness = require("./qaharness")
local qastudio = require("./qastudio")
local Survival = require("../../../genres/survival-coop/module/Contract")
local Fixture = require("../../../genres/survival-coop/module/Adapter.fixture")
local Rng = require("../../../core/domain/random/Rng")
local Journal = require("../../../core/domain/command/Journal")
local qafixtures = require("./qafixtures")

local function target(): qaharness.Target
	return {
		packConfig = {
			api = 1,
			order = { Survival.id },
			configs = { [Survival.id] = table.clone(Fixture.config) :: any },
		},
		contracts = { Survival },
		controls = {},
		storeName = "HarnessSpec",
	}
end

local function scenario(steps: { any }, overrides: { [string]: any }?): any
	local base: any = {
		name = "spec-scenario",
		genre = "survival-coop",
		pack = "fixture-survival",
		kind = "native",
		contract_api = 1,
		timeout_seconds = 60,
		players = { "1" },
		steps = steps,
	}
	local extra: { [string]: any } = overrides or {}
	for key, value in extra do
		base[key] = value
	end
	return base
end

local function hasError(errors: { string }, fragment: string): boolean
	for _, err in errors do
		if string.find(err, fragment, 1, true) ~= nil then
			return true
		end
	end
	return false
end

local function winningSteps(): { any }
	local steps: { any } = {
		{ op = "join", player = "1" },
		{ op = "dispatch", player = "1", action = "survival-coop:buy-defense", expect = "ok" },
		{ op = "advance_to", seconds = 2 },
		{ op = "advance_to", seconds = 4 },
		{ op = "dispatch", player = "1", action = "survival-coop:defend-active", expect = "ok" },
		{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "lastWaveWon", equals = true },
		{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "balance", equals = 5 },
	}
	return steps
end

return {
	["fixture journals distinguish operations and detect mutated results"] = function()
		local function run(destination: string): (any, any, any)
			local raw = scenario({
				{ op = "join", player = "1" },
				{
					op = "role_travel",
					player = "1",
					from = "home",
					destination = destination,
					level = 60,
					objectives = 2,
					expect = "refused",
				},
				{ op = "expect_result", player = "1", field = "ok", equals = false },
				{ op = "close", player = "1" },
			}, { pack = "robango-island", fixtures = { "cli/forge/fixtures/role-routing" } })
			local journal = Journal.new({ seed = 0 })
			local outcome = qaharness.runNative(raw, target(), nil, { journal = journal })
			assert(outcome.ok, table.concat(outcome.failures, "; "))
			return raw, Journal.decode(Journal.encode(journal)), outcome
		end
		local raw, journal, outcome = run("frontier60")
		local _, _, different = run("archipelago")
		assert(outcome.stateHash ~= different.stateHash, "different fixture inputs change final hash")
		local entry = journal.entries[2]
		assert(entry.action == "fixture:role_travel" and entry.actor == "1", "fixture identity recorded")
		assert(entry.args[1].destination == "frontier60" and entry.args[2].ok == false, "inputs and result recorded")
		assert(qaharness.runNative(raw, target(), nil, { replay = journal }).diverged == nil, "original matches")
		entry.args[2].reason = "mutated"
		local replayed = qaharness.runNative(raw, target(), nil, { replay = journal })
		assert(replayed.diverged ~= nil, "mutated result diverges even with unchanged final state")
	end,
	["optional fixture snapshots are cloned deterministic state"] = function()
		local module = {}
		local state = { count = 1 }
		local instances = { [module] = {
			snapshot = function()
				return state
			end,
		} }
		local first = qafixtures.snapshots({ module }, instances)
		state.count = 2
		local second = qafixtures.snapshots({ module }, instances)
		assert(first[1].state.count == 1, "snapshot does not retain mutable fixture state")
		assert(Journal.hash(first) ~= Journal.hash(second), "snapshot changes affect hash")
		local noSnapshot = {}
		assert(#qafixtures.snapshots({ noSnapshot }, { [noSnapshot] = {} }) == 0, "snapshot hook is optional")
	end,
	["declared fixture dispatch works without a scenario name binding"] = function()
		local raw = scenario({
			{ op = "join", player = "1" },
			{
				op = "role_travel",
				player = "1",
				from = "home",
				destination = "frontier60",
				level = 60,
				objectives = 2,
				expect = "refused",
			},
			{ op = "expect_result", player = "1", field = "reason", equals = "transition_not_allowed" },
			{ op = "close", player = "1" },
			{ op = "reload" },
			{ op = "join", player = "1" },
			{
				op = "role_travel",
				player = "1",
				from = "home",
				destination = "frontier60",
				level = 60,
				objectives = 2,
				expect = "refused",
			},
			{ op = "expect_result", player = "1", field = "reason", equals = "transition_not_allowed" },
			{ op = "close", player = "1" },
		}, { pack = "robango-island", fixtures = { "cli/forge/fixtures/role-routing" } })
		local outcome = qaharness.runNative(raw, target())
		assert(outcome.ok, table.concat(outcome.failures, "; "))
		raw.steps[3].equals = "wrong-result"
		assert(not qaharness.runNative(raw, target()).ok, "fixture results reach real harness assertions")
		raw.fixtures = {}
		assert(not qaharness.runNative(raw, target()).ok, "undeclared operation never dispatched")
	end,
	["generated native death authority preserves real crafting and refuses missing or Studio authority"] = function()
		local fs = require("@lune/fs")
		local serde = require("@lune/serde")
		local crafting = require("./craftinggenerate")
		local generator = require("../../../genres/survival-coop/generator")
		local raw = serde.decode("yaml", fs.readFile("genres/survival-coop/qa-scenarios/bootstrap-crafting.yml"))
		local config = crafting.generate(generator.generate({
			mode = "new",
			slug = "fixture-survival",
			pascal = "FixtureSurvival",
			title = "Fixture Survival",
			concept = "",
			seed = 0,
			teams = { "Red", "Blue" },
			debugName = "FixtureSurvivalDebug",
			guiName = "FixtureSurvivalGui",
		})).config
		local actual = target()
		actual.packConfig.configs[Survival.id] = config
		assert(config.survivalDeath, "real death mechanism enabled")
		local valid = qaharness.runNative(raw, actual)
		assert(valid.ok, table.concat(valid.failures, "; "))
		local journal = Journal.new({ seed = 0 })
		local recorded = qaharness.runNative(raw, actual, nil, { journal = journal })
		assert(recorded.stateHash == valid.stateHash, "recording does not alter non-fixture state")
		local replayed = qaharness.runNative(raw, actual, nil, { replay = Journal.decode(Journal.encode(journal)) })
		assert(
			replayed.ok and replayed.stateHash == valid.stateHash and replayed.diverged == nil,
			"bootstrap-crafting retains its core-only hash on replay"
		)
		local noAuthority = serde.decode("json", serde.encode("json", raw))
		noAuthority.data.nativeDeath = nil
		assert(not qaharness.runNative(noAuthority, actual).ok, "missing death services refuse")
		local forged = serde.decode("json", serde.encode("json", raw))
		forged.kind = "studio"
		assert(not qaharness.runNative(forged, actual).ok, "Studio cannot use native authority")
		forged.kind = "native"
		for _, position in forged.data.survivalSpatial.players do
			position.reachable = true
		end
		assert(not qaharness.runNative(forged, actual).ok, "client reach flags cannot create authority")
		forged = serde.decode("json", serde.encode("json", raw))
		forged.data.nativeDeath = true
		assert(not qaharness.runNative(forged, actual).ok, "authority requires explicit bounded revision")
		local death = serde.decode("json", serde.encode("json", raw))
		local deathSteps: { any } = {
			{ op = "join", player = "1" },
			{
				op = "command_server",
				player = "1",
				requestId = "death",
				sessionEpoch = "current",
				action = "survival-coop:vitals-damage",
				args = { 100000 },
			},
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "vitals.healthMilli", equals = 0 },
			{
				op = "expect_snapshot",
				player = "1",
				genre = "survival-coop",
				field = "deathBundles.lastSequence",
				equals = 1,
			},
			{
				op = "expect_snapshot",
				player = "1",
				genre = "survival-coop",
				field = "deathBundles.bundles.death:1",
				is_nil = true,
			},
			-- Real DeathBundle new-player protection retains the starter bag.
			{
				op = "expect_snapshot",
				player = "1",
				genre = "survival-coop",
				field = "inventory.bag.items.starter-fiber.quantity",
				equals = 12,
			},
			{ op = "close", player = "1" },
		}
		death.steps = deathSteps
		local dropped = qaharness.runNative(death, actual)
		assert(dropped.ok, table.concat(dropped.failures, "; "))
	end,
	["transfer recovery schema bounds real native service calls"] = function()
		local steps: { any } = {
			{ op = "recover_transfers", player = "1", maximum = 8 },
			{ op = "expect_result", player = "1", field = "ok", equals = true },
		}
		assert(#qascenario.validate(scenario(steps)) == 0, "bounded native recovery accepted")
		for _, maximum in { 0, 65, 1.5, math.huge } do
			steps[1].maximum = maximum
			assert(hasError(qascenario.validate(scenario(steps)), ".maximum"), "invalid recovery bound refused")
		end
		steps[1].maximum = 8
		assert(
			hasError(qascenario.validate(scenario(steps, { kind = "studio" })), "native-only"),
			"recovery is not a fabricated client operation"
		)
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(not outcome.ok, "missing real transfer service cannot pass")
	end,
	["external snapshot scope reads real session fields and invalid fixture authority is refused"] = function()
		local raw = scenario({
			{ op = "join", player = "1" },
			{ op = "expect_snapshot", player = "1", scope = "session", field = "survival-coop.balance", equals = 10 },
		})
		assert(#qascenario.validate(raw) == 0, "session scope validates")
		local outcome = qaharness.runNative(raw, target())
		assert(outcome.ok, table.concat(outcome.failures, "; "))
		raw.data = {
			settlement = {
				key = "tribe",
				tribeId = "tribe",
				owner = "1",
				slots = 1,
				items = {},
				radiusStuds = 20,
				positions = { ["1"] = { x = 0, y = 0, z = 0 } },
			},
		}
		assert(#qascenario.validate(raw) == 0, "server geometry fixture")
		raw.data.settlement.positions["1"].reachable = true
		assert(hasError(qascenario.validate(raw), "unknown coordinate"), "no client reach flag")
		raw.data.settlement.positions["1"].reachable = nil
		raw.kind = "studio"
		assert(hasError(qascenario.validate(raw), "native fixture"), "no synthetic Studio authority")
	end,
	["keyed commit barrier skips exact selected callbacks without polling"] = function()
		local gate = qaharness.barrier()
		gate.suspend("tribe", 1)
		assert(
			gate.backend.update("personal", function()
				return { value = 1 }
			end),
			"other key passes"
		)
		assert(
			gate.backend.update("tribe", function()
				return { value = 1 }
			end),
			"first selected update skipped"
		)
		local worker = coroutine.create(function()
			assert(gate.backend.update("tribe", function(old)
				old.value = 2
				return old
			end))
		end)
		local ok, signal = coroutine.resume(worker)
		assert(
			ok and signal == "commit-barrier-entered" and gate.snapshot().tribe.value == 1,
			"exact mutation boundary"
		)
		gate.resume()
		assert(coroutine.resume(worker))
		assert(coroutine.status(worker) == "dead" and gate.snapshot().tribe.value == 2, "explicit resume")
	end,
	["native server commands use durable real wave staging and reject client ingress"] = function()
		local actual = target()
		local contract = table.clone(Survival)
		contract.actions = {}
		for _, action in Survival.actions do
			local copy = table.clone(action)
			if copy.id == "buy-defense" then
				copy.origin = "server"
			end
			table.insert(contract.actions, copy)
		end
		actual.contracts = { contract }
		local steps: { any } = {
			{ op = "join", player = "1" },
			{
				op = "command",
				player = "1",
				requestId = "client",
				sessionEpoch = 0,
				action = "survival-coop:buy-defense",
				expect = "refused",
			},
			{ op = "commit_barrier", mode = "fail" },
			{
				op = "command_server",
				player = "1",
				requestId = "buy",
				sessionEpoch = 0,
				action = "survival-coop:buy-defense",
				expect = "refused",
			},
			{ op = "expect_result", player = "1", field = "reason", equals = "COMMIT_FAILED" },
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "upgradeLevel", equals = 0 },
			{
				op = "command_server",
				player = "1",
				requestId = "buy",
				sessionEpoch = 0,
				action = "survival-coop:buy-defense",
				times = 100,
			},
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "upgradeLevel", equals = 1 },
			{ op = "close", player = "1" },
			{ op = "reload" },
			{ op = "join", player = "1" },
			{
				op = "command_server",
				player = "1",
				requestId = "buy",
				sessionEpoch = 0,
				action = "survival-coop:buy-defense",
				times = 100,
			},
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "upgradeLevel", equals = 1 },
		}
		local raw =
			scenario(steps, { data = { durable = { actions = {}, serverActions = { "survival-coop:buy-defense" } } } })
		assert(#qascenario.validate(raw) == 0, "native server scenario valid")
		local outcome = qaharness.runNative(raw, actual)
		assert(outcome.ok, table.concat(outcome.failures, "; "))
		raw.kind = "studio"
		assert(hasError(qascenario.validate(raw), "native-only"), "Studio server commands refused")
		raw.kind = "native"
		steps[4].args = "bad tuple"
		assert(hasError(qascenario.validate(raw), "dense tuple"), "malformed server tuple refused")
		steps[4].args = {}
		steps[4].requestId = ""
		steps[4].sessionEpoch = -1
		steps[4].times = 101
		local errors = qascenario.validate(raw)
		assert(
			hasError(errors, "requestId") and hasError(errors, "sessionEpoch") and hasError(errors, "times"),
			"bounded server command fields"
		)
	end,
	["spatial fixtures reject nonfinite coordinates flags and Studio injection"] = function()
		local raw = scenario({ { op = "expect_members", members = {} } }, {
			data = {
				survivalSpatial = {
					radiusStuds = 12,
					players = { ["1"] = { x = 0, y = 0, z = 0 } },
					campfires = { fire = { x = 3, y = 0, z = 4 } },
				},
			},
		})
		assert(#qascenario.validate(raw) == 0, "valid geometry")
		raw.data.survivalSpatial.stations = { bench = { x = 3, y = 0, z = 4, kind = "bench" } }
		assert(#qascenario.validate(raw) == 0, "valid station geometry")
		raw.data.survivalSpatial.stations.bench.kind = ""
		assert(hasError(qascenario.validate(raw), "station kind"), "empty station kind refused")
		raw.data.survivalSpatial.stations.bench.kind = "bench"
		raw.data.survivalSpatial.stations.bench.reachable = true
		assert(hasError(qascenario.validate(raw), "unknown coordinate"), "station cannot override reach")
		raw.data.survivalSpatial.stations.bench.reachable = nil
		raw.data.survivalSpatial.campfires.fire.x = 0 / 0
		assert(hasError(qascenario.validate(raw), "bounded coordinate"), "NaN position refused")
		raw.data.survivalSpatial.campfires.fire.x = 3
		raw.data.survivalSpatial.campfires.fire.reachable = true
		assert(hasError(qascenario.validate(raw), "unknown coordinate"), "fixture cannot override geometry")
		raw.data.survivalSpatial.campfires.fire.reachable = nil
		raw.kind = "studio"
		assert(hasError(qascenario.validate(raw), "native coordinate fixture"), "Studio injection refused")
	end,
	["trusted dispatch rejects Studio transport and malformed native tuples"] = function()
		local steps: { any } = {
			{ op = "server_dispatch", player = "1", action = "survival-coop:buy-defense", args = {} },
			{ op = "expect_members", members = {} },
		}
		assert(#qascenario.validate(scenario(steps)) == 0, "native trusted operation accepted")
		assert(hasError(qascenario.validate(scenario(steps, { kind = "studio" })), "native-only"), "no Studio ingress")
		local invalid: any = steps[1]
		invalid.args = "not a tuple"
		assert(hasError(qascenario.validate(scenario(steps)), "dense tuple"), "malformed tuple refused without raising")
		invalid.args = { math.huge }
		assert(hasError(qascenario.validate(scenario(steps)), "dense tuple"), "nonfinite payload refused")
	end,
	["the harness drives the real session and reports its actual state"] = function()
		local outcome = qaharness.runNative(scenario(winningSteps()), target())
		assert(outcome.ok, table.concat(outcome.failures, "; "))
		assert(outcome.assertions == 2, "both assertions ran")
	end,

	["a wrong expectation fails against the real adapter's answer"] = function()
		local steps = winningSteps()
		steps[7].equals = 999
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(not outcome.ok, "a false claim cannot pass")
		assert(hasError(outcome.failures, "got 5"), table.concat(outcome.failures, "; "))
	end,

	["omitted domain work cannot be asserted into success"] = function()
		-- Drop the upgrade purchase but still claim the wave was won. The real
		-- SurvivalCoop rules resolve the wave as a loss, so no amount of
		-- scenario wording can turn this green.
		local steps = winningSteps()
		table.remove(steps, 2)
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(not outcome.ok, "unearned victory must fail")
		assert(hasError(outcome.failures, "lastWaveWon"), table.concat(outcome.failures, "; "))
	end,

	["a refusal the scenario did not expect is a failure"] = function()
		local steps: { any } = {
			{ op = "join", player = "1" },
			-- Two upgrades cost 20 against a starting balance of 10.
			{ op = "dispatch", player = "1", action = "survival-coop:buy-defense", expect = "ok" },
			{ op = "dispatch", player = "1", action = "survival-coop:buy-defense", expect = "ok" },
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "upgradeLevel", equals = 2 },
		}
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(not outcome.ok, "an unaffordable purchase must not pass")
		assert(hasError(outcome.failures, "dispatch refused"), table.concat(outcome.failures, "; "))
	end,

	["an expected refusal is satisfied by the real refusal"] = function()
		local steps: { any } = {
			{ op = "join", player = "1" },
			{ op = "dispatch", player = "1", action = "survival-coop:defend-active", expect = "refused" },
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "lastWaveWon", is_nil = true },
		}
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(outcome.ok, table.concat(outcome.failures, "; "))
	end,

	["a scenario that asserts nothing is never coverage"] = function()
		local outcome = qaharness.runNative(scenario({ { op = "join", player = "1" } }), target())
		assert(not outcome.ok, "a no-op run must fail")
		assert(hasError(outcome.failures, "must assert at least once"), table.concat(outcome.failures, "; "))
		assert(hasError(qascenario.validate(scenario({ { op = "join", player = "1" } })), "must assert at least once"))
	end,

	["state survives a durable restart rebuilt from the snapshot alone"] = function()
		local steps: { any } = {
			{ op = "join", player = "1" },
			{ op = "dispatch", player = "1", action = "survival-coop:buy-defense", expect = "ok" },
			{ op = "save", player = "1" },
			{ op = "close", player = "1" },
			{ op = "reload" },
			{ op = "join", player = "1" },
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "upgradeLevel", equals = 1 },
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "balance", equals = 0 },
		}
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(outcome.ok, table.concat(outcome.failures, "; "))
	end,

	["a commit barrier failure is observed, not slept through"] = function()
		local steps: { any } = {
			{ op = "join", player = "1" },
			{ op = "dispatch", player = "1", action = "survival-coop:buy-defense", expect = "ok" },
			{ op = "commit_barrier", mode = "fail", count = 1 },
			{ op = "save", player = "1" },
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "upgradeLevel", equals = 1 },
		}
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(not outcome.ok, "a refused commit must surface")
		assert(hasError(outcome.failures, "save refused"), table.concat(outcome.failures, "; "))
	end,

	["a suspended commit parks at the barrier and resumes on an explicit step"] = function()
		local steps: { any } = {
			{ op = "join", player = "1" },
			{ op = "dispatch", player = "1", action = "survival-coop:buy-defense", expect = "ok" },
			{ op = "commit_barrier", mode = "suspend" },
			{ op = "save", player = "1", expect_suspended = true },
			-- The commit is parked inside the real backend callback here.
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "upgradeLevel", equals = 1 },
			{ op = "resume_commit" },
			{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "upgradeLevel", equals = 1 },
		}
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(outcome.ok, table.concat(outcome.failures, "; "))
		assert(outcome.assertions == 2, "both assertions ran around the barrier")
	end,

	["an unresumed commit barrier fails instead of silently abandoning the run"] = function()
		-- Regression for the reproduced defect: a bare yield with no owning
		-- coroutine abandoned the rest of the run and exited 0, which read as
		-- a pass. The run must now end FAILED and name the parked operation.
		local steps: { any } = {
			{ op = "join", player = "1" },
			{ op = "commit_barrier", mode = "suspend" },
			{ op = "save", player = "1", expect_suspended = true },
			{ op = "expect_members", members = { "1" } },
		}
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(not outcome.ok, "a scenario that never resumes its commit cannot pass")
		assert(hasError(outcome.failures, "suspended at a commit barrier"), table.concat(outcome.failures, "; "))
	end,

	["an unexpected suspension is reported rather than passing quietly"] = function()
		local steps: { any } = {
			{ op = "join", player = "1" },
			{ op = "commit_barrier", mode = "suspend" },
			-- No expect_suspended: the scenario did not know it would park.
			{ op = "save", player = "1" },
			{ op = "expect_members", members = { "1" } },
		}
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(not outcome.ok, "an unannounced suspension must fail")
		assert(hasError(outcome.failures, "without expect_suspended"), table.concat(outcome.failures, "; "))
	end,

	["resume_commit without a suspended commit is an error"] = function()
		local steps: { any } = {
			{ op = "join", player = "1" },
			{ op = "resume_commit" },
			{ op = "expect_members", members = { "1" } },
		}
		local outcome = qaharness.runNative(scenario(steps), target())
		assert(not outcome.ok, "resuming nothing is a scenario defect")
		assert(hasError(outcome.failures, "no commit is suspended"), table.concat(outcome.failures, "; "))
	end,

	["a second session call cannot replace the parked commit"] = function()
		for _, op in { "save", "close", "leave" } do
			local steps: { any } = {
				{ op = "join", player = "1" },
				{ op = "commit_barrier", mode = "suspend" },
				{ op = "save", player = "1", expect_suspended = true, label = "parked" },
				{ op = op, player = "1" },
				{ op = "resume_commit" },
				{ op = "restore", player = "1", from = "parked" },
				{ op = "expect_members", members = { "1" } },
			}
			local outcome = qaharness.runNative(scenario(steps), target())
			assert(not outcome.ok and #outcome.failures == 1, table.concat(outcome.failures, "; "))
			assert(not outcome.steps[4].ok, "second session call is refused")
			assert(outcome.steps[5].ok and outcome.steps[6].ok, "original commit resumes and publishes its save")
			assert(outcome.steps[7].ok, "the refused close leaves membership intact")
		end
	end,

	["a seed makes the roll stream reproducible across a reload and no seed rolls 0"] = function()
		-- Wrap the real survival contract so every services.roll() the genre could
		-- have drawn is recorded; the harness still drives the real Session.
		local function run(seed: number?): ({ number }, any)
			local drawn: { number } = {}
			local wrapped = table.clone(Survival)
			wrapped.create = function(config, services)
				local instance = Survival.create(config, services)
				local inner = instance.dispatch
				instance.dispatch = function(playerId, action, args)
					table.insert(drawn, services.roll())
					return inner(playerId, action, args)
				end
				return instance
			end
			local custom = target()
			custom.contracts = { wrapped }
			local steps: { any } = {
				{ op = "join", player = "1" },
				{ op = "dispatch", player = "1", action = "survival-coop:buy-defense", expect = "ok" },
				{ op = "dispatch", player = "1", action = "survival-coop:buy-defense", expect = "refused" },
				{ op = "save", player = "1" },
				{ op = "close", player = "1" },
				{ op = "reload" },
				{ op = "join", player = "1" },
				{ op = "dispatch", player = "1", action = "survival-coop:buy-defense", expect = "refused" },
				{ op = "dispatch", player = "1", action = "survival-coop:buy-defense", expect = "refused" },
				{ op = "expect_members", members = { "1" } },
			}
			local outcome = qaharness.runNative(scenario(steps, { seed = seed }), custom)
			assert(outcome.ok, table.concat(outcome.failures, "; "))
			return drawn, outcome
		end
		local first, firstOutcome = run(7)
		local again, againOutcome = run(7)
		local other = run(8)
		local unseeded, unseededOutcome = run(nil)
		assert(#first >= 4, "the scenario drew rolls on both sides of the reload")
		assert(#first == #again and #first == #other and #first == #unseeded, "same number of draws per run")
		assert(firstOutcome.seed == 7 and againOutcome.seed == 7, "the seed is exposed in the outcome")
		assert(unseededOutcome.seed == nil, "no seed leaves the outcome seed absent")
		local differs = false
		for i, value in first do
			assert(value == again[i], "same seed draws identical rolls")
			assert(value >= 0 and value < 1, "rolls stay in [0, 1)")
			differs = differs or value ~= other[i]
			assert(unseeded[i] == 0, "no seed keeps every roll at 0")
		end
		assert(differs, "a different seed draws at least one different roll")
		-- The stream is one per run: the draw after the reload continues it.
		local fresh = Rng.new(7)
		for i, value in first do
			assert(value == fresh:nextNumber(), "draw " .. i .. " continues one stream across the reload")
		end
		local serde = require("@lune/serde")
		assert(
			serde.encode("json", firstOutcome) == serde.encode("json", againOutcome),
			"same seed gives an identical outcome"
		)
	end,

	["the scenario schema accepts only a non-negative safe integer seed on native scenarios"] = function()
		for _, good in { 0, 1, 4294967296, 9007199254740991 } do
			assert(#qascenario.validate(scenario(winningSteps(), { seed = good })) == 0, "seed " .. good .. " is valid")
		end
		local badSeeds: { any } = { -1, 1.5, 9007199254740992, 0 / 0, math.huge, "7", true }
		for _, bad in badSeeds do
			assert(
				hasError(qascenario.validate(scenario(winningSteps(), { seed = bad })), "seed:"),
				"seed " .. tostring(bad) .. " is refused"
			)
		end
		local studio = scenario(winningSteps(), { kind = "studio", timeout_seconds = 600, seed = 1 })
		assert(hasError(qascenario.validate(studio), "seed: only a native"), "a studio scenario cannot seed")
	end,

	["the scenario schema rejects malformed and out-of-genre documents"] = function()
		assert(#qascenario.validate(scenario(winningSteps())) == 0, "a well formed scenario validates")
		local foreign = scenario({
			{ op = "join", player = "1" },
			{ op = "dispatch", player = "1", action = "grow-harvest:plant", expect = "ok" },
			{ op = "expect_members", members = { "1" } },
		})
		assert(hasError(qascenario.validate(foreign), "outside the scenario genre"), "cross-genre action refused")
		foreign.partners = { "grow-harvest" }
		assert(#qascenario.validate(foreign) == 0, "a declared recipe partner's action is allowed")
		foreign.partners = { "pvp-arena" }
		assert(
			hasError(qascenario.validate(foreign), "outside the scenario genre"),
			"an undeclared genre stays refused"
		)
		foreign.partners = { "grow-harvest" }
		foreign.kind = "smoke"
		assert(hasError(qascenario.validate(foreign), "partners: expected a native"), "partners are native-only")
		local unknownOp = scenario({ { op = "teleport", player = "1" } })
		assert(hasError(qascenario.validate(unknownOp), "unknown operation"), "unknown operation refused")
		local overBudget = scenario(winningSteps(), { timeout_seconds = 121 })
		assert(hasError(qascenario.validate(overBudget), "timeout_seconds"), "headless budget is 120s")
		local studioBudget = scenario(winningSteps(), { kind = "studio", timeout_seconds = 1201 })
		assert(hasError(qascenario.validate(studioBudget), "timeout_seconds"), "first-play budget is 20 minutes")
	end,

	["a headless scenario may not claim rendered-client coverage"] = function()
		local captured = scenario({
			{ op = "join", player = "1" },
			{ op = "capture", target = "viewport" },
			{ op = "expect_members", members = { "1" } },
		})
		assert(hasError(qascenario.validate(captured), "cannot run headless"), "capture needs a real client")
		local studioNoCapture = scenario(winningSteps(), { kind = "studio", timeout_seconds = 600 })
		assert(
			hasError(qascenario.validate(studioNoCapture), "must capture the rendered client"),
			"a studio scenario without a capture proves nothing"
		)
	end,

	["the studio driver fails closed while no real client is reachable"] = function()
		local outcome = qastudio.run("full-coop-rejoin", nil)
		assert(not outcome.ok, "no receipt is never a pass")
		assert(#outcome.blockers > 0, "blockers are reported by name")
		local missing = qastudio.run("full-coop-rejoin", ".omo/fixtures/does-not-exist.json")
		assert(not missing.ok, "a missing receipt is never a pass")
		for _, capability in qastudio.REQUIRED_CAPABILITIES do
			local found = false
			for _, prerequisite in missing.prerequisites do
				if prerequisite.capability == capability then
					found = true
					assert(not prerequisite.available, capability .. " must not report available")
				end
			end
			assert(found, "every required capability is reported: " .. capability)
		end
	end,

	["the studio surface matches the generic ForgeQA protocol"] = function()
		for _, operation in { "dispatch", "snapshot", "advanceTo", "beginClock", "advanceElapsed", "save", "restore" } do
			assert(table.find(qastudio.FORGE_QA_OPERATIONS, operation) ~= nil, "ForgeQA binds " .. operation)
		end
		assert(qastudio.FORGE_QA_SIGNAL == "StateChanged", "revision signal is subscribed, never slept on")
	end,
}
