--!strict
-- Cross-process serialization proof using the same native Session harness.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local qa = require("../../commands/qa")
local registryLib = require("../../lib/genreregistry")
local harness = require("../../lib/qaharness")
local run = require("../../lib/run")
local registry, errors = registryLib.discover()
assert(registry, table.concat(errors, "; "))
local target, targetErrors =
	qa.loadTarget("fixture-survival", registry, nil, "cli/forge/fixtures/inventory-conservation")
assert(target, table.concat(targetErrors, "; "))
local scenario = serde.decode("yaml", fs.readFile("genres/survival-coop/qa-scenarios/inventory-conservation.yml"))
if process.args[1] == "restore" then
	local durable = serde.decode("json", process.args[2])
	local barrier = harness.barrier(durable)
	scenario.steps = {
		{ op = "join", player = "1" },
		{
			op = "expect_snapshot",
			player = "1",
			genre = "survival-coop",
			field = "inventory.race.reservations.first.last",
			equals = 1,
		},
		{
			op = "expect_snapshot",
			player = "1",
			genre = "survival-coop",
			field = "inventory.race.items.last.quantity",
			equals = 1,
		},
		{
			op = "expect_snapshot",
			player = "1",
			genre = "survival-coop",
			field = "inventory.weight.weightMilli",
			equals = 90000,
		},
		{
			op = "expect_snapshot",
			player = "1",
			genre = "survival-coop",
			field = "inventory.stock.items.supply.quantity",
			equals = 10,
		},
		{ op = "close", player = "1" },
	}
	local outcome = harness.runNative(scenario, target, barrier)
	assert(outcome.ok, table.concat(outcome.failures, "; "))
	print("PASS serialized inventory reconstruction in fresh process")
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
	local serialized = serde.encode("json", barrier.snapshot())
	local result = run.exec("lune", {
		"run",
		"cli/forge/fixtures/inventory-conservation/restart",
		"restore",
		serialized,
	})
	assert(result.ok, result.stderr .. result.stdout)
	print(result.stdout)
end
