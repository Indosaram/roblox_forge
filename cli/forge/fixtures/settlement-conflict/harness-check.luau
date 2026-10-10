--!strict
local specs: { [string]: () -> () } = require("../../lib/qaharness.spec")
local names: { string } = {}
for name in specs do
	table.insert(names, name)
end
table.sort(names)
for _, name in names do
	specs[name]()
	print("PASS " .. name)
end
print(string.format("native harness: %d passed", #names))
