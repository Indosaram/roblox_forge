--!strict
-- SurvivalCoop: wave scheduling and defense resolution for survival-coop games.

export type Config = {
	waveInterval: number,
	baseEnemies: number,
	growth: number,
}

export type Wave = {
	index: number,
	enemies: number,
}

export type Resolution = {
	index: number,
	enemies: number,
	defensePower: number,
	won: boolean,
}

export type Hooks = {
	OnWaveSpawn: ((wave: Wave) -> ())?,
	OnWaveResolved: ((resolution: Resolution) -> ())?,
}

local SurvivalCoop = {}
SurvivalCoop.__index = SurvivalCoop

export type SurvivalCoop = typeof(setmetatable(
	{} :: {
		_config: Config,
		_hooks: Hooks,
		_nextAt: number?,
		_wavesSpawned: number,
	},
	SurvivalCoop
))

function SurvivalCoop.new(config: Config, hooks: Hooks?): SurvivalCoop
	return setmetatable({
		_config = config,
		_hooks = hooks or {},
		_nextAt = nil,
		_wavesSpawned = 0,
	}, SurvivalCoop)
end

-- Wave N fields baseEnemies + (N - 1) * growth enemies: a linear ramp per wave.
function SurvivalCoop.enemiesFor(self: SurvivalCoop, index: number): number
	return self._config.baseEnemies + (index - 1) * self._config.growth
end

function SurvivalCoop.waveIndex(self: SurvivalCoop): number
	return self._wavesSpawned
end

function SurvivalCoop.nextWaveAt(self: SurvivalCoop): number?
	return self._nextAt
end

function SurvivalCoop.secondsUntilNext(self: SurvivalCoop, now: number): number
	if self._nextAt == nil then
		return 0
	end
	return math.max(0, self._nextAt - now)
end

-- The first call arms the schedule; later calls spawn a wave at or after nextWaveAt.
function SurvivalCoop.tick(self: SurvivalCoop, now: number): Wave?
	if self._nextAt == nil then
		self._nextAt = now + self._config.waveInterval
		return nil
	end
	if now < self._nextAt then
		return nil
	end
	local index = self._wavesSpawned + 1
	self._wavesSpawned = index
	self._nextAt = now + self._config.waveInterval
	local wave = { index = index, enemies = SurvivalCoop.enemiesFor(self, index) }
	local onWaveSpawn = self._hooks.OnWaveSpawn
	if onWaveSpawn ~= nil then
		onWaveSpawn(wave)
	end
	return wave
end

function SurvivalCoop.defend(self: SurvivalCoop, waveIndex: number, defensePower: number): boolean
	local enemies = SurvivalCoop.enemiesFor(self, waveIndex)
	local won = defensePower >= enemies
	local onWaveResolved = self._hooks.OnWaveResolved
	if onWaveResolved ~= nil then
		onWaveResolved({
			index = waveIndex,
			enemies = enemies,
			defensePower = defensePower,
			won = won,
		})
	end
	return won
end

-- Brings the next wave forward to `now`; used by Studio-only debug tooling.
function SurvivalCoop.forceNext(self: SurvivalCoop, now: number): Wave?
	if self._nextAt ~= nil then
		self._nextAt = math.min(self._nextAt, now)
	end
	return SurvivalCoop.tick(self, now)
end

return SurvivalCoop
