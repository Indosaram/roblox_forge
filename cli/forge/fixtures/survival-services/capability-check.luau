--!strict
local suites: { { [string]: () -> () } } = {
	require("../../../../genres/survival-coop/module/Mode.spec"),
	require("../../lib/contentrender.spec"),
}
local passed = 0
for _, suite in suites do
	for name, run in suite do
		run()
		passed += 1
		print("PASS " .. name)
	end
end
assert(passed > 0, "no capability regression cases")
print("capability regression: " .. tostring(passed) .. " passed")
