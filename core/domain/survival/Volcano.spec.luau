--!strict
local Volcano = require("./Volcano")
return {
	["volcanic storm integration is independent of heartbeat partition"] = function()
		local policy = {
			clearSeconds = 300,
			stormSeconds = 120,
			stormMultiplier = 2,
			healthPerSecond = 1,
			fatiguePerSecond = 2,
			bootsMultiplier = 0.5,
			springRecovery = 5,
			lavaMaxHealthFraction = 0.25,
		}
		local zone = { exposed = true, spring = false, lava = false }
		local initial = { health = 100, maxHealth = 100, fatigue = 0 }
		local whole = Volcano.advance(initial, 295, 305, 0, zone, true, policy, 1)
		local first = Volcano.advance(initial, 295, 300, 0, zone, true, policy, 1)
		local split = Volcano.advance(first, 300, 305, 0, zone, true, policy, 1)
		assert(whole.health == split.health, "partition changed health")
		assert(whole.fatigue == split.fatigue, "partition changed fatigue")
		assert(whole.health == 92.5, "storm integral incorrect")
	end,
}
