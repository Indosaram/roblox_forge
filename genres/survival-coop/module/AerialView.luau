--!strict
-- Engine-free camera framing and reversible camera/UI lifecycle.
local M = {}
export type Point = { x: number, y: number, z: number }
function M.frame(minimum: Point, maximum: Point, aspect: number, fov: number, yaw: number): any
	assert(aspect > 0 and aspect < math.huge and fov > 0 and fov < 180, "INVALID_PROJECTION")
	local center = { x = (minimum.x + maximum.x) / 2, y = (minimum.y + maximum.y) / 2, z = (minimum.z + maximum.z) / 2 }
	local radius = math.sqrt((maximum.x - minimum.x) ^ 2 + (maximum.y - minimum.y) ^ 2 + (maximum.z - minimum.z) ^ 2)
		/ 2
	assert(radius > 0 and radius < math.huge, "INVALID_BOUNDS")
	local vertical = math.rad(fov) / 2
	local angle = math.min(vertical, math.atan(math.tan(vertical) * aspect))
	-- A bounding sphere makes the full island safe at every orbit angle.
	local distance = radius * 1.1 / math.sin(angle)
	return {
		focus = center,
		distance = distance,
		minDistance = distance,
		maxDistance = distance * 2,
		position = {
			x = center.x + math.sin(yaw) * distance / 2,
			y = center.y + distance * math.sqrt(3) / 2,
			z = center.z + math.cos(yaw) * distance / 2,
		},
		fieldOfView = fov,
	}
end
function M.start(port: any, minimum: Point, maximum: Point, aspect: number, fov: number): any
	local saved = port.read()
	local closed, yaw = false, 0
	local frame = M.frame(minimum, maximum, aspect, fov, yaw)
	port.apply(frame)
	return {
		orbit = function(delta: number)
			assert(not closed, "AERIAL_CLOSED")
			yaw = (yaw + delta) % (2 * math.pi)
			frame = M.frame(minimum, maximum, aspect, fov, yaw)
			port.apply(frame)
		end,
		zoom = function(distance: number)
			assert(not closed, "AERIAL_CLOSED")
			local bounded = math.clamp(distance, frame.minDistance, frame.maxDistance)
			local ratio = bounded / frame.distance
			local p, c = frame.position, frame.focus
			port.apply({
				focus = c,
				fieldOfView = fov,
				distance = bounded,
				position = {
					x = c.x + (p.x - c.x) * ratio,
					y = c.y + (p.y - c.y) * ratio,
					z = c.z + (p.z - c.z) * ratio,
				},
			})
		end,
		hideUI = function(hidden: boolean)
			assert(not closed, "AERIAL_CLOSED")
			port.hideUI(hidden)
		end,
		capture = function()
			assert(not closed, "AERIAL_CLOSED")
			return port.captureLocal()
		end,
		close = function()
			if not closed then
				closed = true
				port.restore(saved)
			end
		end,
	}
end
return M
