--!strict
local Pose = require("./CreaturePose")
return {
	["authoritative attack death and stun override measured movement"] = function()
		local clips: { [string]: string } = {
			warn = "warning",
			windup = "windup",
			strike = "attack",
			dead = "dead",
			stunned = "stun",
			sleep = "rest",
			recovery = "recovery",
		}
		for server, clip in clips do
			local clock = { state = "run", elapsed = 8 }
			local state, elapsed = Pose.sample(clock, server, 20, true, 0.1)
			assert(state == clip and elapsed == 0.1, "server clip resets transition clock")
			local again, time = Pose.sample(clock, server, 20, true, 0.2)
			assert(again == clip and math.abs(time - 0.3) < 0.00001, "same clip retains clock")
		end
	end,
	["locomotion follows speed and mount without replaying chase as a clip"] = function()
		local clock = { state = "idle", elapsed = 0 }
		assert(Pose.sample(clock, "chase", 24, false, 0.1) == "run", "chase runs")
		assert(Pose.sample(clock, "roam", 6, false, 0.1) == "walk", "roam walks")
		assert(Pose.sample(clock, "idle", 0, false, 0.1) == "idle", "stationary idles")
		assert(Pose.sample(clock, nil, 5, true, 0.1) == "ridden", "mount clip")
	end,
}
