--!strict
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local Runtime = require("./module/Contract")
local Fixture = require("./module/Adapter.fixture")
local Executor = require("../../core/domain/genre/Executor")
local passed = 0
local function specs(tests: { [string]: () -> () })
	local names = {}
	for name in tests do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		tests[name]()
		passed += 1
		print("PASS " .. name)
	end
end
specs(require("./module/SurvivalCoop.spec"))
specs(require("./module/Adapter.spec"))
local now = 0
local executor = Executor.new(
	{ api = 1, order = { Runtime.id }, configs = { [Runtime.id] = Fixture.config :: any } },
	{ Runtime },
	{
		now = function()
			return now
		end,
		roll = function()
			return 0
		end,
		emit = function(_) end,
	}
)
assert(executor.join("p", nil).ok, 'check: executor.join("p", nil).ok')
assert(
	not executor.dispatchClient("p", "survival-coop:defend-active", { 99 }).ok,
	'check: not executor.dispatchClient("p", "survival-coop:defend-active", { 99 }).ok'
)
assert(
	executor.dispatchClient("p", "survival-coop:buy-defense", {}).ok,
	'check: executor.dispatchClient("p", "survival-coop:buy-defense", {}).ok'
)
executor.advance(0)
now = 2
executor.advance(now)
assert(
	executor.dispatchClient("p", "survival-coop:defend-active", {}).ok,
	'check: executor.dispatchClient("p", "survival-coop:defend-active", {}).ok'
)
assert(executor.snapshot("p")[Runtime.id].balance == 5, 'check: executor.snapshot("p")[Runtime.id].balance == 5')
assert(
	not executor.dispatchClient("p", "survival-coop:defend-active", {}).ok,
	'check: not executor.dispatchClient("p", "survival-coop:defend-active", {}).ok'
)
local saved = executor.save("p")
executor.leave("p")
assert(executor.join("p", saved).ok, 'check: executor.join("p", saved).ok')
assert(executor.snapshot("p")[Runtime.id].balance == 5, 'check: executor.snapshot("p")[Runtime.id].balance == 5')
local QA = require("../../cli/forge/lib/qa")
for _, name in { "contract-loop", "contract-rejoin" } do
	local source = fs.readFile("genres/survival-coop/qa-scenarios/" .. name .. ".yml")
	local errors = QA.validate(serde.decode("yaml", source))
	assert(#errors == 0, table.concat(errors, "; "))
end
print(string.format("survival proof: %d specs, Executor ingress/settlement/rejoin, 2 QA schemas passed", passed))
local Generator = require("./generator")
local Types = require("../../cli/forge/lib/genrecontract")
local Procgen = require("../../cli/forge/lib/procgen")
local Audio = require("../../cli/forge/lib/audiocues")
local input: Types.GenerateInput = {
	mode = "new",
	slug = "survival-proof",
	pascal = "SurvivalProof",
	title = "Survival Proof",
	concept = "camp",
	seed = 42,
	teams = {},
	debugName = "Proof",
	guiName = "Proof",
}
local generated = Generator.generate(input)
assert(#Types.validateRuntime(Runtime) == 0, "check: #Types.validateRuntime(Runtime) == 0")
assert(
	#Types.validateManifest(
			serde.decode("yaml", fs.readFile("genres/survival-coop/forge-package.yml")),
			Runtime.id,
			"1.0.0"
		) == 0,
	'check: #Types.validateManifest( serde.decode("yaml", fs.readFile("genres/survival-coop/forge-package.yml")), Runtime.id, "1.0.0" ) == 0'
)
assert(#Runtime.validateConfig(generated.config) == 0, "check: #Runtime.validateConfig(generated.config) == 0")
local function fresh()
	local clock = 0
	local instance = Executor.new(
		{ api = 1, order = { Runtime.id }, configs = { [Runtime.id] = generated.config } },
		{ Runtime },
		{
			now = function()
				return clock
			end,
			roll = function()
				return 0
			end,
			emit = function(_) end,
		}
	)
	local advance = instance.advance
	instance.advance = function(epoch)
		clock = epoch
		advance(epoch)
	end
	return instance
end
for _, check in Generator.driver.run(fresh(), input) do
	assert(check.ok, check.name)
end
local metrics = Generator.driver.simulate(fresh(), input, 1, 3)
assert(
	metrics.sourceTotal == 15 and metrics.sinkTotal == 20 and metrics.balances["1"] == 5,
	"three native wins fund two upgrades and leave five coins"
)
assert(
	metrics.acceptedActions == 5 and metrics.rejectedActions == 1,
	"two upgrades, three defenses, one insufficient-funds refusal"
)
print("PASS generator driver, deterministic simulation, manifest/runtime/config")
for _, artifact in generated.artifacts do
	if string.find(artifact.path, "procgen.yml", 1, true) then
		local assets, errors = Procgen.plan(serde.decode("yaml", artifact.content), { prop = 800 })
		assert(assets ~= nil and #assets == 1 and #errors == 0, table.concat(errors, "; "))
	elseif string.find(artifact.path, "audio.yml", 1, true) then
		local cues, errors = Audio.plan(serde.decode("yaml", artifact.content))
		assert(cues ~= nil and #cues == 1 and #errors == 0, table.concat(errors, "; "))
	end
end
print("PASS keyless prop/audio preflight")
