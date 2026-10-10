--!strict
local suites: { { [string]: () -> () } } = {
	require("./generator.spec"),
	require("./module/Adapter.spec"),
	require("./module/runtime/Loop.spec"),
	require("./module/CollectRaid.spec"),
	require("../../cli/forge/lib/scaffold.spec"),
	require("../../cli/forge/lib/planner.spec"),
	require("../../cli/forge/lib/codegen.spec"),
	require("./module/runtime/Server.spec"),
}
local count = 0
for _, suite in suites do
	local names = {}
	for name in suite do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		suite[name]()
		count += 1
		print("PASS", name)
	end
end
local Generator = require("./generator")
local Executor = require("../../core/domain/genre/Executor")
local Package = require("../../cli/forge/lib/genrecontract")
local input: Package.GenerateInput = {
	mode = "plan",
	slug = "collect-proof",
	pascal = "CollectProof",
	title = "",
	concept = "volcano egg keepers",
	seed = 7,
	teams = { "red", "blue" },
	debugName = "CollectProofDebug",
	guiName = "CollectProofGui",
}
local generated = Generator.generate(input)
assert(#Package.validateGenerator(Generator, Generator.runtime) == 0, "proof.luau invariant")
local clock = 0
local e = Executor.new(
	{ api = 1, order = { "collect-raid" }, configs = { ["collect-raid"] = generated.config } },
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
local advance = e.advance
e.advance = function(epoch)
	clock = epoch
	advance(epoch)
end
for _, check in Generator.driver.run(e, input) do
	assert(check.ok, check.name)
	print("PASS generated", check.name)
end
print("COLLECT", count, "specs passed; generated contract driver passed")
