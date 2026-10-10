--!strict
-- Stats: xp curve, level lookup, and stat-point accrual for rpg-progression games.
-- xpForLevel(level) = base * level ^ exp is the xp needed to advance from `level`
-- to `level + 1`; a fresh state starts at level 1 with 0 xp.

export type Config = {
	base: number,
	exp: number,
	pointsPerLevel: number,
}

export type State = {
	config: Config,
	level: number,
	xp: number,
	points: number,
}

local Stats = {}

local function checkFinite(value: number, label: string): ()
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error("invalid " .. label)
	end
end

local function checkLevel(level: number): ()
	checkFinite(level, "level")
	if level < 1 or level % 1 ~= 0 then
		error("invalid level")
	end
end

local function checkConfig(config: Config): ()
	if type(config) ~= "table" then
		error("invalid config")
	end
	checkFinite(config.base, "base")
	checkFinite(config.exp, "exp")
	checkFinite(config.pointsPerLevel, "pointsPerLevel")
	if config.base <= 0 then
		error("invalid base")
	end
	if config.exp <= 0 then
		error("invalid exp")
	end
	if config.pointsPerLevel < 0 or config.pointsPerLevel % 1 ~= 0 then
		error("invalid pointsPerLevel")
	end
end

-- Xp required to advance from `level` to `level + 1`.
function Stats.xpForLevel(config: Config, level: number): number
	checkLevel(level)
	return config.base * level ^ config.exp
end

-- Highest level reachable with `totalXp` accumulated from level 1.
function Stats.levelForXp(config: Config, totalXp: number): number
	checkConfig(config)
	checkFinite(totalXp, "totalXp")
	if totalXp < 0 then
		error("invalid totalXp")
	end
	local level = 1
	local remaining = totalXp
	while remaining >= Stats.xpForLevel(config, level) do
		remaining -= Stats.xpForLevel(config, level)
		level += 1
	end
	return level
end

function Stats.new(config: Config, level: number?): State
	checkConfig(config)
	local startLevel = level or 1
	checkLevel(startLevel)
	return { config = config, level = startLevel, xp = 0, points = 0 }
end

-- Adds xp, consuming whole levels. Returns the resulting level and how many
-- levels were gained; each gained level grants `pointsPerLevel` stat points.
function Stats.addXp(state: State, amount: number): (number, number)
	checkFinite(amount, "amount")
	if amount < 0 then
		error("invalid amount")
	end
	local config = state.config
	state.xp += amount
	local gained = 0
	while state.xp >= Stats.xpForLevel(config, state.level) do
		state.xp -= Stats.xpForLevel(config, state.level)
		state.level += 1
		state.points += config.pointsPerLevel
		gained += 1
	end
	return state.level, gained
end

return Stats
