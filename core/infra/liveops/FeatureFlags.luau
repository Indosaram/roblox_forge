--!strict

export type FlagConfig = boolean | { rollout: number }
export type FlagDefaults = { [string]: FlagConfig }

local BUCKET_MODULUS = 100

local FeatureFlags = {}
FeatureFlags.__index = FeatureFlags

export type FeatureFlags = typeof(setmetatable(
	{} :: {
		defaults: { [string]: boolean },
		rollouts: { [string]: number },
		overrides: { [string]: boolean },
	},
	FeatureFlags
))

function FeatureFlags.new(defaults: FlagDefaults): FeatureFlags
	local booleans: { [string]: boolean } = {}
	local rollouts: { [string]: number } = {}
	for name, config in defaults do
		if type(config) == "boolean" then
			booleans[name] = config
		else
			rollouts[name] = config.rollout
		end
	end
	return setmetatable({
		defaults = booleans,
		rollouts = rollouts,
		overrides = {},
	}, FeatureFlags)
end

function FeatureFlags.override(self: FeatureFlags, name: string, value: boolean)
	self.overrides[name] = value
end

-- Buckets a userId into [0, 99] using exact 32-bit integer arithmetic. Real
-- Roblox UserIds are at or above ~1e8; multiplying them directly as a plain
-- double (as the old `userId * HASH_MULTIPLIER` did) overflows the 53-bit
-- mantissa and silently loses low bits, collapsing the reachable bucket
-- range. Splitting userId into 16-bit halves keeps every intermediate
-- product under 2^32 (well under 2^53), and a xorshift-multiply finisher
-- mixes those bits so consecutive ids still spread evenly across buckets.
-- The finisher's own multiply (`hash * 0x2545F491`) is done the same way,
-- as a 16-bit-limb long multiplication reduced mod 2^32 (`mulMod32`), so
-- that step never depends on a >2^53 double product rounding correctly.
local function mulMod32(a: number, b: number): number
	local aHi = bit32.rshift(a, 16)
	local aLo = bit32.band(a, 0xFFFF)
	local bHi = bit32.rshift(b, 16)
	local bLo = bit32.band(b, 0xFFFF)
	-- Each partial product below is under 2^32; their sum (`cross`) is under
	-- 2^33, still far inside the 53-bit mantissa, so it is exact as a double.
	local cross = aHi * bLo + aLo * bHi
	local lowPart = aLo * bLo
	local crossShifted = bit32.band(cross, 0xFFFF) * 65536
	return bit32.band(crossShifted + lowPart, 0xFFFFFFFF)
end

local function hashBucket(userId: number): number
	local lo = bit32.band(userId, 0xFFFF)
	local hi = bit32.band(bit32.rshift(userId, 16), 0xFFFF)
	local p1 = lo * 0x9E37
	local p2 = lo * 0x79B9
	local p3 = hi * 0x9E37
	local hash = bit32.band(p1, 0xFFFFFFFF)
	hash = bit32.bxor(hash, bit32.band(bit32.lshift(p2, 16), 0xFFFFFFFF))
	hash = bit32.bxor(hash, bit32.band(bit32.lshift(p3, 16), 0xFFFFFFFF))
	hash = bit32.bxor(hash, bit32.rshift(hash, 15))
	hash = mulMod32(hash, 0x2545F491)
	hash = bit32.bxor(hash, bit32.rshift(hash, 13))
	return hash % BUCKET_MODULUS
end

function FeatureFlags.isEnabled(self: FeatureFlags, name: string, userId: number): boolean
	local override = self.overrides[name]
	if override ~= nil then
		return override
	end

	local rollout = self.rollouts[name]
	if rollout ~= nil then
		local bucket = hashBucket(userId)
		return bucket < rollout
	end

	return self.defaults[name] or false
end

return FeatureFlags
