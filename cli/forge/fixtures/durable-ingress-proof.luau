--!strict
local suites: { { [string]: () -> () } } = {
	require("../lib/command-transport.spec"),
	require("../lib/genre-server.spec"),
	require("../lib/command-replay.spec"),
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
print(string.format("durable ingress: %d passed", count))
