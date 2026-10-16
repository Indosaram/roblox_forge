--!strict
-- Pure fixed-point rules. Callers own the authoritative clock, catalog lookup,
-- inventory transaction, reachable-fire query, and death inventory transfer.
local Exposure = require("./Exposure")
local M = {}

-- The four base fields are always present. Three optional groups switch on
-- extra gauges, and each group is all-or-nothing so a half-configured gauge
-- can never exist:
--   exposure: exposureRiseTier1..3MilliPerSecond, exposureRecoverMilliPerSecond,
--             exposureDamageMillisPerUnit (climate gauge; tier 0 never rises)
--   stamina:  staminaRegenMilliPerSecond, staminaCostMilliPerAction
--   respawn:  respawnDelayMillis
-- State fields for a group exist only when its config exists, so saves written
-- before a group was configured keep loading unchanged.
export type Config = {
	hungerMillisPerUnit: number,
	fatigueMilliPerAction: number,
	restMilliPerSecond: number,
	starvationMillisPerUnit: number,
	exposureRiseTier1MilliPerSecond: number?,
	exposureRiseTier2MilliPerSecond: number?,
	exposureRiseTier3MilliPerSecond: number?,
	exposureRecoverMilliPerSecond: number?,
	exposureDamageMillisPerUnit: number?,
	staminaRegenMilliPerSecond: number?,
	staminaCostMilliPerAction: number?,
	respawnDelayMillis: number?,
}
export type State = {
	healthMilli: number,
	hungerMilli: number,
	fatigueMilli: number,
	hungerRemainder: number,
	starvationRemainder: number,
	restRemainder: number,
	exposureMilli: number?,
	exposureRemainder: number?,
	exposureDrainRemainder: number?,
	exposureTier: number?,
	resistanceMilli: number?,
	staminaMilli: number?,
	staminaRemainder: number?,
	respawnWaitMillis: number?,
	clockMillis: number,
	activeMillis: number,
	combatUntilMillis: number,
	online: boolean,
	resting: boolean,
	config: Config,
}

local MAX = 100000
local function integer(value: any, maximum: number): boolean
	return type(value) == "number" and value == value and value >= 0 and value <= maximum and value % 1 == 0
end

M.EXPOSURE_FIELDS = {
	"exposureRiseTier1MilliPerSecond",
	"exposureRiseTier2MilliPerSecond",
	"exposureRiseTier3MilliPerSecond",
	"exposureRecoverMilliPerSecond",
	"exposureDamageMillisPerUnit",
}
M.STAMINA_FIELDS = { "staminaRegenMilliPerSecond", "staminaCostMilliPerAction" }
M.RESPAWN_FIELDS = { "respawnDelayMillis" }

