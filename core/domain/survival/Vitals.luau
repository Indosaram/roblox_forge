--!strict
-- Pure fixed-point rules. Callers own the authoritative clock, catalog lookup,
-- inventory transaction, reachable-fire query, and death inventory transfer.
local M = {}

export type Config = {
	hungerMillisPerUnit: number,
	fatigueMilliPerAction: number,
	restMilliPerSecond: number,
	starvationMillisPerUnit: number,
}
export type State = {
	healthMilli: number,
	hungerMilli: number,
	fatigueMilli: number,
	hungerRemainder: number,
	starvationRemainder: number,
	restRemainder: number,
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
	local now = clock(nowMillis)
	return {
		healthMilli = MAX,
		hungerMilli = MAX,
		fatigueMilli = 0,
		hungerRemainder = 0,
		starvationRemainder = 0,
		restRemainder = 0,
		clockMillis = now,
		activeMillis = 0,
		combatUntilMillis = now + 10000,
		online = true,
		resting = false,
		config = table.freeze(c),
	}
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
		return s
	end
	local c = s.config
	local hungerBefore = s.hungerMilli
	local zeroAt = math.max(0, math.ceil((hungerBefore * c.hungerMillisPerUnit - s.hungerRemainder) / 1000))
	local starveTime = math.max(0, dt - zeroAt)
	-- Regeneration precedes starvation in this interval; eligibility ends at
	-- the exact hunger threshold, independently of heartbeat chunking.
	local belowThirtyAt =
		math.max(0, math.ceil(((hungerBefore - 30000 + 1) * c.hungerMillisPerUnit - state.hungerRemainder) / 1000))
	local regenStart = math.max(0, state.combatUntilMillis - state.clockMillis)
	local regenTime = math.max(0, math.min(dt, belowThirtyAt) - regenStart)
	s.healthMilli = math.min(MAX, s.healthMilli + regenTime)
	-- Stop all live simulation at the exact millisecond of death, including rest.
	local deathAfter = math.ceil((s.healthMilli * c.starvationMillisPerUnit - s.starvationRemainder) / 1000)
	local liveTime = math.min(dt, zeroAt + deathAfter)
	starveTime = math.min(starveTime, deathAfter)
	local hungerTotal = s.hungerRemainder + liveTime * 1000
	s.hungerMilli = math.max(0, hungerBefore - math.floor(hungerTotal / c.hungerMillisPerUnit))
	s.hungerRemainder = if s.hungerMilli == 0 then 0 else hungerTotal % c.hungerMillisPerUnit
	if starveTime > 0 then
		local total = s.starvationRemainder + starveTime * 1000
		s.healthMilli = math.max(0, s.healthMilli - math.floor(total / c.starvationMillisPerUnit))
		s.starvationRemainder = if s.healthMilli == 0 then 0 else total % c.starvationMillisPerUnit
	end
	if s.resting then
		local total = s.restRemainder + liveTime * c.restMilliPerSecond
		s.fatigueMilli = math.max(0, s.fatigueMilli - math.floor(total / 1000))
		s.restRemainder = if s.fatigueMilli == 0 then 0 else total % 1000
	end
	if s.healthMilli == 0 then
		s.resting = false
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
	s.resting = false
	s.restRemainder = 0
	return s
end

function M.damage(state: State, healthMilli: number): State
	alive(state)
	assert(integer(healthMilli, MAX), "invalid damage")
	local s = table.clone(state)
	s.healthMilli = math.max(0, s.healthMilli - healthMilli)
	s.combatUntilMillis = s.clockMillis + 10000
	s.resting = false
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

function M.movementMilli(state: State): number
	return if state.fatigueMilli >= 80000 then 800 else 1000
end

-- The prior policy does not prescribe respawn vital values; the server supplies them.
function M.respawn(state: State, values: { healthMilli: number, hungerMilli: number, fatigueMilli: number }): State
	assert(state.online and state.healthMilli == 0, "actor is not dead and online")
	assert(type(values) == "table", "invalid respawn values")
	for _, field in { "healthMilli", "hungerMilli", "fatigueMilli" } do
		assert(integer((values :: any)[field], MAX), "invalid respawn values")
	end
	assert(values.healthMilli > 0, "respawn must restore health")
	local s = table.clone(state)
	s.healthMilli = values.healthMilli
	s.hungerMilli = values.hungerMilli
	s.fatigueMilli = values.fatigueMilli
	s.hungerRemainder = 0
	s.starvationRemainder = 0
	s.restRemainder = 0
	s.resting = false
	s.combatUntilMillis = s.clockMillis + 10000
	return s
end

function M.deathPolicy(
	state: State
): { keepEquipped: boolean, dropBag: boolean, ownerOnlyMillis: number, destination: string }
	assert(state.healthMilli == 0, "actor is not dead")
	return {
		keepEquipped = true,
		dropBag = state.activeMillis >= 1800000,
		ownerOnlyMillis = 600000,
		destination = "tribe-campfire-or-island-start",
	}
end

return M
