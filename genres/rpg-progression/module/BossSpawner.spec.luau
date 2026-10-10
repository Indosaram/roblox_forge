--!strict
-- Specs for BossSpawner: locked regions, interval spawning, roster rotation, and hooks.

local BossSpawner = require("./BossSpawner")

local function newSpawner(hooks: BossSpawner.Hooks?): BossSpawner.BossSpawner
	return BossSpawner.new({
		regions = {
			{ region = "plains", interval = 10, bossIds = { "goblin-king", "wolf-alpha" } },
			{ region = "volcano", interval = 5, bossIds = { "magma-lord" } },
		},
	}, hooks)
end

local function regionSet(names: { string }): (string) -> boolean
	local set: { [string]: boolean } = {}
	for _, name in names do
		set[name] = true
	end
	return function(region: string): boolean
		return set[region] == true
	end
end

return {
	["locked regions never spawn and are not armed"] = function()
		local spawner = newSpawner()
		assert(#spawner:tick(0, regionSet({})) == 0, "no spawn while locked")
		assert(#spawner:tick(100, regionSet({})) == 0, "still no spawn while locked")
		assert(spawner:activeCount() == 0, "no active bosses")
	end,

	["the first unlocked tick arms and the next interval spawns"] = function()
		local spawner = newSpawner()
		assert(#spawner:tick(0, regionSet({ "plains", "volcano" })) == 0, "the first tick only arms")
		local spawned = spawner:tick(5, regionSet({ "volcano" }))
		assert(#spawned == 1 and spawned[1] == "magma-lord", "volcano spawns at its interval")
		assert(spawner:isActive("magma-lord"), "the spawned boss is active")
		assert(spawner:activeCount() == 1, "one active boss")
	end,

	["each region rotates through its roster"] = function()
		local spawner = newSpawner()
		local plains = regionSet({ "plains" })
		spawner:tick(0, plains)
		local first = spawner:tick(10, plains)
		assert(first[1] == "goblin-king", "first boss")
		assert(spawner:defeat("goblin-king"), "the first boss is defeated before the next interval")
		local second = spawner:tick(20, plains)
		assert(second[1] == "wolf-alpha", "second boss")
		assert(spawner:defeat("wolf-alpha"), "the second boss is defeated before the next interval")
		local third = spawner:tick(30, plains)
		assert(third[1] == "goblin-king", "the roster wraps around")
	end,

	["OnBossSpawn and OnBossDefeated fire with the boss context"] = function()
		local spawned: { BossSpawner.Boss } = {}
		local defeated: { BossSpawner.Boss } = {}
		local spawner = newSpawner({
			OnBossSpawn = function(boss)
				table.insert(spawned, boss)
			end,
			OnBossDefeated = function(boss)
				table.insert(defeated, boss)
			end,
		})
		local volcano = regionSet({ "volcano" })
		spawner:tick(0, volcano)
		spawner:tick(5, volcano)
		assert(#spawned == 1, "OnBossSpawn fired once")
		assert(spawned[1].id == "magma-lord" and spawned[1].region == "volcano", "spawn context")

		assert(spawner:defeat("magma-lord"), "defeating an active boss returns true")
		assert(#defeated == 1, "OnBossDefeated fired once")
		assert(defeated[1].id == "magma-lord", "defeat context")
		assert(not spawner:isActive("magma-lord"), "the boss is no longer active")
		assert(not spawner:defeat("nobody"), "defeating an unknown boss returns false")
	end,

	["duplicate boss ids across regions are rejected"] = function()
		local ok = pcall(function()
			BossSpawner.new({
				regions = {
					{ region = "a", interval = 1, bossIds = { "same" } },
					{ region = "b", interval = 1, bossIds = { "same" } },
				},
			})
		end)
		assert(not ok, "a duplicate boss id errors")
	end,

	["a large gap between ticks spawns once, not a catch-up burst"] = function()
		local spawner = BossSpawner.new({
			regions = { { region = "plains", interval = 10, bossIds = { "goblin-king", "wolf-alpha" } } },
		})
		local plains = regionSet({ "plains" })
		spawner:tick(0, plains) -- arms at t=0
		local totalSpawns = 0
		for i = 1, 10 do
			local now = 100 + (i - 1) * 0.016
			totalSpawns += #spawner:tick(now, plains)
		end
		assert(totalSpawns == 1, "expected exactly one spawn after the gap, got " .. totalSpawns)
		assert(spawner:activeCount() == 1, "only one boss became active")
	end,

	["a still-active boss is not re-spawned when its interval elapses again"] = function()
		local spawned: { BossSpawner.Boss } = {}
		local spawner = BossSpawner.new({
			regions = { { region = "volcano", interval = 5, bossIds = { "magma-lord" } } },
		}, {
			OnBossSpawn = function(boss)
				table.insert(spawned, boss)
			end,
		})
		local volcano = regionSet({ "volcano" })
		spawner:tick(0, volcano) -- arms
		spawner:tick(5, volcano) -- spawns magma-lord
		spawner:tick(10, volcano) -- must not re-spawn: magma-lord is still active
		assert(#spawned == 1, "OnBossSpawn must fire once while the boss stays active, fired " .. #spawned)
		assert(spawner:activeCount() == 1, "the live set must still hold exactly one boss")
		assert(spawner:defeat("magma-lord"), "the one active boss can be defeated")
		assert(spawner:activeCount() == 0, "the live set is empty after the defeat")
	end,
}
