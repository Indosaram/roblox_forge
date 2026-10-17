--!strict
local Vitals = require("./Vitals")

local function rejects(fn: () -> ())
	assert(not pcall(fn), "expected rejection")
end

local function equal(a: any, b: any)
	for key, value in a do
		if key ~= "config" then
			assert(value == b[key], key .. ": " .. tostring(value) .. " ~= " .. tostring(b[key]))
		end
	end
end

local function exposureConfig(): any
	return {
		hungerMillisPerUnit = 18000,
		fatigueMilliPerAction = 500,
		restMilliPerSecond = 2000,
		starvationMillisPerUnit = 5000,
		exposureRiseTier1MilliPerSecond = 100,
		exposureRiseTier2MilliPerSecond = 400,
		exposureRiseTier3MilliPerSecond = 1000,
		exposureRecoverMilliPerSecond = 500,
		exposureDamageMillisPerUnit = 5000,
		staminaRegenMilliPerSecond = 5000,
		staminaCostMilliPerAction = 10000,
		respawnDelayMillis = 5000,
	}
end

return {
	["stop rest preserves fatigue and clock without action cost"] = function()
		local state = Vitals.rest(Vitals.action(Vitals.new(1790899200000)), { campfireId = "fire", reachable = true })
		local stopped = Vitals.stopRest(state)
		assert(state.resting and not stopped.resting, "detached rest stop")
		assert(
			stopped.fatigueMilli == state.fatigueMilli and stopped.clockMillis == state.clockMillis,
			"no cost or elapsed time"
		)
		equal(stopped, Vitals.stopRest(stopped))
		rejects(function()
			Vitals.stopRest(Vitals.damage(state, 100000))
		end)
	end,
	["current Unix milliseconds preserve elapsed simulation and bounded cooldown"] = function()
		local now = 1790899200000
		local state = Vitals.advance(Vitals.new(now), now + 18000)
		assert(state.hungerMilli == 99000 and state.activeMillis == 18000, "Unix elapsed simulation")
		assert(state.clockMillis == now + 18000, "absolute clock preserved")
		local last = 2 ^ 53 - 1 - 10000
		assert(Vitals.new(last).combatUntilMillis == 2 ^ 53 - 1, "cooldown fits safe integer")
		rejects(function()
			Vitals.new(last + 1)
		end)
	end,
	["regeneration crosses combat cooldown and hunger thirty identically"] = function()
		local start = Vitals.damage(Vitals.new(0), 50000)
		start.hungerMilli = 31000
		local fine = start
		for i = 1, 100 do
			fine = Vitals.advance(fine, i * 250)
		end
		equal(fine, Vitals.advance(start, 25000))
		assert(fine.healthMilli == 58018, "vital policy expectation")
	end,
	["respawn accepts explicit bounded policy and rejects duplicate revival"] = function()
		local dead = Vitals.damage(Vitals.new(0), 100000)
		local values = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 }
		local revived = Vitals.respawn(dead, values)
		assert(revived.healthMilli == 100000 and revived.hungerMilli == 50000, "vital policy expectation")
		assert(dead.healthMilli == 0, "vital policy expectation")
		rejects(function()
			Vitals.respawn(revived, values)
		end)
		values.healthMilli = 100001
		rejects(function()
			Vitals.respawn(dead, values)
		end)
	end,
	["fractional heartbeat partitions preserve all accumulators through death"] = function()
		local initial = Vitals.damage(Vitals.new(0), 50000)
		for _ = 1, 200 do
			initial = Vitals.action(initial)
		end
		initial = Vitals.rest(initial, { campfireId = "fire", reachable = true })
		local fine = initial
		for i = 1, 10000 do
			fine = Vitals.advance(fine, i * 250)
		end
		equal(fine, Vitals.advance(initial, 2500000))
		assert(fine.healthMilli == 0 and fine.hungerMilli == 0 and fine.fatigueMilli == 0, "vital policy expectation")
	end,
	["fractional absolute timestamps do not accumulate rounding error"] = function()
		local fine = Vitals.new(0)
		for i = 1, 1800 do
			fine = Vitals.advance(fine, i * 10)
		end
		equal(fine, Vitals.advance(Vitals.new(0), 18000))
		assert(fine.hungerMilli == 99000, "vital policy expectation")
	end,
	["starvation starts at the crossing and clamps without heartbeat dependence"] = function()
		local start = Vitals.new(0)
		start.hungerMilli = 1000
		start.healthMilli = 1000
		start.fatigueMilli = 100000
		start = Vitals.rest(start, { campfireId = "fire", reachable = true })
		local fine = start
		for i = 1, 120 do
			fine = Vitals.advance(fine, i * 250)
		end
		equal(fine, Vitals.advance(start, 30000))
		assert(fine.healthMilli == 0 and fine.fatigueMilli == 54000, "vital policy expectation")
	end,
	["offline time freezes vitals and first session protection time"] = function()
		local s = Vitals.advance(Vitals.new(0), 1801000)
		local offline = Vitals.disconnect(s, 1801000)
		local joined = Vitals.reconnect(Vitals.advance(offline, 5000000), 9000000)
		assert(joined.healthMilli == s.healthMilli and joined.hungerMilli == s.hungerMilli, "vital policy expectation")
		assert(
			joined.activeMillis == s.activeMillis and joined.starvationRemainder == s.starvationRemainder,
			"offline accumulators freeze"
		)
		assert(Vitals.advance(joined, 9005000).healthMilli == s.healthMilli - 1000, "online starvation resumes")
	end,
	["invalid clocks effects and rest inputs leave source untouched"] = function()
		local s = Vitals.new(10)
		local original = table.clone(s)
		for _, now in { -1, 9, 10.5, math.huge, -math.huge, 0 / 0 } do
			rejects(function()
				Vitals.advance(s, now)
			end)
		end
		for _, amount in { -1, 0.5, math.huge, 0 / 0, 100001 } do
			rejects(function()
				Vitals.food(s, { hungerMilli = amount, healthMilli = 0, fatigueMilli = 0 })
			end)
		end
		rejects(function()
			Vitals.rest(s, { campfireId = "fire", reachable = false })
		end)
		rejects(function()
			Vitals.rest(s, { campfireId = "", reachable = true })
		end)
		equal(s, original)
	end,
	["food clamps effects and action fatigue uses configured fixed point"] = function()
		local s = Vitals.new(0)
		for _ = 1, 160 do
			s = Vitals.action(s)
		end
		assert(s.fatigueMilli == 80000 and Vitals.movementMilli(s) == 800, "vital policy expectation")
		local food = Vitals.food(s, { hungerMilli = 1000, healthMilli = 1000, fatigueMilli = 100000 })
		assert(
			food.hungerMilli == 100000 and food.healthMilli == 100000 and food.fatigueMilli == 0,
			"food clamps all vital values"
		)
		assert(s.fatigueMilli == 80000, "vital policy expectation")
	end,
	["death requests protected inventory policy without mutating inventory"] = function()
		local young = Vitals.damage(Vitals.new(0), 100000)
		local policy = Vitals.deathPolicy(young)
		assert(
			policy.keepEquipped and not policy.dropBag and policy.ownerOnlyMillis == 600000,
			"vital policy expectation"
		)
		local old = Vitals.advance(young, 1800000)
		assert(Vitals.deathPolicy(old).dropBag, "vital policy expectation")
		rejects(function()
			Vitals.food(old, { hungerMilli = 1000, healthMilli = 1000, fatigueMilli = 0 })
		end)
	end,
	["exposure rises per tier, is mitigated by clothing, and drains health only at full"] = function()
		local config = exposureConfig()
		local naked = Vitals.setEnvironment(Vitals.new(0, config), 3, 0)
		local clothed = Vitals.setEnvironment(Vitals.new(0, config), 3, 500)
		assert(Vitals.advance(naked, 10000).exposureMilli == 10000, "extreme tier rises 1000 milli per second")
		assert(Vitals.advance(clothed, 10000).exposureMilli == 5000, "half resistance halves the rise")
		local temperate = Vitals.advance(Vitals.new(0, config), 10000)
		assert(temperate.exposureMilli == 0 and temperate.healthMilli == 100000, "temperate never rises")
		local full = Vitals.setEnvironment(Vitals.new(0, config), 3, 0)
		full.exposureMilli = 99000
		full.hungerMilli = 100000
		local drained = Vitals.advance(full, 3000)
		-- 1000 ms to reach full, then 2000 ms at 0.2 health milli per ms.
		assert(
			drained.exposureMilli == 100000 and drained.healthMilli == 100000 - 400,
			"drain begins at the full crossing"
		)
		local early = Vitals.advance(full, 1000)
		assert(early.exposureMilli == 100000 and early.healthMilli == 100000, "no drain before the crossing")
		local safe = Vitals.setEnvironment(Vitals.new(0, config), 3, 1000)
		assert(Vitals.advance(safe, 60000).exposureMilli == 0, "full resistance is immune")
		local warm =
			Vitals.rest(Vitals.setEnvironment(Vitals.new(0, config), 3, 0), { campfireId = "fire", reachable = true })
		warm.exposureMilli = 50000
		assert(Vitals.advance(warm, 10000).exposureMilli == 50000 - 5000, "campfire rest recovers")
	end,
	["exposure drain is heartbeat independent and reaches death at the exact millisecond"] = function()
		local config = exposureConfig()
		local start = Vitals.setEnvironment(Vitals.new(0, config), 3, 0)
		start.exposureMilli = 98000
		start.hungerMilli = 100000
		start.healthMilli = 20
		local fine = start
		for i = 1, 40 do
			fine = Vitals.advance(fine, i * 100)
		end
		equal(fine, Vitals.advance(start, 4000))
		-- Full at 2000 ms, then 20 health milli at 0.2 per ms: dead at exactly 2100 ms.
		assert(fine.healthMilli == 0 and fine.exposureMilli == 100000, "drained to death")
		assert(fine.respawnWaitMillis == 5000 - (4000 - 2100), "death time fixes the wait")
		assert(Vitals.advance(start, 2099).healthMilli == 1, "alive one millisecond before the fatal tick")
		assert(Vitals.advance(start, 2100).healthMilli == 0, "dead at the fatal millisecond")
	end,
	["exposure config groups are all or nothing and bounded"] = function()
		for _, field in Vitals.EXPOSURE_FIELDS do
			local config = exposureConfig()
			config[field] = nil
			rejects(function()
				Vitals.new(0, config)
			end)
		end
		for _, field in Vitals.STAMINA_FIELDS do
			local config = exposureConfig()
			config[field] = nil
			rejects(function()
				Vitals.new(0, config)
			end)
		end
		local zero = exposureConfig()
		zero.exposureDamageMillisPerUnit = 0
		rejects(function()
			Vitals.new(0, zero)
		end)
		local legacy = Vitals.new(0)
		assert(legacy.exposureMilli == nil and legacy.staminaMilli == nil, "legacy state has no new gauges")
		rejects(function()
			Vitals.setEnvironment(legacy, 1, 0)
		end)
		local state = Vitals.new(0, exposureConfig())
		for _, bad in { { 4, 0 }, { -1, 0 }, { 1, 1001 }, { 1, -1 }, { 0.5, 0 } } do
			rejects(function()
				Vitals.setEnvironment(state, bad[1], bad[2])
			end)
		end
	end,
	["stamina regenerates automatically, floors at zero and slows movement"] = function()
		local config = exposureConfig()
		local state = Vitals.new(0, config)
		assert(state.staminaMilli == 100000, "starts full")
		for _ = 1, 8 do
			state = Vitals.action(state)
		end
		assert(state.staminaMilli == 20000 and not Vitals.exhausted(state), "actions spend stamina")
		state = Vitals.action(Vitals.action(Vitals.action(state)))
		assert(state.staminaMilli == 0 and Vitals.exhausted(state), "stamina floors at zero")
		assert(Vitals.movementMilli(state) == 800, "exhaustion slows movement")
		local regen = Vitals.advance(state, 1000)
		assert(regen.staminaMilli == 5000 and not Vitals.exhausted(regen), "regenerates without resting")
		assert(Vitals.movementMilli(regen) == 1000, "movement recovers with stamina")
		local fine = state
		for i = 1, 1000 do
			fine = Vitals.advance(fine, i * 7)
		end
		equal(fine, Vitals.advance(state, 7000))
		assert(Vitals.advance(state, 100000).staminaMilli == 100000, "caps at full")
	end,
	["respawn is refused until the configured delay has elapsed online"] = function()
		local config = exposureConfig()
		local dead = Vitals.damage(Vitals.new(0, config), 100000)
		local values = { healthMilli = 100000, hungerMilli = 50000, fatigueMilli = 0 }
		assert(Vitals.respawnWait(dead) == 5000, "wait starts at the configured delay")
		rejects(function()
			Vitals.respawn(dead, values)
		end)
		local almost = Vitals.advance(dead, 4999)
		assert(Vitals.respawnWait(almost) == 1, "wait counts down")
		rejects(function()
			Vitals.respawn(almost, values)
		end)
		local offline = Vitals.advance(Vitals.disconnect(almost, 4999), 99999)
		assert(Vitals.respawnWait(offline) == 1, "offline time does not shorten the wait")
		local ready = Vitals.advance(dead, 5000)
		local revived = Vitals.respawn(ready, values)
		assert(
			revived.healthMilli == 100000 and revived.exposureMilli == 0 and revived.staminaMilli == 100000,
			"gauges reset"
		)
		local plain = Vitals.respawn(Vitals.damage(Vitals.new(0), 100000), values)
		assert(plain.healthMilli == 100000, "no configured delay keeps instant respawn")
	end,
	["death rule keeps the safe zone inventory and drops only in the opt-in danger zone"] = function()
		local old = Vitals.new(0, exposureConfig())
		old.activeMillis = 3600000
		local dead = Vitals.damage(old, 100000)
		local safe = Vitals.deathPolicy(dead, "safe")
		assert(not safe.dropBag and safe.respawnWaitMillis == 5000, "safe zone keeps everything and waits")
		assert(Vitals.deathPolicy(dead, "danger").dropBag, "danger zone drops")
		local fresh = Vitals.damage(Vitals.new(0, exposureConfig()), 100000)
		assert(Vitals.deathPolicy(fresh, "danger").dropBag, "no newcomer protection after opting in")
		assert(not Vitals.deathPolicy(Vitals.damage(Vitals.new(0), 100000)).dropBag, "legacy rule is unchanged")
		assert(not Vitals.deathPolicy(fresh).dropBag, "the actor starts in the safe zone")
		local entered = Vitals.setZone(Vitals.new(0, exposureConfig()), "danger")
		assert(entered.zone == "danger", "opt-in is a detached transition")
		assert(Vitals.deathPolicy(Vitals.damage(entered, 100000)).dropBag, "own danger zone drops")
		rejects(function()
			Vitals.setZone(Vitals.new(0), "danger")
		end)
		rejects(function()
			Vitals.setZone(Vitals.new(0, exposureConfig()), "wild" :: any)
		end)
		rejects(function()
			Vitals.setZone(dead, "danger")
		end)
		rejects(function()
			Vitals.deathPolicy(dead, "wild" :: any)
		end)
		rejects(function()
			Vitals.deathPolicy(Vitals.new(0), "safe")
		end)
	end,
}
