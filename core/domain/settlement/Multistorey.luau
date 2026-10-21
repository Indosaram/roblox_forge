--!strict
-- Grid topology. The host commits these candidates with inventory and permissions.
local M = {}
export type Policy = { floors: number, cellStuds: number, floorHeight: number, baseY: number, stairSteps: number }
export type Part = { id: string, kind: string, x: number, z: number, floor: number }
export type State = { version: number, parts: { [string]: Part } }
local function copy(state: State): State
	local out: State = { version = state.version, parts = {} }
	for id, part in state.parts do
		out.parts[id] = table.clone(part)
	end
	return out
end
local function at(state: State, kind: string, floor: number, x: number, z: number): boolean
	for _, part in state.parts do
		if part.kind == kind and part.floor == floor and part.x == x and part.z == z then
			return true
		end
	end
	return false
end
local function supported(state: State, part: Part): boolean
	if part.floor == 1 and part.kind == "floor" then
		return true
	elseif part.kind == "floor" then
		return at(state, "pillar", part.floor - 1, part.x, part.z) or at(state, "wall", part.floor - 1, part.x, part.z)
	end
	return at(state, "floor", part.floor, part.x, part.z)
end
function M.new(): State
	return { version = 0, parts = {} }
end
function M.reachable(state: State, floor: number, x: number, z: number): boolean
	local queue = {}
	local seen: { [string]: boolean } = {}
	for _, part in state.parts do
		if part.kind == "floor" and part.floor == 1 then
			table.insert(queue, part)
		end
	end
	local index = 1
	while index <= #queue do
		local part = queue[index]
		index += 1
		local key = part.floor .. ":" .. part.x .. ":" .. part.z
		if seen[key] then
			continue
		end
		seen[key] = true
		if part.floor == floor and part.x == x and part.z == z then
			return true
		end
		for _, other in state.parts do
			if other.kind ~= "floor" then
				continue
			end
			local adjacent = part.floor == other.floor and math.abs(part.x - other.x) + math.abs(part.z - other.z) == 1
			local vertical = other.floor == part.floor + 1
				and part.x == other.x
				and part.z == other.z
				and at(state, "stairs", part.floor, part.x, part.z)
			if adjacent or vertical then
				table.insert(queue, other)
			end
		end
	end
	return false
end
function M.place(state: State, policy: Policy, part: Part, version: number): (State?, string?)
	if version ~= state.version then
		return nil, "STALE_VERSION"
	elseif state.parts[part.id] then
		return nil, "DUPLICATE_ID"
	elseif
		part.floor % 1 ~= 0
		or part.floor < 1
		or part.floor > policy.floors
		or part.x % 1 ~= 0
		or part.z % 1 ~= 0
		or part.id == ""
	then
		return nil, "INVALID_PLACEMENT"
	elseif not table.find({ "floor", "pillar", "stairs", "wall", "roof", "door" }, part.kind) then
		return nil, "UNKNOWN_PART"
	elseif part.kind == "stairs" and part.floor == policy.floors then
		return nil, "TOP_FLOOR"
	end
	for _, other in state.parts do
		if other.floor == part.floor and other.x == part.x and other.z == part.z then
			local supportStair = (other.kind == "pillar" and part.kind == "stairs")
				or (other.kind == "stairs" and part.kind == "pillar")
			if other.kind == part.kind or (other.kind ~= "floor" and part.kind ~= "floor" and not supportStair) then
				return nil, "COLLISION"
			end
		end
	end
	if not supported(state, part) then
		return nil, "UNSUPPORTED"
	end
	local out = copy(state)
	out.parts[part.id] = table.clone(part)
	out.version += 1
	return out, nil
end
function M.remove(state: State, id: string, version: number): (State?, string?)
	if version ~= state.version then
		return nil, "STALE_VERSION"
	elseif not state.parts[id] then
		return nil, "UNKNOWN_PART"
	end
	local out = copy(state)
	out.parts[id] = nil
	for _, part in out.parts do
		if not supported(out, part) then
			return nil, "SUPPORT_REQUIRED"
		elseif
			part.kind == "floor"
			and M.reachable(state, part.floor, part.x, part.z)
			and not M.reachable(out, part.floor, part.x, part.z)
		then
			return nil, "STAIRS_REQUIRED"
		end
	end
	out.version += 1
	return out, nil
end
-- Collision geometry descriptors consumed by an injected renderer, including
-- low-rise stairs that a touch-controlled humanoid can walk without jumping.
function M.geometry(policy: Policy, part: Part, state: State?): { any }
	local result = {}
	local cell, height = policy.cellStuds, policy.floorHeight
	local y = policy.baseY + (part.floor - 1) * height
	if part.kind == "stairs" then
		local direction = if part.floor % 2 == 1 then 1 else -1
		for index = 1, policy.stairSteps do
			local rise = height * index / policy.stairSteps
			table.insert(result, {
				x = part.x * cell,
				y = y + rise / 2,
				z = part.z * cell + direction * cell * ((index - 0.5) / policy.stairSteps - 0.5),
				width = cell,
				height = rise,
				depth = cell / policy.stairSteps,
				canCollide = true,
			})
		end
	elseif part.kind == "floor" and state and at(state, "stairs", part.floor - 1, part.x, part.z) then
		-- Landing at the high end; the remainder is the stairwell opening.
		local direction = if part.floor % 2 == 0 then 1 else -1
		table.insert(result, {
			x = part.x * cell,
			y = y - cell / 16,
			z = part.z * cell + direction * cell * 3 / 8,
			width = cell,
			height = cell / 8,
			depth = cell / 4,
			canCollide = true,
		})
	else
		local thickness = cell / 8
		local tall = part.kind == "pillar" or part.kind == "wall" or part.kind == "door"
		table.insert(result, {
			x = part.x * cell + (if part.kind == "pillar" then cell / 2 - thickness / 2 else 0),
			y = y + (if tall then height / 2 else -thickness / 2),
			z = part.z * cell,
			width = if part.kind == "pillar" then thickness else cell,
			height = if tall then height else thickness,
			depth = if tall then thickness else cell,
			canCollide = true,
		})
	end
	return result
end
return M
