--!strict
-- RateLimiter: engine-free token bucket per (key, action).
-- Time is always supplied by the caller so the limiter is deterministic and
-- testable under Lune; it never reads a clock itself.

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type ActionConfig = {
	capacity: number,
	refillPerSecond: number,
}

export type Config = { [string]: ActionConfig }

type Bucket = {
	tokens: number,
	lastRefill: number,
}

export type RateLimiter = typeof(setmetatable(
	{} :: { _config: Config, _buckets: { [string]: { [string]: Bucket } } },
	RateLimiter
))

local function isPositiveFinite(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function isNonNegativeFinite(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

function RateLimiter.new(config: Config): RateLimiter
	local self = setmetatable({ _config = {}, _buckets = {} }, RateLimiter)
	for action, entry in pairs(config) do
		if type(action) ~= "string" or action == "" then
			error("invalid action")
		end
		if
			type(entry) ~= "table"
			or not isPositiveFinite(entry.capacity)
			or not isNonNegativeFinite(entry.refillPerSecond)
		then
			error("invalid action config: " .. tostring(action))
		end
		self._config[action] = { capacity = entry.capacity, refillPerSecond = entry.refillPerSecond }
	end
	return self
end

-- Consumes one token for (key, action) at `now`. Returns false plus a reason
-- when the action is unknown or the bucket is empty.
function RateLimiter.allow(self: RateLimiter, key: string, action: string, now: number): (boolean, string?)
	local config = self._config[action]
	if config == nil then
		return false, "unknown action"
	end

	local buckets = self._buckets[key]
	if buckets == nil then
		buckets = {}
		self._buckets[key] = buckets
	end

	local bucket: Bucket
	local existing = buckets[action]
	if existing ~= nil then
		bucket = existing
	else
		bucket = { tokens = config.capacity, lastRefill = now }
		buckets[action] = bucket
	end

	local elapsed = now - bucket.lastRefill
	if elapsed > 0 then
		bucket.tokens = math.min(config.capacity, bucket.tokens + elapsed * config.refillPerSecond)
		bucket.lastRefill = now
	end

	if bucket.tokens < 1 then
		return false, "rate limited: " .. action
	end
	bucket.tokens -= 1
	return true, nil
end

-- Drops every bucket for one key, for example when a player leaves.
function RateLimiter.forget(self: RateLimiter, key: string): ()
	self._buckets[key] = nil
end

return RateLimiter
