--!strict
-- Specs for Motion: determinism, bounded amplitudes, hatch settling, and
-- loop periodicity. Motion is pure Luau, so these run under Lune.

local Motion = require("./Motion")

local LOOP_PROFILES: { Motion.Profile } = { "idle", "walk", "serpent", "celebrate" }
local SEEDS: { number } = { 1, 42, 101, 106, -7 }

local function nearly(a: number, b: number): boolean
	return math.abs(a - b) < 1e-9
end

local function sameSample(a: Motion.Sample, b: Motion.Sample): boolean
	return nearly(a.offset.x, b.offset.x)
		and nearly(a.offset.y, b.offset.y)
		and nearly(a.offset.z, b.offset.z)
		and nearly(a.pitch, b.pitch)
		and nearly(a.yaw, b.yaw)
		and nearly(a.roll, b.roll)
		and nearly(a.scale.x, b.scale.x)
		and nearly(a.scale.y, b.scale.y)
		and nearly(a.scale.z, b.scale.z)
end

return {
	["sample is deterministic for a seed"] = function()
		for _, profile in LOOP_PROFILES do
			for _, seed in SEEDS do
				for _, t in { 0, 0.37, 1.9, 7.3 } do
					local a = Motion.sample(profile, t, seed)
					local b = Motion.sample(profile, t, seed)
					assert(sameSample(a, b), "sample is deterministic")
				end
			end
		end
	end,

	["seed only shifts phase"] = function()
		local a = Motion.sample("idle", 1.25, 1)
		local b = Motion.sample("idle", 1.25, 2)
		assert(not sameSample(a, b), "different seeds desync the phase")
	end,

	["loop amplitudes stay bounded"] = function()
		for _, profile in LOOP_PROFILES do
			for _, seed in SEEDS do
				local t = 0
				while t < 12 do
					local s = Motion.sample(profile, t, seed)
					assert(math.abs(s.offset.x) <= 0.6, "offset.x bounded")
					assert(math.abs(s.offset.y) <= 0.6, "offset.y bounded")
					assert(math.abs(s.offset.z) <= 0.6, "offset.z bounded")
					assert(math.abs(s.pitch) <= 0.4, "pitch bounded")
					assert(math.abs(s.yaw) <= 0.4, "yaw bounded")
					assert(math.abs(s.roll) <= 0.4, "roll bounded")
					assert(s.scale.x >= 0.85 and s.scale.x <= 1.15, "scale.x bounded")
					assert(s.scale.y >= 0.85 and s.scale.y <= 1.15, "scale.y bounded")
					assert(s.scale.z >= 0.85 and s.scale.z <= 1.15, "scale.z bounded")
					t += 0.13
				end
			end
		end
	end,

	["idle breathing is 2 to 4 percent"] = function()
		for _, seed in SEEDS do
			local lo, hi = math.huge, -math.huge
			local t = 0
			while t < 6 do
				local y = Motion.sample("idle", t, seed).scale.y
				lo = math.min(lo, y)
				hi = math.max(hi, y)
				t += 0.05
			end
			local amplitude = (hi - lo) / 2
			assert(amplitude >= 0.019 and amplitude <= 0.041, "breathing amplitude in 2-4%")
		end
	end,

	["loops are periodic"] = function()
		for _, profile in LOOP_PROFILES do
			local period = Motion.periodOf(profile)
			assert(period > 0, "loop profile has a period")
			for _, seed in SEEDS do
				for _, t in { 0, 0.4, 2.7 } do
					local a = Motion.sample(profile, t, seed)
					local b = Motion.sample(profile, t + period, seed)
					assert(sameSample(a, b), "sample repeats every period")
				end
			end
		end
	end,

	["hatch overshoots then settles at scale 1"] = function()
		local peak = 0
		local t = 0
		while t <= 1 do
			local s = Motion.sample("hatch", t, 1)
			peak = math.max(peak, s.scale.y)
			t += 0.01
		end
		assert(peak > 1, "hatch overshoots past 1")

		for _, seed in SEEDS do
			for _, ended in { 1, 1.5, 3 } do
				local s = Motion.sample("hatch", ended, seed)
				assert(nearly(s.scale.x, 1), "hatch scale.x settles at 1")
				assert(nearly(s.scale.y, 1), "hatch scale.y settles at 1")
				assert(nearly(s.scale.z, 1), "hatch scale.z settles at 1")
				assert(nearly(s.offset.y, 0), "hatch offset settles at 0")
			end
		end
	end,

	["profileFor maps archetypes"] = function()
		assert(Motion.periodOf(Motion.profileFor("quad")) == Motion.periodOf("idle"), "quad idles")
		assert(Motion.periodOf(Motion.profileFor("biped")) == Motion.periodOf("idle"), "biped idles")
		assert(Motion.periodOf(Motion.profileFor("serpent")) == Motion.periodOf("serpent"), "serpent sways")
		assert(Motion.periodOf(Motion.profileFor("titan")) > Motion.periodOf("idle"), "titan idles more slowly")
	end,

	["unknown profiles fall back to idle"] = function()
		local a = Motion.sample("nonsense", 1.1, 5)
		local b = Motion.sample("idle", 1.1, 5)
		assert(sameSample(a, b), "unknown profile uses idle")
	end,
}
