--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local qa = require("../../commands/qa")
local Registry = require("../../lib/genreregistry")
local Harness = require("../../lib/qaharness")
local run = require("../../lib/run")
local registry, errors = Registry.discover()
assert(registry, table.concat(errors, "; "))
local target, targetErrors = qa.loadTarget("fixture-survival", registry, nil, "cli/forge/fixtures/crafting-reservation")
assert(target, table.concat(targetErrors, "; "))
local scenario = serde.decode("yaml", fs.readFile("genres/survival-coop/qa-scenarios/crafting-reservation.yml"))
if process.args[1] == "restore" then
	local barrier = Harness.barrier(serde.decode("json", process.args[2]))
	local steps: { any } = {
		{ op = "join", player = "1" },
		{
			op = "command",
			player = "1",
			requestId = "reserve",
			sessionEpoch = 0,
			action = "survival-coop:craft-reserve",
			args = { "cord", "hand" },
			times = 100,
		},
		{
			op = "expect_snapshot",
			player = "1",
			genre = "survival-coop",
			field = "workshop.entries.w1:1:0:7:reserve.job.state",
			equals = "Reserved",
		},
		{
			op = "expect_snapshot",
			player = "1",
			genre = "survival-coop",
			field = "inventory.bag.reservations.w1:1:0:7:reserve.fiber-stack",
			equals = 3,
		},
		{ op = "expect_snapshot", player = "1", genre = "survival-coop", field = "inventory.bag.version", equals = 3 },
		{ op = "close", player = "1" },
	}
	scenario.steps = steps
	local result = Harness.runNative(scenario, target, barrier)
	assert(result.ok, table.concat(result.failures, "; "))
	print("PASS fresh-process reserved job and exact 100 replay")
else
	local prefix = {}
	for _, step in scenario.steps do
		table.insert(prefix, step)
		if step.op == "close" then
			break
		end
	end
	scenario.steps = prefix
	local barrier = Harness.barrier()
	local result = Harness.runNative(scenario, target, barrier)
	assert(result.ok, table.concat(result.failures, "; "))
	local restored = run.exec("lune", {
		"run",
		"cli/forge/fixtures/crafting-reservation/restart",
		"restore",
		serde.encode("json", barrier.snapshot()),
	})
	assert(restored.ok, restored.stdout .. restored.stderr)
	print(restored.stdout)
end
