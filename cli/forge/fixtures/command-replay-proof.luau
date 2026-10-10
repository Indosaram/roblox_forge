--!strict
local suites: { { [string]: () -> () } } = {
	require("../lib/command-replay.spec"),
	require("../lib/qaharness.spec"),
	require("../lib/genre-session.spec"),
	require("./genre-session.spec"),
}
local count = 0
for _, suite in suites do
	for name, test in suite do
		test()
		count += 1
		print("PASS " .. name)
	end
end
print(string.format("Command replay owned checks: %d passed, 0 failed", count))
