--!strict
-- Rng: seeded deterministic generator (xorshift128, state seeded by splitmix32).
-- Pure Luau on bit32 and doubles only: identical sequences in Roblox and Lune.
-- No ambient randomness and no clock: every stream is a function of its seed.

export type Rng = {
	nextU32: (self: Rng) -> number,
	nextNumber: (self: Rng) -> number,
	nextInteger: (self: Rng, min: number, max: number) -> number,
	state: (self: Rng) -> { number },
	fork: (self: Rng, label: string) -> Rng,
}

type RngImpl = Rng & { _s: { number } }

local TWO_32 = 4294967296
local TWO_53 = 9007199254740992
local MAX_SAFE_INTEGER = TWO_53 - 1

local Rng = {}
local RngMethods = {}
local RngMeta = { __index = RngMethods }

local function isInteger(value: any): boolean
	return type(value) == "number" and value == math.floor(value) and value > -math.huge and value < math.huge
end

local function isU32(value: any): boolean
	return isInteger(value) and value >= 0 and value < TWO_32
end

-- Exact 32-bit multiply: 16-bit limbs keep every intermediate below 2^53.
local function mul32(a: number, b: number): number
	local high = (bit32.rshift(a, 16) * b) % 65536
	local low = bit32.band(a, 0xFFFF) * b
	return (high * 65536 + low) % TWO_32
end

-- splitmix32 output function over an already-advanced counter.
local function mix32(counter: number): number
	local t = bit32.bxor(counter, bit32.rshift(counter, 16))
	t = mul32(t, 0x21F0AAAD)
	t = bit32.bxor(t, bit32.rshift(t, 15))
	t = mul32(t, 0x735A2D97)
	return bit32.bxor(t, bit32.rshift(t, 15))
end

local GOLDEN_GAMMA = 0x9E3779B9

-- Fill four state words from a 32-bit counter; never all zero.
local function expandState(counter: number): { number }
	local words = table.create(4, 0)
	for i = 1, 4 do
		counter = (counter + GOLDEN_GAMMA) % TWO_32
		words[i] = mix32(counter)
	end
	if words[1] == 0 and words[2] == 0 and words[3] == 0 and words[4] == 0 then
		words[1] = 1
	end
	return words
end

local function fromWords(words: { number }): Rng
	return setmetatable({ _s = words }, RngMeta) :: any
end

function Rng.new(seed: number): Rng
	if not isInteger(seed) or seed < 0 or seed > MAX_SAFE_INTEGER then
		error("invalid seed: expected a non-negative safe integer")
	end
	local low = seed % TWO_32
	local high = (seed - low) / TWO_32
	-- Absorb the high half through one mixing round so seeds that differ only
	-- above 2^32 still diverge.
	local counter = bit32.bxor(mix32((low + GOLDEN_GAMMA) % TWO_32), high)
	return fromWords(expandState(counter))
end

function Rng.fromState(state: { number }): Rng
	if type(state) ~= "table" or #state ~= 4 then
		error("invalid state: expected four u32 words")
	end
	local words = table.create(4, 0)
	local anyNonZero = false
	for i = 1, 4 do
		local word = state[i]
		if not isU32(word) then
			error("invalid state: words must be u32 integers")
		end
		words[i] = word
		if word ~= 0 then
			anyNonZero = true
		end
	end
	if not anyNonZero then
		error("invalid state: all-zero state is degenerate")
	end
	return fromWords(words)
end

function RngMethods.nextU32(self: RngImpl): number
	local s = self._s
	local x, y, z, w = s[1], s[2], s[3], s[4]
	local t = bit32.bxor(x, bit32.lshift(x, 11))
	local nw = bit32.bxor(w, bit32.rshift(w, 19), t, bit32.rshift(t, 8))
	s[1], s[2], s[3], s[4] = y, z, w, nw
	return nw
end

-- 53 random bits scaled into [0, 1); never returns 1.
function RngMethods.nextNumber(self: RngImpl): number
	local high = bit32.rshift(self:nextU32(), 5) -- 27 bits
	local low = bit32.rshift(self:nextU32(), 6) -- 26 bits
	return (high * 67108864 + low) / TWO_53
end

function RngMethods.nextInteger(self: RngImpl, min: number, max: number): number
	if
		not isInteger(min)
		or not isInteger(max)
		or math.abs(min) > MAX_SAFE_INTEGER
		or math.abs(max) > MAX_SAFE_INTEGER
	then
		error("invalid range: min and max must be safe integers")
	end
	if min > max then
		error("invalid range: min exceeds max")
	end
	local span = max - min + 1
	if span > TWO_32 then
		return min + math.floor(self:nextNumber() * span)
	end
	-- Rejection sampling removes modulo bias.
	local limit = TWO_32 - (TWO_32 % span)
	local draw = self:nextU32()
	while draw >= limit do
		draw = self:nextU32()
	end
	return min + draw % span
end

function RngMethods.state(self: RngImpl): { number }
	local s = self._s
	return { s[1], s[2], s[3], s[4] }
end

-- Derive an independent stream from (current state, label) without advancing
-- this generator. Same state and label always give the same child.
function RngMethods.fork(self: RngImpl, label: string): Rng
	if type(label) ~= "string" then
		error("invalid label: expected a string")
	end
	local hash = 2166136261 -- FNV-1a over the label bytes
	for i = 1, #label do
		hash = mul32(bit32.bxor(hash, string.byte(label, i)), 16777619)
	end
	local counter = mix32((hash + GOLDEN_GAMMA) % TWO_32)
	for i = 1, 4 do
		counter = mix32((bit32.bxor(counter, self._s[i]) + GOLDEN_GAMMA) % TWO_32)
	end
	return fromWords(expandState(counter))
end

return Rng
