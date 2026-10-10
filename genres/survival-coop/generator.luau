--!strict
local Types = require("../../cli/forge/lib/genrecontract")
local Runtime = require("./module/Contract")
local Fixture = require("./module/Adapter.fixture")
local Recipe = require("./recipe-generator")
assert(Runtime.recipe, "survival recipe required")
local Generator: Types.Generator = {
	api = 1,
	id = "survival-coop",
	configVersion = 1,
	runtime = Runtime,
	recipes = { [Runtime.recipe.id] = Recipe },
	qa = {
		scenarios = { "contract-loop", "contract-rejoin" },
		operations = { "dispatch", "snapshot", "advanceTo", "beginClock", "advanceElapsed", "save", "restore" },
		targets = { "survival-coop:buy-defense", "survival-coop:defend-active" },
	},
	generate = function(input)
		return {
			config = table.clone(Fixture.config) :: any,
			controls = {
				{
					id = "survival-coop:buy-defense",
					action = "survival-coop:buy-defense",
					args = {},
					label = "Buy defense",
					kind = "prompt",
				},
				{
					id = "survival-coop:defend-active",
					action = "survival-coop:defend-active",
					args = {},
					label = "Defend active wave",
					kind = "button",
				},
			},
			assetKeys = { "survival-coop-starter-prop", "survival-coop-action" },
			generation = { "procedural", "audio" },
			artifacts = {
				{
					path = "design/survival-coop/loop.md",
					content = "# Camp defense\nBuy defense, then defend the current server wave. Wins reward every eligible participant once.\n",
				},
				{
					path = "assets/survival-coop/procgen.yml",
					content = string.format(
						"assets:\n  - key: survival-coop-starter-prop\n    kind: prop\n    archetype: rock\n    scale: 1\n    body: [100, 110, 120]\n    accent: [180, 200, 220]\n    seed: %d\n",
						input.seed
					),
				},
				{
					path = "assets/survival-coop/audio.yml",
					content = string.format(
						"cues:\n  - key: survival-coop-action\n    kind: sfx\n    type: raid\n    duration: 0.3\n    seed: %d\n",
						input.seed
					),
				},
			},
		}
	end,
	driver = {
		run = function(executor, _input)
			local id = "survival-proof"
			local checks: { Types.Check } = {}
			local function check(name: string, ok: boolean)
				table.insert(checks, { name = name, ok = ok })
			end
			check("join", executor.join(id, nil).ok)
			check("upgrade", executor.dispatchClient(id, "survival-coop:buy-defense", {}).ok)
			executor.advance(0)
			executor.advance(2)
			check("native wave win", executor.dispatchClient(id, "survival-coop:defend-active", {}).ok)
			local state = executor.snapshot(id)["survival-coop"]
			check("reward ledger", state.lastWaveWon == true and state.balance == 5 and state.upgradeLevel == 1)
			check("duplicate blocked", not executor.dispatchClient(id, "survival-coop:defend-active", {}).ok)
			local save = executor.save(id)
			executor.leave(id)
			check("rejoin", executor.join(id, save).ok)
			check("no rejoin reward", executor.snapshot(id)["survival-coop"].balance == 5)
			return checks
		end,
		simulate = function(executor, _input, playerCount, dayCount)
			local metrics: Types.SimMetrics =
				{ balances = {}, sourceTotal = 0, sinkTotal = 0, acceptedActions = 0, rejectedActions = 0 }
			local function action(id: string, name: string)
				local before = executor.snapshot(id)["survival-coop"].balance
				local result = executor.dispatchClient(id, "survival-coop:" .. name, {})
				if result.ok then
					metrics.acceptedActions += 1
				else
					metrics.rejectedActions += 1
				end
				local after = executor.snapshot(id)["survival-coop"].balance
				metrics.sinkTotal += math.max(0, before - after)
			end
			for index = 1, playerCount do
				assert(executor.join(tostring(index), nil).ok, "check: executor.join(tostring(index), nil).ok")
			end
			executor.advance(0)
			for day = 1, dayCount do
				executor.advance(day * Fixture.config.waveInterval)
				for index = 1, playerCount do
					action(tostring(index), "buy-defense")
				end
				local before = 0
				for index = 1, playerCount do
					before += executor.snapshot(tostring(index))["survival-coop"].balance
				end
				action("1", "defend-active")
				local after = 0
				for index = 1, playerCount do
					after += executor.snapshot(tostring(index))["survival-coop"].balance
				end
				metrics.sourceTotal += math.max(0, after - before)
			end
			for index = 1, playerCount do
				metrics.balances[tostring(index)] = executor.snapshot(tostring(index))["survival-coop"].balance
			end
			return metrics
		end,
	},
}
return Generator
