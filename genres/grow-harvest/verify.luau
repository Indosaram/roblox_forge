--!strict
local native = require("./module/GrowHarvest.spec")
local adapter = require("./module/Adapter.spec")
local integration = require("./generator.spec")
local total = 0
local suites: { { [string]: () -> () } } = { native, adapter, integration }
for _, suite in suites do
	local names: { string } = {}
	for name in suite do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		suite[name]()
		total += 1
		print("PASS " .. name)
	end
end
print("PASS grow-harvest: " .. total .. " tests")
