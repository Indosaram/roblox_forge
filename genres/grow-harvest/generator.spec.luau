--!strict
local Generator = require("./generator")
local Executor = require("../../core/domain/genre/Executor")
local Types = require("../../cli/forge/lib/genrecontract")
local Fixture = require("./module/Adapter.fixture")
local serde = require("@lune/serde")
local procgen = require("../../cli/forge/lib/procgen")
local fs = require("@lune/fs")
local qa = require("../../cli/forge/lib/qa")
local audio = require("../../cli/forge/lib/audiocues")
local INPUT: Types.GenerateInput = {
	mode = "new",
	slug = "garden",
	pascal = "Garden",
	title = "Garden",
	concept = "carrots",
	seed = 42,
	teams = {},
	debugName = "GardenDebug",
	guiName = "GardenGui",
}
local function newExecutor()
	local clock = 100
	local executor = Executor.new(
		{ api = 1, order = { "grow-harvest" }, configs = { ["grow-harvest"] = Fixture.config() } },
		{ Generator.runtime },
		{
			now = function()
				return clock
			end,
			roll = function()
				return 0
			end,
			emit = function() end,
		}
	)
	local advance = executor.advance
	executor.advance = function(epoch)
		clock = epoch
		advance(epoch)
	end
	return executor
end
return {
	["declared scenarios satisfy current QA schema and exact capability metadata"] = function()
		for _, name in Generator.qa.scenarios do
			local scenario = serde.decode("yaml", fs.readFile("genres/grow-harvest/qa-scenarios/" .. name .. ".yml"))
			local errors = qa.validate(scenario, { expectedGenre = "grow-harvest", expectedName = name })
			assert(#errors == 0, table.concat(errors, "; "))
			assert(scenario.contract_api == 1, "contract API required")
			for _, operation in scenario.operations do
				assert(table.find(Generator.qa.operations, operation) ~= nil, "undeclared operation")
			end
			for _, step in scenario.steps do
				if step.target then
					assert(table.find(Generator.qa.targets, step.target) ~= nil, "undeclared target")
				end
			end
		end
	end,
	["generator descriptor and deterministic machine artifacts validate"] = function()
		assert(
			#Types.validateRuntime(Generator.runtime) == 0,
			"expected #Types.validateRuntime(Generator.runtime) == 0"
		)
		assert(
			#Types.validateGenerator(Generator, Generator.runtime) == 0,
			"expected #Types.validateGenerator(Generator, Generator.runtime) == 0"
		)
		local a, b = Generator.generate(INPUT), Generator.generate(INPUT)
		assert(
			serde.encode("json", a) == serde.encode("json", b),
			'expected serde.encode("json", a) == serde.encode("json", b)'
		)
		assert(
			#Generator.runtime.validateConfig(a.config) == 0 and #a.controls == 4,
			"expected #Generator.runtime.validateConfig(a.config) == 0 and #a.controls == 4"
		)
		for _, artifact in a.artifacts do
			if string.find(artifact.path, "procgen.yml", 1, true) then
				local entries, errors = procgen.parse(serde.decode("yaml", artifact.content))
				assert(#errors == 0 and #entries == 1, "expected #errors == 0 and #entries == 1")
			elseif string.find(artifact.path, "audio.yml", 1, true) then
				local cues, errors = audio.plan(serde.decode("yaml", artifact.content))
				assert(cues ~= nil and #errors == 0, table.concat(errors, "; "))
			end
		end
	end,
	["driver runs native farming through actual executor and restores envelope"] = function()
		local checks = Generator.driver.run(newExecutor(), INPUT)
		assert(#checks > 0, "expected #checks > 0")
		for _, check in checks do
			assert(check.ok, check.name)
		end
	end,
	["simulation records real sources sinks and player balances"] = function()
		local metrics = Generator.driver.simulate(newExecutor(), INPUT, 2, 3)
		assert(
			metrics.sourceTotal == 60
				and metrics.sinkTotal == 6
				and metrics.acceptedActions == 24
				and metrics.rejectedActions == 0,
			"expected metrics.sourceTotal == 60 and metrics.sinkTotal == 6 and metrics.acceptedActions == 24 and metrics.rejectedActions == 0"
		)
		assert(
			metrics.balances["grow-sim-1"] == 37 and metrics.balances["grow-sim-2"] == 37,
			'expected metrics.balances["grow-sim-1"] == 37 and metrics.balances["grow-sim-2"] == 37'
		)
	end,
	["executor validates future save versions and forged tuples without ledger change"] = function()
		local executor = newExecutor()
		assert(executor.join("p").ok, 'expected executor.join("p").ok')
		local before = serde.encode("json", executor.save("p"))
		local invalid: { { any } } = { { 1, "carrot", "extra" }, { 0 / 0, "carrot" }, { [1] = 1, [3] = "carrot" } }
		for _, args in invalid do
			assert(
				not executor.dispatchClient("p", "grow-harvest:plant", args).ok,
				'expected not executor.dispatchClient("p", "grow-harvest:plant", args).ok'
			)
			assert(
				serde.encode("json", executor.save("p")) == before,
				'expected serde.encode("json", executor.save("p")) == before'
			)
		end
		local save = executor.save("p")
		executor.leave("p")
		save.genres["grow-harvest"].version = 2
		assert(not executor.join("p", save).ok, 'expected not executor.join("p", save).ok')
		save.genres["grow-harvest"].version = 1
		assert(executor.join("p", save).ok, 'expected executor.join("p", save).ok')
	end,
}
