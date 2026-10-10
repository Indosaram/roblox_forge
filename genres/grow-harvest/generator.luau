--!strict
local Types = require("../../cli/forge/lib/genrecontract")
local Executor = require("../../core/domain/genre/Executor")
local Runtime = require("./module/Contract")
local Fixture = require("./module/Adapter.fixture")
local function dispatch(executor: Executor.Executor, player: string, action: string, args: { any }): boolean
	return executor.dispatchClient(player, "grow-harvest:" .. action, args).ok
end
local function run(executor: Executor.Executor, _input: Types.GenerateInput): { Types.Check }
	local player = "grow-proof"
	assert(executor.join(player).ok, "expected executor.join(player).ok")
	local start = executor.snapshot(player)["grow-harvest"].balance
	local bought = dispatch(executor, player, "buy-seed", { "carrot" })
	local planted = dispatch(executor, player, "plant", { 1, "carrot" })
	local readyAt = executor.snapshot(player)["grow-harvest"].plots[1].readyAt
	local early = not dispatch(executor, player, "harvest", { 1 })
	executor.advance(readyAt)
	local harvested = dispatch(executor, player, "harvest", { 1 })
	local held = executor.snapshot(player)["grow-harvest"].inventory.carrot == 1
	local sold = dispatch(executor, player, "sell-held", { "carrot" })
	local repeated = not dispatch(executor, player, "sell-held", { "carrot" })
	local save = executor.save(player)
	executor.leave(player)
	local restored = executor.join(player, save).ok
	local state = executor.snapshot(player)["grow-harvest"]
	return {
		{
			name = "native farming ledger",
			ok = bought
				and planted
				and early
				and harvested
				and held
				and sold
				and repeated
				and state.balance == start + 9
				and state.inventory.carrot == 0,
		},
		{ name = "farming rejoin", ok = restored and state.seeds.carrot == 1 and state.plots[1].cropId == nil },
	}
end
local function simulate(
	executor: Executor.Executor,
	_input: Types.GenerateInput,
	playerCount: number,
	days: number
): Types.SimMetrics
	local metrics: Types.SimMetrics =
		{ balances = {}, sourceTotal = 0, sinkTotal = 0, acceptedActions = 0, rejectedActions = 0 }
	for i = 1, playerCount do
		assert(executor.join("grow-sim-" .. i).ok, 'expected executor.join("grow-sim-" .. i).ok')
	end
	local epoch = 0
	for _day = 1, days do
		for i = 1, playerCount do
			local player = "grow-sim-" .. i
			local before = executor.snapshot(player)["grow-harvest"].balance
			local planting: { { action: string, args: { any } } } =
				{ { action = "buy-seed", args = { "carrot" } }, { action = "plant", args = { 1, "carrot" } } }
			for _, intent in planting do
				if dispatch(executor, player, intent.action, intent.args) then
					metrics.acceptedActions += 1
				else
					metrics.rejectedActions += 1
				end
			end
			local state = executor.snapshot(player)["grow-harvest"]
			metrics.sinkTotal += before - state.balance
			epoch = math.max(epoch, state.plots[1].readyAt or epoch)
		end
		executor.advance(epoch)
		for i = 1, playerCount do
			local player = "grow-sim-" .. i
			local before = executor.snapshot(player)["grow-harvest"].balance
			local selling: { { action: string, args: { any } } } =
				{ { action = "harvest", args = { 1 } }, { action = "sell-held", args = { "carrot" } } }
			for _, intent in selling do
				if dispatch(executor, player, intent.action, intent.args) then
					metrics.acceptedActions += 1
				else
					metrics.rejectedActions += 1
				end
			end
			metrics.sourceTotal += executor.snapshot(player)["grow-harvest"].balance - before
		end
	end
	for i = 1, playerCount do
		local player = "grow-sim-" .. i
		metrics.balances[player] = executor.snapshot(player)["grow-harvest"].balance
	end
	return metrics
end
local generator: Types.Generator = {
	api = 1,
	id = "grow-harvest",
	configVersion = 1,
	runtime = Runtime,
	generate = function(input)
		return {
			config = Fixture.config(),
			controls = {
				{
					id = "grow-harvest:seed-shop",
					action = "grow-harvest:buy-seed",
					args = { "carrot" },
					label = "Buy carrot seed",
					kind = "prompt",
				},
				{
					id = "grow-harvest:plant",
					action = "grow-harvest:plant",
					args = { 1, "carrot" },
					label = "Plant carrot",
					kind = "prompt",
				},
				{
					id = "grow-harvest:harvest",
					action = "grow-harvest:harvest",
					args = { 1 },
					label = "Harvest carrot",
					kind = "button",
				},
				{
					id = "grow-harvest:sell",
					action = "grow-harvest:sell-held",
					args = { "carrot" },
					label = "Sell carrot",
					kind = "button",
				},
			},
			assetKeys = {
				"grow-harvest-starter-prop",
				"grow-harvest-buy",
				"grow-harvest-plant",
				"grow-harvest-harvest",
				"grow-harvest-sell",
			},
			generation = { "procedural", "audio" },
			artifacts = {
				{
					path = "design/grow-harvest/overview.md",
					content = [[# Grow and harvest

Plant seeds, harvest ready carrots, and sell held crops.
]],
				},
				{
					path = "assets/grow-harvest/procgen.yml",
					content = [[assets:
  - key: grow-harvest-starter-prop
    kind: prop
    archetype: crate
    scale: 1
    body: [120, 80, 40]
    accent: [80, 190, 80]
    seed: ]] .. tostring(input.seed) .. string.char(10),
				},
				{
					path = "assets/grow-harvest/audio.yml",
					-- One cue per bound action, so the derived audio policy binds each
					-- committed action to its own sound instead of sharing one cue.
					content = string.format(
						"cues:\n  - key: grow-harvest-buy\n    kind: sfx\n    type: coin\n    duration: 0.2\n    seed: %d\n"
							.. "  - key: grow-harvest-plant\n    kind: sfx\n    type: click\n    duration: 0.15\n    seed: %d\n"
							.. "  - key: grow-harvest-harvest\n    kind: sfx\n    type: coin\n    duration: 0.25\n    seed: %d\n"
							.. "  - key: grow-harvest-sell\n    kind: sfx\n    type: coin\n    duration: 0.3\n    seed: %d\n",
						input.seed,
						input.seed + 1,
						input.seed + 2,
						input.seed + 3
					),
				},
			},
		}
	end,
	driver = { run = run, simulate = simulate },
	qa = {
		scenarios = { "contract-loop", "contract-rejoin" },
		operations = { "dispatch", "snapshot", "advanceTo", "beginClock", "advanceElapsed", "save", "restore" },
		targets = { "grow-harvest:seed-shop", "grow-harvest:plant", "grow-harvest:harvest", "grow-harvest:sell" },
	},
}
return generator
