--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local qa = require("../../commands/qa")
local registryLib = require("../../lib/genreregistry")
local harness = require("../../lib/qaharness")
local run = require("../../lib/run")
local registry, errors = registryLib.discover()
assert(registry, table.concat(errors, "; "))
local target, targetErrors = qa.loadTarget("fixture-survival", registry, nil, "cli/forge/fixtures/vitals-food-rest")
assert(target, table.concat(targetErrors, "; "))
local scenario = serde.decode("yaml", fs.readFile("genres/survival-coop/qa-scenarios/vitals-food-rest.yml"))
if process.args[1] == "restore" then
	local barrier = harness.barrier(serde.decode("json", process.args[2]))
	scenario.steps = {
		{ op = "join", player = "1" },
		{
			op = "command",
			player = "1",
			requestId = "eat",
			sessionEpoch = 0,
			action = "survival-coop:food",
			args = { "ration-stack" },
			times = 100,
		},
		{
			op = "expect_snapshot",
			player = "1",
			genre = "survival-coop",
			field = "inventory.bag.items.ration-stack.quantity",
			equals = 2,
		},
		{
			op = "expect_snapshot",
			player = "1",
			genre = "survival-coop",
			field = "vitals.hungerMilli",
			equals = 100000,
		},
		{
			op = "expect_snapshot",
			player = "1",
			genre = "survival-coop",
			field = "vitals.clockMillis",
			equals = 0,
		},
		{ op = "close", player = "1" },
	}
	local outcome = harness.runNative(scenario, target, barrier)
	assert(outcome.ok, table.concat(outcome.failures, "; "))
	print("PASS food JSON replay 100 times in a fresh process")
else
	local prefix = {}
	for _, step in scenario.steps do
		table.insert(prefix, step)
		if step.op == "close" then
			break
		end
	end
	scenario.steps = prefix
	local barrier = harness.barrier()
	local outcome = harness.runNative(scenario, target, barrier)
	assert(outcome.ok, table.concat(outcome.failures, "; "))
	local result = run.exec("lune", {
		"run",
		"cli/forge/fixtures/vitals-food-rest/restart",
		"restore",
		serde.encode("json", barrier.snapshot()),
	})
	assert(result.ok, result.stderr .. result.stdout)
	print(result.stdout)
end
