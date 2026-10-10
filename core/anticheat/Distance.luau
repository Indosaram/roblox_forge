--!strict
-- Distance: engine-free reach and movement-plausibility checks on {x, y, z} tables.

local Distance = {}

export type Vector3Like = {
	x: number,
	y: number,
	z: number,
}

local function distanceSquared(a: Vector3Like, b: Vector3Like): number
	local dx = a.x - b.x
	local dy = a.y - b.y
	local dz = a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

-- True when `b` is within `maxStuds` of `a` (boundary inclusive).
function Distance.withinReach(a: Vector3Like, b: Vector3Like, maxStuds: number): boolean
	return distanceSquared(a, b) <= maxStuds * maxStuds
end

-- True when moving from `prev` to `cur` over `dt` seconds stays within
-- `maxSpeed` studs per second. A non-positive `dt` is never plausible.
function Distance.movementPlausible(prev: Vector3Like, cur: Vector3Like, dt: number, maxSpeed: number): boolean
	if dt <= 0 or maxSpeed < 0 then
		return false
	end
	local allowed = maxSpeed * dt
	return distanceSquared(prev, cur) <= allowed * allowed
end

return Distance
