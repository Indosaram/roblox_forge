--!strict
-- The world supplies a fixed position interval and a seeded world-clock origin.
-- Split movement intervals at the movement event, never project old positions.
local M = {}

local function distance(a: any, b: any): number
	return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

function M.zone(layout: any, position: any): any
	local result = { exposed = table.find(layout.biomes, "volcano") ~= nil, spring = false, lava = false }
	for _, refuge in layout.refuges do
		local b = refuge.bounds
		if
			position.x >= b.min.x
			and position.x <= b.max.x
			and position.y >= b.min.y
			and position.y <= b.max.y
			and position.z >= b.min.z
			and position.z <= b.max.z
		then
			result.exposed = false
		end
	end
	for _, path in layout.paths do
		for i = 2, #path.points do
			local a, b = path.points[i - 1], path.points[i]
			local dx, dz = b.x - a.x, b.z - a.z
			local length = dx * dx + dz * dz
			local t = if length == 0
				then 0
				else math.clamp(((position.x - a.x) * dx + (position.z - a.z) * dz) / length, 0, 1)
			if distance(position, { x = a.x + t * dx, z = a.z + t * dz }) <= path.width / 2 then
				result.exposed = false
			end
		end
	end
	for _, hazard in layout.hazards do
		if distance(position, hazard.position) <= hazard.radius then
			result.spring = result.spring or hazard.kind == "hot-spring"
			result.lava = result.lava or hazard.kind == "lava"
		end
	end
	return result
end

function M.storm(now: number, origin: number, policy: any): boolean
	return (now - origin) % (policy.clearSeconds + policy.stormSeconds) >= policy.clearSeconds
end

-- Exact integral of the square-wave weather; independent of heartbeat partition.
function M.advance(
	vitals: any,
	from: number,
	now: number,
	origin: number,
	zone: any,
	boots: boolean,
	policy: any,
	lifeMultiplier: number
): any
	assert(now >= from, "INVALID_CLOCK")
	local period = policy.clearSeconds + policy.stormSeconds
	local function storms(t: number): number
		local elapsed = t - origin
		return math.floor(elapsed / period) * policy.stormSeconds + math.max(0, elapsed % period - policy.clearSeconds)
	end
	local dt = now - from
	local exposureSeconds = dt + (storms(now) - storms(from)) * (policy.stormMultiplier - 1)
	local protection = if boots then policy.bootsMultiplier else 1
	local result: any = table.clone(vitals)
	if zone.lava then
		result.health = math.max(0, result.health - vitals.maxHealth * policy.lavaMaxHealthFraction * dt)
	end
	if zone.spring and not zone.lava then
		result.fatigue = math.max(0, result.fatigue - policy.springRecovery * dt)
	elseif zone.exposed then
		result.health = math.max(0, result.health - policy.healthPerSecond * exposureSeconds * protection)
		result.fatigue =
			math.min(100, result.fatigue + policy.fatiguePerSecond * exposureSeconds * protection * lifeMultiplier)
	end
	return result
end

return M
