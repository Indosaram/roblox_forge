--!strict
-- Every native survival-coop scenario that runs locally against a committed
-- fixture pack is executed through the real `forge qa run` process and must
-- exit 0. This keeps scenario drift (for example a commit barrier parked on the
-- wrong backend update) inside `forge check` instead of only manual runs.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local run = require("../lib/run")
local registryLib = require("../lib/genreregistry")
local qaharness = require("../lib/qaharness")
local qa = require("./qa")

local SCENARIOS_DIR = "genres/survival-coop/qa-scenarios"

-- Scenario -> fixture packs root that hosts its `fixture-survival` pack.
local RUNNABLE: { [string]: string } = {
	["command-replay"] = "cli/forge/fixtures/command-replay",
	["crafting-reservation"] = "cli/forge/fixtures/crafting-reservation",
	["gather-craft-settle"] = "cli/forge/fixtures/survival-services",
	["inventory-conservation"] = "cli/forge/fixtures/inventory-conservation",
	["settlement-conflict"] = "cli/forge/fixtures/settlement-conflict",
	["transfer-crash-matrix"] = "cli/forge/fixtures/item-transfer-recovery",
	["vitals-food-rest"] = "cli/forge/fixtures/vitals-food-rest",
}

-- Native fixture-survival scenarios that no committed fixture can run yet.
local NOT_RUNNABLE: { [string]: string } = {
	["native-wave-smoke"] = 'dispatch refused: feature "wildlife" is declared but not implemented yet',
}

local function qaRun(scenario: string, packsRoot: string): run.ExecResult
	return run.exec("lune", {
		"run",
		"cli/forge",
		"qa",
		"run",
		"--pack",
		"fixture-survival",
		"--scenario",
		scenario,
		"--packs-root",
		packsRoot,
	})
end

local function decode(name: string): any
	local base = SCENARIOS_DIR .. "/" .. name
	local path = if fs.isFile(base .. ".yml") then base .. ".yml" else base .. ".yaml"
	return serde.decode("yaml", fs.readFile(path))
end

local specs: { [string]: () -> () } = {
	["every native fixture-survival scenario is classified"] = function()
		for _, entry in fs.readDir(SCENARIOS_DIR) do
			local name = string.match(entry, "^(.+)%.ya?ml$")
			if name then
				local scenario = decode(name)
				if scenario.kind == "native" and scenario.pack == "fixture-survival" then
					assert(
						RUNNABLE[name] ~= nil or NOT_RUNNABLE[name] ~= nil,
						name .. ": native fixture scenario is neither runnable nor explicitly excluded"
					)
				end
			end
		end
		for name, root in RUNNABLE do
			assert(fs.isDir(root .. "/fixture-survival"), name .. ": missing fixture pack under " .. root)
		end
	end,
	-- Negative: the pre-fix barrier placement (skip 2 / skip 3) parks a later
	-- command instead of the contested commit, and the run must fail.
	["settlement-conflict fails when the barrier skips past the contested commit"] = function()
		local scenario = decode("settlement-conflict")
		local skips = { 2, 3 }
		local barriers = 0
		for _, step in scenario.steps do
			if step.op == "commit_barrier" and step.mode == "suspend" then
				barriers += 1
				step.skip = skips[barriers]
			end
		end
		assert(barriers == 2, "settlement-conflict declares two suspend barriers")
		local registry = assert(registryLib.discover(nil))
		local target, errors =
			qa.loadTarget("fixture-survival", registry, nil, "cli/forge/fixtures/settlement-conflict")
		assert(target, table.concat(errors, "; "))
		local outcome = qaharness.runNative(scenario, target :: qaharness.Target)
		assert(not outcome.ok, "a mis-placed commit barrier must fail the scenario")
		local found = false
		for _, failure in outcome.failures do
			if string.find(failure, "command did not suspend", 1, true) then
				found = true
			end
		end
		assert(found, table.concat(outcome.failures, "; "))
	end,
	["a native scenario run against the wrong fixture pack exits non-zero"] = function()
		local result = qaRun("settlement-conflict", "cli/forge/fixtures/vitals-food-rest")
		assert(not result.ok, "settlement-conflict must not pass without its settlement fixture")
	end,
}

for name, root in RUNNABLE do
	specs["qa run " .. name .. " passes on " .. root] = function()
		local result = qaRun(name, root)
		assert(result.ok, string.format("qa run %s exited non-zero:\n%s%s", name, result.stdout, result.stderr))
		assert(string.find(result.stdout .. result.stderr, "qa run: PASS " .. name, 1, true), "PASS line printed")
	end
end

return specs
