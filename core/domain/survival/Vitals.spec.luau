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
}