-- Presence of each group, as one of: absent, complete, or an invalid partial.
local function group(c: any, fields: { string }): boolean
	local present = 0
	for _, field in fields do
		if c[field] ~= nil then
			present += 1
		end
	end
	assert(present == 0 or present == #fields, "incomplete vitals config group")
	return present > 0
end

local function clock(millis: number): number
	assert(integer(millis, 2 ^ 53 - 1 - 10000), "invalid clock milliseconds")
	return millis
end

function M.new(nowMillis: number, config: Config?): State
	local c = table.clone(config or {
		hungerMillisPerUnit = 18000,
		fatigueMilliPerAction = 500,
		restMilliPerSecond = 2000,
		starvationMillisPerUnit = 5000,
	})
	assert(integer(c.hungerMillisPerUnit, 86400000) and c.hungerMillisPerUnit > 0, "invalid hunger period")
	assert(integer(c.starvationMillisPerUnit, 86400000) and c.starvationMillisPerUnit > 0, "invalid starvation period")
	assert(integer(c.fatigueMilliPerAction, MAX), "invalid action cost")
	assert(integer(c.restMilliPerSecond, MAX), "invalid rest rate")
	local exposed = group(c, M.EXPOSURE_FIELDS)
	local staminaOn = group(c, M.STAMINA_FIELDS)
	local delayed = group(c, M.RESPAWN_FIELDS)
	if exposed then
		for _, field in
			{
				"exposureRiseTier1MilliPerSecond",
				"exposureRiseTier2MilliPerSecond",
				"exposureRiseTier3MilliPerSecond",
				"exposureRecoverMilliPerSecond",
			}
		do
			assert(integer(c[field], MAX * 1000), "invalid exposure rate")
		end
		assert(
			integer(c.exposureDamageMillisPerUnit, 86400000) and c.exposureDamageMillisPerUnit > 0,
			"invalid exposure damage period"
		)
	end
	if staminaOn then
		assert(integer(c.staminaRegenMilliPerSecond, MAX * 1000), "invalid stamina regen")
		assert(integer(c.staminaCostMilliPerAction, MAX), "invalid stamina cost")
	end
	if delayed then
		assert(integer(c.respawnDelayMillis, 86400000), "invalid respawn delay")
	end
	local now = clock(nowMillis)
	return {
		healthMilli = MAX,
		hungerMilli = MAX,
		fatigueMilli = 0,
		hungerRemainder = 0,
		starvationRemainder = 0,
		restRemainder = 0,
		exposureMilli = if exposed then 0 else nil,
		exposureRemainder = if exposed then 0 else nil,
		exposureDrainRemainder = if exposed then 0 else nil,
		exposureTier = if exposed then 0 else nil,
		resistanceMilli = if exposed then 0 else nil,
		staminaMilli = if staminaOn then MAX else nil,
		staminaRemainder = if staminaOn then 0 else nil,
		respawnWaitMillis = if delayed then 0 else nil,
		clockMillis = now,
		activeMillis = 0,
		combatUntilMillis = now + 10000,
		online = true,
		resting = false,
		config = table.freeze(c),
	}
end

local function exposureRate(s: State): number
	local c = s.config
	return Exposure.rate({
		c.exposureRiseTier1MilliPerSecond :: number,
		c.exposureRiseTier2MilliPerSecond :: number,
		c.exposureRiseTier3MilliPerSecond :: number,
	}, c.exposureRecoverMilliPerSecond :: number, s.exposureTier :: number, s.resistanceMilli :: number, s.resting)
end

function M.advance(state: State, nowMillis: number): State
	local now = clock(nowMillis)
	assert(now >= state.clockMillis, "clock must be monotonic")
	local s = table.clone(state)
	local dt = now - s.clockMillis
	s.clockMillis = now
	if not s.online then
		s.combatUntilMillis += dt
		return s
	end
	s.activeMillis += dt
	if s.healthMilli == 0 then
		if s.respawnWaitMillis ~= nil then
			s.respawnWaitMillis = math.max(0, s.respawnWaitMillis - dt)
		end
		return s
	end
	local c = s.config
	local exposed = s.exposureMilli ~= nil
	-- Exposure drain starts when the gauge reads full while it is still rising
	-- (a recovering or warm actor never drains) and blocks regeneration.
	local rate = if exposed then exposureRate(s) else 0
	local drainFrom = math.huge
	if rate > 0 then
		drainFrom = Exposure.timeToFull(s.exposureMilli :: number, s.exposureRemainder :: number, rate)
	end
	local hungerBefore = s.hungerMilli
	local zeroAt = math.max(0, math.ceil((hungerBefore * c.hungerMillisPerUnit - s.hungerRemainder) / 1000))
	local starveTime = math.max(0, dt - zeroAt)
	-- Regeneration precedes starvation in this interval; eligibility ends at
	-- the exact hunger threshold, independently of heartbeat chunking.
	local belowThirtyAt =
		math.max(0, math.ceil(((hungerBefore - 30000 + 1) * c.hungerMillisPerUnit - state.hungerRemainder) / 1000))
	local regenStart = math.max(0, state.combatUntilMillis - state.clockMillis)
	local regenTime = math.max(0, math.min(dt, belowThirtyAt, drainFrom) - regenStart)
	s.healthMilli = math.min(MAX, s.healthMilli + regenTime)
	-- Stop all live simulation at the exact millisecond of death, including rest.
	local liveTime: number
	local drainTime = 0
	if not exposed then
		local deathAfter = math.ceil((s.healthMilli * c.starvationMillisPerUnit - s.starvationRemainder) / 1000)
		liveTime = math.min(dt, zeroAt + deathAfter)
		starveTime = math.min(starveTime, deathAfter)
	else
		local starvePeriod = c.starvationMillisPerUnit
		local drainPeriod = c.exposureDamageMillisPerUnit :: number
		local function loss(t: number): number
			return math.floor((s.starvationRemainder + math.max(0, t - zeroAt) * 1000) / starvePeriod)
				+ math.floor(((s.exposureDrainRemainder :: number) + math.max(0, t - drainFrom) * 1000) / drainPeriod)
		end
		liveTime = dt
		if loss(dt) >= s.healthMilli then
			-- Both drains are monotone in time: bisect the first fatal millisecond.
			local low, high = 0, dt
			while low < high do
				local mid = (low + high) // 2
				if loss(mid) >= s.healthMilli then
					high = mid
				else
					low = mid + 1
				end
			end
			liveTime = low
		end
		starveTime = math.max(0, liveTime - zeroAt)
		drainTime = math.max(0, liveTime - drainFrom)
	end
	local hungerTotal = s.hungerRemainder + liveTime * 1000
	s.hungerMilli = math.max(0, hungerBefore - math.floor(hungerTotal / c.hungerMillisPerUnit))
	s.hungerRemainder = if s.hungerMilli == 0 then 0 else hungerTotal % c.hungerMillisPerUnit
	local starved = if starveTime > 0 then s.starvationRemainder + starveTime * 1000 else 0
	local drained = if drainTime > 0 then (s.exposureDrainRemainder :: number) + drainTime * 1000 else 0
	local lost = 0
	if starveTime > 0 then
		lost += math.floor(starved / c.starvationMillisPerUnit)
	end
	if drainTime > 0 then
		lost += math.floor(drained / (c.exposureDamageMillisPerUnit :: number))
	end
	if lost > 0 or starveTime > 0 or drainTime > 0 then
		s.healthMilli = math.max(0, s.healthMilli - lost)
		if starveTime > 0 then
			s.starvationRemainder = if s.healthMilli == 0 then 0 else starved % c.starvationMillisPerUnit
		end
		if drainTime > 0 then
			s.exposureDrainRemainder = if s.healthMilli == 0
				then 0
				else drained % (c.exposureDamageMillisPerUnit :: number)
		end
	end
	if exposed then
		s.exposureMilli, s.exposureRemainder =
			Exposure.step(s.exposureMilli :: number, s.exposureRemainder :: number, rate, liveTime)
		if (s.exposureMilli :: number) < MAX then
			s.exposureDrainRemainder = 0
		end
	end
	if s.staminaMilli ~= nil then
		s.staminaMilli, s.staminaRemainder = Exposure.step(
			s.staminaMilli,
			s.staminaRemainder :: number,
			c.staminaRegenMilliPerSecond :: number,
			liveTime
		)
	end
	if s.resting then
		local total = s.restRemainder + liveTime * c.restMilliPerSecond
		s.fatigueMilli = math.max(0, s.fatigueMilli - math.floor(total / 1000))
		s.restRemainder = if s.fatigueMilli == 0 then 0 else total % 1000
	end
	if s.healthMilli == 0 then
		s.resting = false
		if s.respawnWaitMillis ~= nil then
			s.respawnWaitMillis = math.max(0, (c.respawnDelayMillis :: number) - (dt - liveTime))
		end
	end
	return s
end

function M.disconnect(state: State, nowMillis: number): State
	local s = M.advance(state, nowMillis)
	s.online = false
	s.resting = false
	return s
end

function M.reconnect(state: State, nowMillis: number): State
	assert(not state.online, "already online")
	local s = M.advance(state, nowMillis)
	s.online = true
	return s
end

local function alive(state: State)
	assert(state.online and state.healthMilli > 0, "actor is not alive and online")
end

function M.action(state: State): State
	alive(state)
	local s = table.clone(state)
	s.fatigueMilli = math.min(MAX, s.fatigueMilli + s.config.fatigueMilliPerAction)
	if s.staminaMilli ~= nil then
		-- Stamina never refuses an action: it floors at zero and slows movement.
		s.staminaMilli = math.max(0, s.staminaMilli - (s.config.staminaCostMilliPerAction :: number))
		s.staminaRemainder = 0
	end
	s.resting = false
	s.restRemainder = 0
	return s
end

--- Sets the server-observed biome tier and the clothing resistance score. The
--- caller advances first so the old tier covers the elapsed interval.
function M.setEnvironment(state: State, tier: number, resistanceMilli: number): State
	alive(state)
	assert(state.exposureMilli ~= nil, "exposure is not configured")
	assert(Exposure.validTier(tier), "invalid exposure tier")
	assert(Exposure.validResistance(resistanceMilli), "invalid resistance")
	local s = table.clone(state)
	s.exposureTier = tier
	s.resistanceMilli = resistanceMilli
	-- A changed rate starts a fresh sub-milli remainder instead of carrying a stale fraction.
	if tier ~= state.exposureTier or resistanceMilli ~= state.resistanceMilli then
		s.exposureRemainder = 0
	end
	return s
end

function M.damage(state: State, healthMilli: number): State
	alive(state)
	assert(integer(healthMilli, MAX), "invalid damage")
	local s = table.clone(state)
	s.healthMilli = math.max(0, s.healthMilli - healthMilli)
	s.combatUntilMillis = s.clockMillis + 10000
	s.resting = false
	if s.healthMilli == 0 and s.respawnWaitMillis ~= nil then
		s.respawnWaitMillis = s.config.respawnDelayMillis :: number
	end
	return s
end

function M.stopRest(state: State): State
	alive(state)
	local s = table.clone(state)
	s.resting = false
	s.restRemainder = 0
	return s
end

function M.food(state: State, effect: { hungerMilli: number, healthMilli: number, fatigueMilli: number }): State
	alive(state)
	assert(type(effect) == "table", "invalid food effect")
	for _, field in { "hungerMilli", "healthMilli", "fatigueMilli" } do
		assert(integer((effect :: any)[field], MAX), "invalid food effect")
	end
	local s = table.clone(state)
	s.hungerMilli = math.min(MAX, s.hungerMilli + effect.hungerMilli)
	s.healthMilli = math.min(MAX, s.healthMilli + effect.healthMilli)
	s.fatigueMilli = math.max(0, s.fatigueMilli - effect.fatigueMilli)
	if s.hungerMilli > 0 then
		s.starvationRemainder = 0
	end
	if s.hungerMilli == MAX then
		s.hungerRemainder = 0
	end
	if s.fatigueMilli == 0 then
		s.restRemainder = 0
	end
	return s
end

function M.rest(state: State, port: { campfireId: string, reachable: boolean }): State
	alive(state)
	assert(
		type(port) == "table" and type(port.campfireId) == "string" and #port.campfireId > 0 and #port.campfireId <= 64,
		"invalid campfire"
	)
	assert(port.reachable == true, "campfire is unreachable")
	local s = table.clone(state)
	s.resting = true
	return s
end

function M.exhausted(state: State): boolean
	return state.staminaMilli ~= nil and state.staminaMilli == 0
end

function M.movementMilli(state: State): number
	return if state.fatigueMilli >= 80000 or M.exhausted(state) then 800 else 1000
end

--- Milliseconds of online time left before a dead actor may respawn. Always 0
--- when no respawn delay is configured.
function M.respawnWait(state: State): number
	assert(state.healthMilli == 0, "actor is not dead")
	return state.respawnWaitMillis or 0
end

-- The prior policy does not prescribe respawn vital values; the server supplies them.
function M.respawn(state: State, values: { healthMilli: number, hungerMilli: number, fatigueMilli: number }): State
	assert(state.online and state.healthMilli == 0, "actor is not dead and online")
	assert(type(values) == "table", "invalid respawn values")
	for _, field in { "healthMilli", "hungerMilli", "fatigueMilli" } do
		assert(integer((values :: any)[field], MAX), "invalid respawn values")
	end
	assert(values.healthMilli > 0, "respawn must restore health")
	assert((state.respawnWaitMillis or 0) == 0, "respawn delay has not elapsed")
	local s = table.clone(state)
	s.healthMilli = values.healthMilli
	s.hungerMilli = values.hungerMilli
	s.fatigueMilli = values.fatigueMilli
	s.hungerRemainder = 0
	s.starvationRemainder = 0
	s.restRemainder = 0
	if s.exposureMilli ~= nil then
		s.exposureMilli, s.exposureRemainder, s.exposureDrainRemainder = 0, 0, 0
	end
	if s.staminaMilli ~= nil then
		s.staminaMilli, s.staminaRemainder = MAX, 0
	end
	s.resting = false
	s.combatUntilMillis = s.clockMillis + 10000
	return s
end

export type Zone = "safe" | "danger"

--- `zone` selects the death rule. nil keeps the legacy newcomer-threshold rule.
--- "safe": the whole inventory is kept and only the respawn wait applies.
--- "danger" (opt-in): the carried-in items drop through DeathBundle, with no
--- newcomer protection because entering the zone was the player's choice.
function M.deathPolicy(
	state: State,
	zone: Zone?
): {
	keepEquipped: boolean,
	dropBag: boolean,
	ownerOnlyMillis: number,
	destination: string,
	respawnWaitMillis: number,
}
	assert(state.healthMilli == 0, "actor is not dead")
	assert(zone == nil or zone == "safe" or zone == "danger", "invalid death zone")
	local drop = if zone == nil then state.activeMillis >= 1800000 else zone == "danger"
	return {
		keepEquipped = true,
		dropBag = drop,
		ownerOnlyMillis = 600000,
		destination = "tribe-campfire-or-island-start",
		respawnWaitMillis = state.respawnWaitMillis or 0,
	}
end

return M
