--!strict
local Package = require("../../cli/forge/lib/genrecontract")
local Executor = require("../../core/domain/genre/Executor")
local Runtime = require("./module/Contract")
local Fixture = require("./module/Adapter.fixture")
local Recipe = require("./recipe-generator")
assert(Runtime.recipe, "arena recipe required")
local function state(executor: Executor.Executor, id: string): any
	return executor.snapshot(id)["pvp-arena"]
end
local function run(executor: Executor.Executor, _input: Package.GenerateInput): { Package.Check }
	local a, b = "pvp-proof-a", "pvp-proof-b"
	assert(executor.join(a, nil).ok and executor.join(b, nil).ok, "generator.luau: invariant failed")
	assert(executor.dispatchClient(a, "pvp-arena:enqueue", {}).ok, "generator.luau: invariant failed")
	assert(executor.dispatchClient(b, "pvp-arena:enqueue", {}).ok, "generator.luau: invariant failed")
	local paired = state(executor, a).rival == b and state(executor, b).rival == a
	local blocked = not executor.dispatchClient(a, "pvp-arena:attack", { b, 999 }).ok
	executor.advance(1)
	local started = state(executor, a).phase == "active"
	executor.leave(b)
	local saved = executor.save(a)
	local won = state(executor, a).rating == 1016
	executor.advance(10)
	local once = state(executor, a).rating == 1016
	executor.leave(a)
	return {
		{ name = "native pairing", ok = paired },
		{ name = "reject forged damage and rival", ok = blocked },
		{ name = "native Round countdown", ok = started },
		{ name = "native Rank forfeit once", ok = won and once },
		{
			name = "rating-only persistence",
			ok = saved.genres["pvp-arena"].data.rating == 1016 and saved.genres["pvp-arena"].data.matchId == nil,
		},
	}
end
local function simulate(
	executor: Executor.Executor,
	_input: Package.GenerateInput,
	count: number,
	_days: number
): Package.SimMetrics
	local balances: { [string]: number } = {}
	local accepted, rejected = 0, 0
	for index = 1, count do
		local id = "pvp-sim-" .. tostring(index)
		assert(executor.join(id, nil).ok, "generator.luau: invariant failed")
		if executor.dispatchClient(id, "pvp-arena:enqueue", {}).ok then
			accepted += 1
		else
			rejected += 1
		end
	end
	executor.advance(1)
	executor.advance(5)
	for index = 1, count do
		local id = "pvp-sim-" .. tostring(index)
		balances[id] = state(executor, id).rating
		executor.leave(id)
	end
	return {
		balances = balances,
		sourceTotal = 0,
		sinkTotal = 0,
		acceptedActions = accepted,
		rejectedActions = rejected,
	}
end
local generator: Package.Generator = {
	api = 1,
	id = "pvp-arena",
	configVersion = 1,
	runtime = Runtime,
	recipes = { [Runtime.recipe.id] = Recipe },
	generate = function(input)
		return {
			config = {
				Round = table.clone(Fixture.Round),
				maxDelta = Fixture.maxDelta,
				initialRating = Fixture.initialRating,
				k = Fixture.k,
				startingHealth = Fixture.startingHealth,
				attackDamage = Fixture.attackDamage,
				attackCooldown = Fixture.attackCooldown,
			},
			controls = {
				{ id = "queue", action = "pvp-arena:enqueue", args = {}, label = "Join arena queue", kind = "button" },
				{ id = "attack", action = "pvp-arena:attack", args = {}, label = "Attack rival", kind = "button" },
			},
			assetKeys = { "pvp-arena-starter-prop", "pvp-arena-queue", "pvp-arena-attack" },
			generation = { "procedural", "audio" },
			artifacts = {
				{
					path = "assets/pvp-arena/procgen.yml",
					content = string.format(
						"assets:\n  - key: pvp-arena-starter-prop\n    kind: prop\n    archetype: rock\n    scale: 1\n    body: [80, 90, 110]\n    accent: [220, 80, 60]\n    seed: %d\n",
						input.seed
					),
				},
				{
					path = "assets/pvp-arena/audio.yml",
					content = string.format(
						"cues:\n  - key: pvp-arena-queue\n    kind: sfx\n    type: click\n    duration: 0.15\n    seed: %d\n"
							.. "  - key: pvp-arena-attack\n    kind: sfx\n    type: raid\n    duration: 0.2\n    seed: %d\n",
						input.seed,
						input.seed + 1
					),
				},
			},
		}
	end,
	driver = { run = run, simulate = simulate },
	qa = {
		scenarios = { "contract-loop", "contract-rejoin" },
		operations = { "dispatch", "snapshot", "advanceTo", "beginClock", "advanceElapsed", "save", "restore" },
		targets = { "pvp-arena:queue", "pvp-arena:attack" },
	},
}
return generator
