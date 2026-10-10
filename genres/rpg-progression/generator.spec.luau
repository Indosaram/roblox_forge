--!strict
local Generator = require("./generator")
local Executor = require("../../core/domain/genre/Executor")
local Package = require("../../cli/forge/lib/genrecontract")
local Procgen = require("../../cli/forge/lib/procgen")
local Audio = require("../../cli/forge/lib/audiocues")
local serde = require("@lune/serde")
local input: Package.GenerateInput = {
	mode = "new",
	slug = "rpg-proof",
	pascal = "RpgProof",
	title = "RPG proof",
	concept = "boss progression",
	seed = 42,
	teams = {},
	debugName = "RpgProof",
	guiName = "RpgProofGui",
}
local function fresh(): Executor.Executor
	local now = 0
	local generated = Generator.generate(input)
	local executor = Executor.new(
		{ api = 1, order = { Generator.id }, configs = { [Generator.id] = generated.config } },
		{ Generator.runtime },
		{
			now = function()
				return now
			end,
			roll = function()
				return 0
			end,
			emit = function() end,
		},
		nil
	)
	local advance = executor.advance
	executor.advance = function(epoch)
		now = epoch
		advance(epoch)
	end
	return executor
end
return {
	["descriptor and native runtime driver execute through Executor"] = function()
		assert(#Package.validateGenerator(Generator, Generator.runtime) == 0, "descriptor validation")
		local checks = Generator.driver.run(fresh(), input)
		assert(#checks == 5, "nonempty native proof")
		for _, check in checks do
			assert(check.ok, check.name)
		end
	end,
	["simulation reports real once-only native quest currency"] = function()
		local metrics = Generator.driver.simulate(fresh(), input, 2, 2)
		assert(metrics.sourceTotal == 10 and metrics.sinkTotal == 0, "one first-boss reward per player")
		assert(metrics.acceptedActions == 10 and metrics.rejectedActions == 2, "duplicate claims rejected")
		assert(metrics.balances["rpg-sim-1"] == 5 and metrics.balances["rpg-sim-2"] == 5, "actual wallets")
	end,
	["deterministic generation provides valid owned assets and client controls"] = function()
		local a, b = Generator.generate(input), Generator.generate(input)
		assert(#a.artifacts == 2 and #a.controls == 3, "complete starter surface")
		for index, artifact in a.artifacts do
			assert(artifact.content == b.artifacts[index].content, "deterministic asset bytes")
		end
		local _, procErrors = Procgen.parse(serde.decode("yaml", a.artifacts[1].content))
		local _, audioErrors = Audio.plan(serde.decode("yaml", a.artifacts[2].content))
		assert(#procErrors == 0, table.concat(procErrors, "; "))
		assert(#audioErrors == 0, table.concat(audioErrors, "; "))
		a.config.bosses.slime.health = 99
		assert(b.config.bosses.slime.health == 2, "config isolation")
		for _, control in a.controls do
			local declared = false
			for _, action in Generator.runtime.actions do
				if control.action == Generator.id .. ":" .. action.id and action.origin == "client" then
					declared = true
				end
			end
			assert(declared, "control maps to declared client action")
		end
	end,
}
