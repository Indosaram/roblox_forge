--!strict
-- Scoped runnable regression entry point; never discovers or reads games.
local suites: { { path: string, tests: { [string]: () -> () } } } = {
	{ path = "Executor", tests = require("../../../core/domain/genre/Executor.spec") },
	{ path = "Recipe", tests = require("../../../core/domain/genre/Recipe.spec") },
	{ path = "GardenDefense", tests = require("../../../genres/survival-coop/module/GardenDefense.spec") },
	{ path = "genrecontract", tests = require("../lib/genrecontract.spec") },
	{ path = "genreregistry", tests = require("../lib/genreregistry.spec") },
	{ path = "Schema", tests = require("../../../core/infra/net/Schema.spec") },
	{ path = "cliutil", tests = require("../lib/cliutil.spec") },
}
local count = 0
for _, suite in suites do
	local names = {}
	for name in suite.tests do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		suite.tests[name]()
		count += 1
		print("PASS " .. suite.path .. " :: " .. name)
	end
end
print(string.format("%d tests passed", count))
