--!strict
local Generator = require("./generator")
local Executor = require("../../core/domain/genre/Executor")
local Package = require("../../cli/forge/lib/genrecontract")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local Procgen = require("../../cli/forge/lib/procgen")
local Audio = require("../../cli/forge/lib/audiocues")
local QA = require("../../cli/forge/lib/qa")
local input: Package.GenerateInput = {
	mode = "new",
	slug = "arena",
	pascal = "Arena",
	title = "Arena",
	concept = "Arena",
	seed = 42,
	teams = {},
	debugName = "ArenaDebug",
	guiName = "ArenaGui",
}
local function executor()
	local generated = Generator.generate(input)
	local epoch = 0
	local instance = Executor.new(
		{ api = 1, order = { "pvp-arena" }, configs = { ["pvp-arena"] = generated.config } },
		{ Generator.runtime },
		{
			now = function()
				return epoch
			end,
			roll = function()
				return 0
			end,
			emit = function() end,
		}
	)
	local advance = instance.advance
	instance.advance = function(value: number)
		epoch = value
		advance(value)
	end
	return instance
end
return {
	["driver executes actual executor pairing countdown settlement and saves"] = function()
		local checks = Generator.driver.run(executor(), input)
		assert(#checks > 0, "generator.spec.luau: invariant failed")
		for _, check in checks do
			assert(check.ok, check.name)
		end
	end,
	["generator emits deterministic valid native config controls and assets"] = function()
		local first, second = Generator.generate(input), Generator.generate(input)
		assert(#Generator.runtime.validateConfig(first.config) == 0, "generator.spec.luau: invariant failed")
		assert(#first.controls == 2 and #first.artifacts == 2, "generator.spec.luau: invariant failed")
		for index, artifact in first.artifacts do
			assert(artifact.content == second.artifacts[index].content, "generator.spec.luau: invariant failed")
			local doc = serde.decode("yaml", artifact.content)
			if string.find(artifact.path, "procgen", 1, true) then
				local resolved, errors = Procgen.plan(doc, { prop = 800 })
				assert(resolved and #errors == 0, table.concat(errors, ";"))
			else
				local cues, errors = Audio.plan(doc)
				assert(cues and #errors == 0, table.concat(errors, ";"))
			end
		end
		first.config.Round.duration = 999
		assert(second.config.Round.duration == 4, "generator.spec.luau: invariant failed")
	end,
	["simulation executes native rounds without invented currency"] = function()
		local metrics = Generator.driver.simulate(executor(), input, 4, 1)
		assert(metrics.acceptedActions == 4 and metrics.rejectedActions == 0, "generator.spec.luau: invariant failed")
		assert(metrics.sourceTotal == 0 and metrics.sinkTotal == 0, "generator.spec.luau: invariant failed")
		for _, rating in metrics.balances do
			assert(rating == 1000, "generator.spec.luau: invariant failed")
		end
	end,
	["declared scenarios decode and pass QA schema"] = function()
		for _, name in Generator.qa.scenarios do
			local scenario, err = QA.decode(fs.readFile("genres/pvp-arena/qa-scenarios/" .. name .. ".yml"))
			assert(scenario, err)
			local errors = QA.validate(scenario, { expectedGenre = "pvp-arena", expectedName = name })
			assert(#errors == 0, table.concat(errors, ";"))
		end
	end,
}
