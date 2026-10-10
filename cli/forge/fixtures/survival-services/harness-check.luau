--!strict
local suites: { { [string]: () -> () } } = {
	require("../../lib/qaharness.spec"),
	require("../../lib/qastudio.spec"),
}
local passed = 0
for _, suite in suites do
	for name, run in suite do
		run()
		passed += 1
		print("PASS " .. name)
	end
end
assert(passed > 0, "no harness regression cases")
print("harness regression: " .. tostring(passed) .. " passed")
