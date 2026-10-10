--!strict
-- Specs for RateLimiter: burst, refill, per-key/per-action isolation, forget, unknowns.

local RateLimiter = require("./RateLimiter")

local CONFIG: RateLimiter.Config = {
	BuyEgg = { capacity = 5, refillPerSecond = 2 },
	Raid = { capacity = 2, refillPerSecond = 0.2 },
}

return {
	["allows a burst up to capacity then refuses"] = function()
		local limiter = RateLimiter.new(CONFIG)
		for i = 1, 5 do
			local ok = limiter:allow("p1", "BuyEgg", 0)
			assert(ok, "burst call " .. tostring(i) .. " should pass")
		end
		local ok, reason = limiter:allow("p1", "BuyEgg", 0)
		assert(ok == false, "sixth call should be refused")
		assert(reason == "rate limited: BuyEgg", "unexpected reason: " .. tostring(reason))
	end,

	["refills over time"] = function()
		local limiter = RateLimiter.new({ Raid = { capacity = 1, refillPerSecond = 2 } })
		assert(limiter:allow("p1", "Raid", 0), "the single burst token")
		-- 2 tokens/s: 0.25s restores only half a token.
		assert(limiter:allow("p1", "Raid", 0.25) == false, "half a token is not enough")
		-- Another 0.25s reaches exactly one token.
		assert(limiter:allow("p1", "Raid", 0.5), "one full token")
		assert(limiter:allow("p1", "Raid", 0.5) == false, "the refilled token was spent")
	end,

	["never refills above capacity"] = function()
		local limiter = RateLimiter.new({ Raid = { capacity = 2, refillPerSecond = 1 } })
		assert(limiter:allow("p1", "Raid", 0), "first")
		assert(limiter:allow("p1", "Raid", 0), "second")
		-- A long idle restores at most `capacity` tokens.
		assert(limiter:allow("p1", "Raid", 100), "capped token one")
		assert(limiter:allow("p1", "Raid", 100), "capped token two")
		assert(limiter:allow("p1", "Raid", 100) == false, "capacity is an upper bound")
	end,

	["isolates buckets per key"] = function()
		local limiter = RateLimiter.new({ Raid = { capacity = 1, refillPerSecond = 1 } })
		assert(limiter:allow("p1", "Raid", 0), "p1 gets its token")
		assert(limiter:allow("p2", "Raid", 0), "p2 is unaffected")
		assert(limiter:allow("p1", "Raid", 0) == false, "p1 is exhausted")
	end,

	["isolates buckets per action"] = function()
		local limiter = RateLimiter.new(CONFIG)
		for _ = 1, 5 do
			assert(limiter:allow("p1", "BuyEgg", 0), "buy burst")
		end
		assert(limiter:allow("p1", "BuyEgg", 0) == false, "buy is exhausted")
		assert(limiter:allow("p1", "Raid", 0), "raid keeps its own bucket")
	end,

	["forget drops a key's buckets"] = function()
		local limiter = RateLimiter.new({ Raid = { capacity = 1, refillPerSecond = 1 } })
		assert(limiter:allow("p1", "Raid", 0), "first")
		assert(limiter:allow("p1", "Raid", 0) == false, "exhausted")
		limiter:forget("p1")
		assert(limiter:allow("p1", "Raid", 0), "fresh bucket after forget")
	end,

	["unknown action is refused"] = function()
		local limiter = RateLimiter.new(CONFIG)
		local ok, reason = limiter:allow("p1", "DropTable", 0)
		assert(ok == false, "unknown action must be refused")
		assert(reason == "unknown action", "unexpected reason: " .. tostring(reason))
	end,
}
