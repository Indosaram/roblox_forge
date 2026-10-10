--!strict

local FeatureFlags = require("./FeatureFlags")

return {
	["boolean flags return their configured value"] = function()
		local flags = FeatureFlags.new({ alpha = true, beta = false })
		assert(flags:isEnabled("alpha", 1) == true, "expected alpha enabled")
		assert(flags:isEnabled("beta", 1) == false, "expected beta disabled")
	end,

	["unknown flags are disabled"] = function()
		local flags = FeatureFlags.new({})
		assert(flags:isEnabled("missing", 42) == false, "expected unknown flag disabled")
	end,

	["override replaces the underlying value"] = function()
		local flags = FeatureFlags.new({ alpha = false, gamma = { rollout = 0 } })
		flags:override("alpha", true)
		flags:override("gamma", true)
		flags:override("delta", false)
		assert(flags:isEnabled("alpha", 1) == true, "expected override to enable alpha")
		assert(flags:isEnabled("gamma", 1) == true, "expected override to win over rollout")
		assert(flags:isEnabled("delta", 1) == false, "expected override on unknown flag")
	end,

	["rollout 0 is disabled for every user"] = function()
		local flags = FeatureFlags.new({ gated = { rollout = 0 } })
		for userId = 1, 200 do
			assert(flags:isEnabled("gated", userId) == false, "rollout 0 must never enable")
		end
	end,

	["rollout 100 is enabled for every user"] = function()
		local flags = FeatureFlags.new({ gated = { rollout = 100 } })
		for userId = 1, 200 do
			assert(flags:isEnabled("gated", userId) == true, "rollout 100 must always enable")
		end
	end,

	["rollout is deterministic per user"] = function()
		local flags = FeatureFlags.new({ gated = { rollout = 50 } })
		for userId = 1, 100 do
			local first = flags:isEnabled("gated", userId)
			local second = flags:isEnabled("gated", userId)
			assert(first == second, "same user must get the same bucket every time")
		end
	end,

	["rollout 50 enables roughly half of users"] = function()
		local flags = FeatureFlags.new({ gated = { rollout = 50 } })
		local enabled = 0
		for userId = 1, 1000 do
			if flags:isEnabled("gated", userId) then
				enabled += 1
			end
		end
		local fraction = enabled / 1000
		assert(fraction >= 0.4 and fraction <= 0.6, `expected 40..60% enabled, got {enabled}/1000`)
	end,

	["rollout distributes across all 100 buckets for real-scale UserIds"] = function()
		local total = 50000

		local flagsTen = FeatureFlags.new({ gated = { rollout = 10 } })
		local tenEnabled = 0
		for offset = 0, total - 1 do
			if flagsTen:isEnabled("gated", 1e9 + offset) then
				tenEnabled += 1
			end
		end
		local tenFraction = tenEnabled / total
		assert(
			tenFraction >= 0.09 and tenFraction <= 0.11,
			`expected roughly 10% enabled for real-scale userIds, got {tenFraction}`
		)

		-- The failure mode is buckets collapsing to a quarter of the range
		-- (0..24 instead of 0..99), which inflates a 1% rollout to about 4%.
		local flagsOne = FeatureFlags.new({ gated = { rollout = 1 } })
		local oneEnabled = 0
		for offset = 0, total - 1 do
			if flagsOne:isEnabled("gated", 1e9 + offset) then
				oneEnabled += 1
			end
		end
		local oneFraction = oneEnabled / total
		assert(
			oneFraction >= 0.005 and oneFraction <= 0.02,
			`expected roughly 1% enabled at rollout=1 for real-scale userIds, got {oneFraction}`
		)
	end,

	["a known real-scale userId lands in its exact bucket"] = function()
		-- Pins the bucket for one real-scale userId so a future change to the
		-- finisher multiply (for example rounding it via a plain double instead
		-- of the exact mod-2^32 long multiplication) is caught even though the
		-- aggregate distribution specs above would still pass.
		local userId = 123456789
		local expectedBucket = 63

		local below = FeatureFlags.new({ gated = { rollout = expectedBucket } })
		assert(below:isEnabled("gated", userId) == false, `userId {userId} must not be enabled below its bucket`)

		local atAndAbove = FeatureFlags.new({ gated = { rollout = expectedBucket + 1 } })
		assert(atAndAbove:isEnabled("gated", userId) == true, `userId {userId} must be enabled at its own bucket`)
	end,
}
