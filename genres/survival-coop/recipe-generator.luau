--!strict
local Types = require("../../cli/forge/lib/genrecontract")
local Executor = require("../../core/domain/genre/Executor")
local Garden = require("./module/GardenDefense")
local M = {}
function M.normalize(configs: { [string]: any }): { [string]: any }
	local result = Executor.clone(configs)
	for _, id in Garden.recipe.partners do
		result[id].startingBalance = 0
	end
	return result
end
local function action(executor: Executor.Executor, player: string, id: string, args: { any }, expected: boolean)
	local result = executor.dispatchClient(player, id, args)
	assert(result.ok == expected, id .. ": " .. tostring(result.reason))
end
local function run(executor: Executor.Executor, _input: Types.GenerateInput): { Types.Check }
	local player = "garden-proof"
	assert(executor.join(player).ok, "garden join")
	executor.advance(0)
	executor.advance(2)
	action(executor, player, "survival-coop:defend-active", {}, true)
	assert(executor.snapshot(player)["survival-coop"].lastWaveWon == false, "unfunded baseline must lose")
	action(executor, player, "grow-harvest:plant", { 1, "carrot" }, true)
	executor.advance(4)
	action(executor, player, "grow-harvest:harvest", { 1 }, true)
	action(executor, player, "grow-harvest:sell-held", { "carrot" }, true)
	action(executor, player, "grow-harvest:sell-held", { "carrot" }, false)
	action(executor, player, "survival-coop:buy-defense", {}, true)
	action(executor, player, "survival-coop:buy-defense", {}, false)
	action(executor, player, "survival-coop:defend-active", {}, true)
	action(executor, player, "survival-coop:defend-active", {}, false)
	local state = executor.snapshot(player)
	assert(
		state["grow-harvest"].balance == 5
			and state["grow-harvest"].inventory.carrot == 0
			and state["survival-coop"].lastWaveWon == true,
		"sale-funded upgrade must win with one reward"
	)
	local saved = executor.save(player)
	assert(saved.genres["survival-coop"].data.balance == nil, "composition duplicated currency save")
	executor.leave(player)
	assert(executor.join(player, saved).ok, "garden restore")
	state = executor.snapshot(player)
	return {
		{
			name = "baseline loss then sale-funded upgraded win",
			ok = state["grow-harvest"].balance == 5 and state["survival-coop"].upgradeLevel == 1,
		},
		{ name = "one wallet survives rejoin", ok = saved.genres["grow-harvest"].data.balance == 5 },
	}
end
local function simulate(
	executor: Executor.Executor,
	_input: Types.GenerateInput,
	players: number,
	days: number
): Types.SimMetrics
	local metrics: Types.SimMetrics =
		{ balances = {}, sourceTotal = 0, sinkTotal = 0, acceptedActions = 0, rejectedActions = 0 }
	for i = 1, players do
		assert(executor.join("garden-sim-" .. i).ok, "garden sim join")
	end
	executor.advance(0)
	local epoch = 0
	local function dispatch(player: string, id: string, args: { any })
		if executor.dispatchClient(player, id, args).ok then
			metrics.acceptedActions += 1
		else
			metrics.rejectedActions += 1
		end
	end
	for _day = 1, days do
		for i = 1, players do
			local player = "garden-sim-" .. i
			local state = executor.snapshot(player)["grow-harvest"]
			if state.seeds.carrot == 0 then
				dispatch(player, "grow-harvest:buy-seed", { "carrot" })
				metrics.sinkTotal += state.balance - executor.snapshot(player)["grow-harvest"].balance
			end
			dispatch(player, "grow-harvest:plant", { 1, "carrot" })
		end
		epoch += 2
		executor.advance(epoch)
		for i = 1, players do
			local player = "garden-sim-" .. i
			dispatch(player, "grow-harvest:harvest", { 1 })
			local before = executor.snapshot(player)["grow-harvest"].balance
			dispatch(player, "grow-harvest:sell-held", { "carrot" })
			metrics.sourceTotal += executor.snapshot(player)["grow-harvest"].balance - before
			before = executor.snapshot(player)["grow-harvest"].balance
			dispatch(player, "survival-coop:buy-defense", {})
			metrics.sinkTotal += before - executor.snapshot(player)["grow-harvest"].balance
		end
		local before = 0
		for i = 1, players do
			before += executor.snapshot("garden-sim-" .. i)["grow-harvest"].balance
		end
		dispatch("garden-sim-1", "survival-coop:defend-active", {})
		local after = 0
		for i = 1, players do
			after += executor.snapshot("garden-sim-" .. i)["grow-harvest"].balance
		end
		metrics.sourceTotal += after - before
	end
	for i = 1, players do
		metrics.balances["garden-sim-" .. i] = executor.snapshot("garden-sim-" .. i)["grow-harvest"].balance
	end
	return metrics
end
M.driver = { run = run, simulate = simulate }
return M
