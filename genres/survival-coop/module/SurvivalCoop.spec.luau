--!strict
-- Specs for SurvivalCoop: wave scheduling, enemy ramp, defense, and hooks.

local SurvivalCoop = require("./SurvivalCoop")

local CONFIG: SurvivalCoop.Config = {
	waveInterval = 60,
	baseEnemies = 3,
	growth = 2,
}

local function newCoop(hooks: SurvivalCoop.Hooks?)
	return SurvivalCoop.new(CONFIG, hooks)
end

return {
	["first tick arms the schedule without spawning"] = function()
		local coop = newCoop()
		assert(coop:tick(1000) == nil, "no wave on first tick")
		assert(coop:waveIndex() == 0, "no waves spawned")
		assert(coop:nextWaveAt() == 1060, "next wave armed one interval out")
	end,

	["tick before the interval returns nil"] = function()
		local coop = newCoop()
		coop:tick(0)
		assert(coop:tick(59.9) == nil, "not due yet")
		assert(coop:secondsUntilNext(0) == 60, "countdown from start")
		assert(coop:secondsUntilNext(30) == 30, "countdown mid")
	end,

	["tick at the interval spawns wave 1"] = function()
		local coop = newCoop()
		coop:tick(0)
		local wave = coop:tick(60)
		assert(wave ~= nil, "wave due at interval")
		assert(wave.index == 1, "wave index 1")
		assert(wave.enemies == 3, "base enemies")
		assert(coop:waveIndex() == 1, "wave counter advanced")
		assert(coop:nextWaveAt() == 120, "next wave rescheduled")
	end,

	["enemies ramp by growth each wave"] = function()
		local coop = newCoop()
		coop:tick(0)
		local wave1 = coop:tick(60)
		assert(wave1 ~= nil, "wave 1 due")
		assert(wave1.enemies == 3, "wave 1 enemies")
		local wave2 = coop:tick(120)
		assert(wave2 ~= nil, "wave 2 due")
		assert(wave2.enemies == 5, "wave 2 enemies")
		local wave3 = coop:tick(180)
		assert(wave3 ~= nil, "wave 3 due")
		assert(wave3.enemies == 7, "wave 3 enemies")
		assert(coop:enemiesFor(10) == 21, "enemiesFor formula")
	end,

	["tick between waves returns nil"] = function()
		local coop = newCoop()
		coop:tick(0)
		coop:tick(60)
		assert(coop:tick(90) == nil, "no wave between intervals")
		assert(coop:secondsUntilNext(90) == 30, "countdown continues")
	end,

	["OnWaveSpawn receives the spawned wave"] = function()
		local calls = {}
		local coop = newCoop({
			OnWaveSpawn = function(wave)
				table.insert(calls, wave)
			end,
		})
		coop:tick(0)
		coop:tick(60)
		assert(#calls == 1, "hook called once")
		assert(calls[1].index == 1, "hook wave index")
		assert(calls[1].enemies == 3, "hook wave enemies")
	end,

	["defend wins when defensePower meets enemies"] = function()
		local coop = newCoop()
		coop:tick(0)
		coop:tick(60)
		assert(coop:defend(1, 3) == true, "exact power wins")
		assert(coop:defend(1, 99) == true, "surplus power wins")
	end,

	["defend loses when defensePower is short"] = function()
		local coop = newCoop()
		coop:tick(0)
		coop:tick(60)
		assert(coop:defend(1, 2) == false, "one short loses")
		assert(coop:defend(2, 4) == false, "scales with wave size")
	end,

	["OnWaveResolved receives the full resolution"] = function()
		local calls = {}
		local coop = newCoop({
			OnWaveResolved = function(resolution)
				table.insert(calls, resolution)
			end,
		})
		coop:tick(0)
		coop:tick(60)
		coop:defend(1, 5)
		assert(#calls == 1, "hook called once")
		assert(calls[1].index == 1, "resolution index")
		assert(calls[1].enemies == 3, "resolution enemies")
		assert(calls[1].defensePower == 5, "resolution defense")
		assert(calls[1].won == true, "resolution won")
	end,

	["secondsUntilNext never goes negative"] = function()
		local coop = newCoop()
		coop:tick(0)
		assert(coop:secondsUntilNext(1000) == 0, "clamps to zero when overdue")
	end,

	["forceNext spawns immediately and restores cadence"] = function()
		local coop = newCoop()
		coop:tick(0)
		local wave = coop:forceNext(10)
		assert(wave ~= nil, "forced wave spawned")
		assert(wave.index == 1, "forced wave index")
		assert(coop:nextWaveAt() == 70, "cadence resumes from force time")
	end,

	["new rejects nothing but starts idle"] = function()
		local coop = newCoop()
		assert(coop:nextWaveAt() == nil, "no schedule before first tick")
		assert(coop:secondsUntilNext(0) == 0, "no countdown before first tick")
	end,
}
