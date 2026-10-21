--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Rng = require("../../../../core/domain/random/Rng")
local topologySource = fs.readFile("core/domain/island/Topology.luau")
local function topology(source: string): any
	return luau.load(source)()
end
local specs = fs.readFile("core/domain/island/TopologyRoles.spec.luau")
for _, mutation in
	{
		{ "forbidden-transition", "if not ROLE_EDGES%[from%]%[to%] then", "if false then" },
		{ "unknown-role", "if Topology.ROLES%[role%] == nil then", "if false then" },
		{ "level-gate", "if level < minimum then", "if false then" },
	}
do
	local changed, count = string.gsub(topologySource, mutation[2], mutation[3])
	assert(count == 1, "mutation must change exactly one guard")
	local mutant = topology(changed)
	local tests = luau.load(specs, { environment = {
		require = function()
			return mutant
		end,
	} })()
	local killed = false
	for _, test in tests do
		if not pcall(test) then
			killed = true
		end
	end
	assert(killed, "mutation survived: " .. mutation[1])
	print("KILLED " .. mutation[1])
end
local expedition = fs.readFile("core/domain/island/Expedition.luau")
local changed, count = string.gsub(expedition, "if facts.stage > 1 and", "if false and")
assert(count == 1, "mission mutation must change exactly one guard")
local mutant = luau.load(changed, { environment = {
	require = function()
		return Rng
	end,
} })()
local tests = luau.load(fs.readFile("core/domain/island/ExpeditionAdmission.spec.luau"), {
	environment = {
		require = function()
			return mutant
		end,
	},
})()
local killed = false
for _, test in tests do
	if not pcall(test) then
		killed = true
	end
end
assert(killed, "mutation survived: mission-gate")
print("KILLED mission-gate")
