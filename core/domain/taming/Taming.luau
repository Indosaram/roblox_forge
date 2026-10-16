--!strict
-- Taming: pure capture rules for wild animals (plan SYS-099 / FAUNA-03).
--
-- A stun gauge fills from hits and decays on a caller clock (integer
-- milliseconds). Capture is refused unless the gauge is full at that instant.
-- The success roll draws from `rng:fork("capture")`, so it is a pure function
-- of the injected generator: no math.random, no os.time, no ambient clock.
-- A failed roll consumes only tool durability; the gauge stays and the animal
-- does not flee, so the attempt can be retried while it remains full.
--
-- Feed only shortens the pen time, by a fixed per-feed amount. Nothing here
-- accepts an entitlement, a Robux product or a feed on the capture path, and
-- config validation rejects unknown fields, so no paid input can reach a roll.
local M = {}

export type Config = {
	gaugeMax: number,
	fillPerHit: number,
	-- One gauge unit drains every `decayStepMillis` of caller clock.
	decayStepMillis: number,
	-- Success rate in permille (0..1000). New estimate, tunable per pack.
	successPermille: number,
	-- Tool durability consumed by every rolled attempt (milli-durability).
	toolWearMilli: number,
	-- Time a captured animal spends in the pen before it is ready.
	penMillis: number,
	-- Pen time removed per feed, by feed id.
	feedShortenMillis: { [string]: number },
}
export type Gauge = { level: number, at: number }
export type Tool = { durabilityMilli: number }
export type Pen = { startedAt: number, readyAt: number }
export type Attempt = {
	ok: boolean,
	reason: string?,
	captured: boolean,
	-- Always false: a failed capture never makes the animal flee.
	fled: boolean,
	retry: boolean,
	gauge: Gauge,
	tool: Tool,
}

local MAX_CLOCK = 2 ^ 53 - 1
local CONFIG_FIELDS = {
	"gaugeMax",
	"fillPerHit",
	"decayStepMillis",
	"successPermille",
	"toolWearMilli",
	"penMillis",
	"feedShortenMillis",
}

local function integer(n: any, low: number, high: number): boolean
	return type(n) == "number" and n == n and n % 1 == 0 and n >= low and n <= high
end

local function clock(now: any): number
	assert(integer(now, 0, MAX_CLOCK), "INVALID_CLOCK")
	return now
end

