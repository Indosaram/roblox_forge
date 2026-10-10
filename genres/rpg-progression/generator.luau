--!strict
local Package = require("../../cli/forge/lib/genrecontract")
local Executor = require("../../core/domain/genre/Executor")
local Runtime = require("./module/Contract")
local Fixture = require("./module/Adapter.fixture")
local ID = "rpg-progression"
local function state(executor: Executor.Executor, playerId: string): any
	return executor.snapshot(playerId)[ID]
end
local function run(executor: Executor.Executor, _input: Package.GenerateInput): { Package.Check }
	local playerId = "rpg-proof"
	assert(executor.join(playerId, nil).ok, "RPG invariant: 12")
	executor.advance(0)
	executor.advance(2)
	local spawned = state(executor, playerId).activeBosses.slime == 2
		and state(executor, playerId).activeBosses.golem == nil
	local locked = not executor.dispatchClient(playerId, ID .. ":strike-boss", { "golem" }).ok
	assert(executor.dispatchClient(playerId, ID .. ":strike-boss", { "slime" }).ok, "RPG invariant: 18")
	local damaged = state(executor, playerId).activeBosses.slime == 1
	local cooldown = not executor.dispatchClient(playerId, ID .. ":strike-boss", { "slime" }).ok
	executor.advance(3)
	assert(executor.dispatchClient(playerId, ID .. ":strike-boss", { "slime" }).ok, "RPG invariant: 22")
	local leveled = state(executor, playerId).level == 2 and state(executor, playerId).points == 1
	assert(executor.dispatchClient(playerId, ID .. ":claim-quest", { "first-boss" }).ok, "RPG invariant: 24")
	local claimed = state(executor, playerId).balance == 5
	local once = not executor.dispatchClient(playerId, ID .. ":claim-quest", { "first-boss" }).ok
	executor.advance(4)
	executor.advance(6)
	local ridge = state(executor, playerId).activeBosses.golem == 4
	local save = executor.save(playerId)
	executor.leave(playerId)
	assert(executor.join(playerId, save).ok, "RPG invariant: 32")
	local restored = state(executor, playerId).balance == 5
		and state(executor, playerId).level == 2
		and next(state(executor, playerId).activeBosses) == nil
	local noReplay = not executor.dispatchClient(playerId, ID .. ":claim-quest", { "first-boss" }).ok
	executor.leave(playerId)
	return {
		{ name = "native spawn and locked region", ok = spawned and locked },
		{ name = "configured damage and authoritative cooldown", ok = damaged and cooldown },
		{ name = "native defeat XP and ridge unlock", ok = leveled and ridge },
		{ name = "native quest reward once", ok = claimed and once },
		{ name = "validated rejoin with ephemeral bosses", ok = restored and noReplay },
	}
end
local function simulate(
	executor: Executor.Executor,
	_input: Package.GenerateInput,
	count: number,
	days: number
): Package.SimMetrics
	assert(
		count >= 1 and count <= 64 and count % 1 == 0 and days >= 1 and days <= 365 and days % 1 == 0,
		"invalid simulation bounds"
	)
	local balances: { [string]: number } = {}
	local accepted, rejected = 0, 0
	local function action(playerId: string, name: string, args: { any })
		if executor.dispatchClient(playerId, ID .. ":" .. name, args).ok then
			accepted += 1
		else
			rejected += 1
		end
	end
	for index = 1, count do
		assert(executor.join("rpg-sim-" .. tostring(index), nil).ok, "RPG invariant: 66")
	end
	executor.advance(0)
	for day = 1, days do
		local start = (day - 1) * 4 + 2
		executor.advance(start)
		for index = 1, count do
			action("rpg-sim-" .. tostring(index), "strike-boss", { "slime" })
		end
		executor.advance(start + 1)
		for index = 1, count do
			local playerId = "rpg-sim-" .. tostring(index)
			action(playerId, "strike-boss", { "slime" })
			action(playerId, "claim-quest", { "first-boss" })
		end
	end
	local total = 0
	for index = 1, count do
		local playerId = "rpg-sim-" .. tostring(index)
		balances[playerId] = state(executor, playerId).balance
		total += balances[playerId]
		executor.leave(playerId)
	end
	return {
		balances = balances,
		sourceTotal = total,
		sinkTotal = 0,
		acceptedActions = accepted,
		rejectedActions = rejected,
	}
end
local generator: Package.Generator = {
	api = 1,
	id = ID,
	configVersion = 1,
	runtime = Runtime,
	generate = function(input)
		return {
			config = Executor.clone(Fixture),
			controls = {
				{
					id = "strike-slime",
					action = ID .. ":strike-boss",
					args = { "slime" },
					label = "Strike meadow slime",
					kind = "button",
				},
				{
					id = "strike-golem",
					action = ID .. ":strike-boss",
					args = { "golem" },
					label = "Strike ridge golem",
					kind = "button",
				},
				{
					id = "claim-first-boss",
					action = ID .. ":claim-quest",
					args = { "first-boss" },
					label = "Claim first boss quest",
					kind = "button",
				},
			},
			assetKeys = { ID .. "-starter-prop", ID .. "-strike", ID .. "-claim" },
			generation = { "procedural", "audio" },
			artifacts = {
				{
					path = "assets/" .. ID .. "/procgen.yml",
					content = string.format(
						"assets:\n  - key: rpg-progression-starter-prop\n    kind: prop\n    archetype: crystal\n    scale: 1\n    body: [90, 150, 190]\n    accent: [180, 230, 110]\n    seed: %d\n",
						input.seed
					),
				},
				{
					path = "assets/" .. ID .. "/audio.yml",
					content = string.format(
						"cues:\n  - key: rpg-progression-strike\n    kind: sfx\n    type: raid\n    duration: 0.2\n    seed: %d\n"
							.. "  - key: rpg-progression-claim\n    kind: sfx\n    type: coin\n    duration: 0.3\n    seed: %d\n",
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
		targets = { ID .. ":strike-slime", ID .. ":strike-golem", ID .. ":claim-first-boss" },
	},
}
return generator
