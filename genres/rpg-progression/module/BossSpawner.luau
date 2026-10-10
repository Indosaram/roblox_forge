--!strict
-- BossSpawner: per-region boss schedules for rpg-progression games. Each unlocked
-- region spawns the next boss in its roster every `interval` seconds; locked
-- regions never spawn.

export type RegionSchedule = {
	region: string,
	interval: number,
	bossIds: { string },
}

export type Config = {
	regions: { RegionSchedule },
}

export type Boss = {
	id: string,
	region: string,
	spawnedAt: number,
}

export type Hooks = {
	OnBossSpawn: ((Boss) -> ())?,
	OnBossDefeated: ((Boss) -> ())?,
}

type RegionState = {
	nextAt: number?,
	cursor: number,
}

local BossSpawner = {}
BossSpawner.__index = BossSpawner

export type BossSpawner = typeof(setmetatable(
	{} :: {
		_schedules: { [string]: RegionSchedule },
		_order: { string },
		_states: { [string]: RegionState },
		_active: { [string]: Boss },
		_hooks: Hooks,
	},
	BossSpawner
))

local function checkFinite(value: number, label: string): ()
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error("invalid " .. label)
	end
end

function BossSpawner.new(config: Config, hooks: Hooks?): BossSpawner
	if type(config) ~= "table" then
		error("invalid config")
	end
	if type(config.regions) ~= "table" or #config.regions == 0 then
		error("invalid regions")
	end

	local schedules: { [string]: RegionSchedule } = {}
	local order: { string } = {}
	local states: { [string]: RegionState } = {}
	local seen: { [string]: boolean } = {}

	for _, schedule in config.regions do
		if type(schedule.region) ~= "string" or schedule.region == "" then
			error("invalid region")
		end
		if schedules[schedule.region] ~= nil then
			error("duplicate region: " .. schedule.region)
		end
		checkFinite(schedule.interval, "interval")
		if schedule.interval <= 0 then
			error("invalid interval")
		end
		if type(schedule.bossIds) ~= "table" or #schedule.bossIds == 0 then
			error("invalid bossIds")
		end
		for _, bossId in schedule.bossIds do
			if type(bossId) ~= "string" or bossId == "" then
				error("invalid boss id")
			end
			if seen[bossId] then
				error("duplicate boss id: " .. bossId)
			end
			seen[bossId] = true
		end
		schedules[schedule.region] = schedule
		states[schedule.region] = { nextAt = nil, cursor = 1 }
		table.insert(order, schedule.region)
	end

	return setmetatable({
		_schedules = schedules,
		_order = order,
		_states = states,
		_active = {},
		_hooks = hooks or {},
	}, BossSpawner)
end

-- Advances every unlocked region's schedule. The first unlocked tick only arms
-- the interval; later ticks return the ids spawned this call and fire
-- OnBossSpawn once per spawn. A locked region is skipped entirely.
function BossSpawner.tick(self: BossSpawner, now: number, isUnlocked: (string) -> boolean): { string }
	checkFinite(now, "now")
	local spawned: { string } = {}
	for _, region in self._order do
		if isUnlocked(region) then
			local schedule = self._schedules[region]
			local state = self._states[region]
			if state.nextAt == nil then
				state.nextAt = now + schedule.interval
			elseif now >= state.nextAt then
				local bossId = schedule.bossIds[state.cursor]
				state.cursor = state.cursor % #schedule.bossIds + 1
				state.nextAt = now + schedule.interval
				if self._active[bossId] == nil then
					local boss: Boss = { id = bossId, region = region, spawnedAt = now }
					self._active[bossId] = boss
					table.insert(spawned, bossId)
					local hook = self._hooks.OnBossSpawn
					if hook ~= nil then
						hook(boss)
					end
				end
			end
		end
	end
	return spawned
end

-- Removes an active boss and fires OnBossDefeated. Returns false when the boss
-- was not active.
function BossSpawner.defeat(self: BossSpawner, bossId: string): boolean
	local boss: Boss? = self._active[bossId]
	if boss == nil then
		return false
	end
	self._active[bossId] = nil
	local hook = self._hooks.OnBossDefeated
	if hook ~= nil then
		hook(boss)
	end
	return true
end

function BossSpawner.isActive(self: BossSpawner, bossId: string): boolean
	return self._active[bossId] ~= nil
end

function BossSpawner.activeCount(self: BossSpawner): number
	local count = 0
	for _ in self._active do
		count += 1
	end
	return count
end

return BossSpawner