--- Validates and freezes a configuration. Unknown fields are rejected so a
--- pack can never smuggle an entitlement or Robux modifier into the rules.
function M.config(raw: Config): Config
	assert(type(raw) == "table", "INVALID_CONFIG")
	for key in raw :: any do
		assert(table.find(CONFIG_FIELDS, key) ~= nil, "UNKNOWN_CONFIG_FIELD")
	end
	assert(integer(raw.gaugeMax, 1, 1000000), "INVALID_GAUGE_MAX")
	assert(integer(raw.fillPerHit, 1, raw.gaugeMax), "INVALID_FILL")
	assert(integer(raw.decayStepMillis, 1, 86400000), "INVALID_DECAY")
	assert(integer(raw.successPermille, 0, 1000), "INVALID_SUCCESS_RATE")
	assert(integer(raw.toolWearMilli, 1, 1000000), "INVALID_TOOL_WEAR")
	assert(integer(raw.penMillis, 0, 7 * 86400000), "INVALID_PEN_TIME")
	assert(type(raw.feedShortenMillis) == "table", "INVALID_FEED")
	local feeds: { [string]: number } = {}
	for id, shorten in raw.feedShortenMillis do
		assert(type(id) == "string" and #id > 0 and #id <= 64, "INVALID_FEED_ID")
		assert(integer(shorten, 1, 7 * 86400000), "INVALID_FEED_SHORTEN")
		feeds[id] = shorten
	end
	local copy = table.clone(raw)
	copy.feedShortenMillis = table.freeze(feeds)
	return table.freeze(copy)
end

--- An empty gauge anchored at `now`.
function M.newGauge(now: number): Gauge
	return { level = 0, at = clock(now) }
end

-- Drains whole decay steps since the anchor. The anchor advances by exactly the
-- steps consumed, so partial steps are never lost however often this settles.
local function settle(config: Config, gauge: Gauge, now: number): Gauge
	assert(
		integer(gauge.level, 0, config.gaugeMax) and integer(gauge.at, 0, MAX_CLOCK) and now >= gauge.at,
		"INVALID_GAUGE"
	)
	local steps = (now - gauge.at) // config.decayStepMillis
	if steps == 0 then
		return { level = gauge.level, at = gauge.at }
	end
	local level = math.max(0, gauge.level - steps)
	return { level = level, at = if level == 0 then now else gauge.at + steps * config.decayStepMillis }
end

--- Gauge level after decay at `now`.
function M.level(config: Config, gauge: Gauge, now: number): number
	return settle(config, gauge, clock(now)).level
end

function M.isFull(config: Config, gauge: Gauge, now: number): boolean
	return settle(config, gauge, clock(now)).level >= config.gaugeMax
end

--- Applies `hits` landed hits at `now`: decay first, then fill, clamped to full.
function M.hit(config: Config, gauge: Gauge, now: number, hits: number?): Gauge
	local count = if hits == nil then 1 else hits
	assert(integer(count, 1, 1000), "INVALID_HITS")
	local settled = settle(config, gauge, clock(now))
	settled.level = math.min(config.gaugeMax, settled.level + config.fillPerHit * count)
	return settled
end

local function tool(raw: Tool): Tool
	assert(type(raw) == "table" and integer(raw.durabilityMilli, 0, 1000000000), "INVALID_TOOL")
	for key in raw :: any do
		assert(key == "durabilityMilli", "UNKNOWN_TOOL_FIELD")
	end
	return { durabilityMilli = raw.durabilityMilli }
end

--- One capture attempt. Refused (no roll, nothing consumed) while the gauge is
--- not full or the tool is broken. Otherwise the tool loses `toolWearMilli`
--- and the roll is `rng:fork("capture")` against `successPermille`. The parent
--- generator advances one word so a retry rolls a different child; replaying
--- the same seed and event order reproduces every result.
function M.capture(config: Config, gauge: Gauge, now: number, rng: any, held: Tool): Attempt
	assert(type(rng) == "table" and type(rng.fork) == "function" and type(rng.nextU32) == "function", "INVALID_RNG")
	local settled = settle(config, gauge, clock(now))
	local current = tool(held)
	if settled.level < config.gaugeMax then
		return {
			ok = false,
			reason = "GAUGE_NOT_FULL",
			captured = false,
			fled = false,
			retry = false,
			gauge = settled,
			tool = current,
		}
	end
	if current.durabilityMilli <= 0 then
		return {
			ok = false,
			reason = "TOOL_BROKEN",
			captured = false,
			fled = false,
			retry = false,
			gauge = settled,
			tool = current,
		}
	end
	local roll = rng:fork("capture")
	rng:nextU32()
	local success = roll:nextInteger(0, 999) < config.successPermille
	current.durabilityMilli = math.max(0, current.durabilityMilli - config.toolWearMilli)
	return {
		ok = true,
		reason = nil,
		captured = success,
		fled = false,
		retry = not success,
		gauge = if success then { level = 0, at = clock(now) } else settled,
		tool = current,
	}
end

--- Starts the pen timer for a freshly captured animal.
function M.pen(config: Config, now: number): Pen
	return { startedAt = clock(now), readyAt = clock(now) + config.penMillis }
end

--- Feed shortens the remaining pen time by the configured fixed amount, never
--- below `now`. No randomness: the same feed always removes the same time.
function M.feed(config: Config, pen: Pen, now: number, feedId: string): Pen
	clock(now)
	local shorten = config.feedShortenMillis[feedId]
	assert(shorten ~= nil, "UNKNOWN_FEED")
	if pen.readyAt <= now then
		return { startedAt = pen.startedAt, readyAt = pen.readyAt }
	end
	return { startedAt = pen.startedAt, readyAt = math.max(now, pen.readyAt - shorten) }
end

function M.remainingMillis(pen: Pen, now: number): number
	return math.max(0, pen.readyAt - clock(now))
end

function M.isReady(pen: Pen, now: number): boolean
	return clock(now) >= pen.readyAt
end

return M
