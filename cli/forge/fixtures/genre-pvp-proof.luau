--!strict
local suites: { { [string]: () -> () } } = {
	require("../../../genres/pvp-arena/module/Matchmaking.spec"),
	require("../../../genres/pvp-arena/module/Round.spec"),
	require("../../../genres/pvp-arena/module/Rank.spec"),
	require("../../../genres/pvp-arena/module/Adapter.spec"),
	require("../../../genres/pvp-arena/generator.spec"),
}
local passed = 0
for _, suite in suites do
	local names = {}
	for name in suite do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		suite[name]()
		passed += 1
		print("PASS " .. name)
	end
end
print(string.format("PVP: %d passed, 0 failed", passed))
