--!strict
-- Explicit-clock server combat. The owner publishes returned candidates in its
-- fenced transaction; positions, LOS, equipment and defense are server facts.
local M = {}
export type Point = { x: number, y: number, z: number }
export type Defense = {
	dodgeStart: number?,
	dodgeEnd: number?,
	guardStart: number?,
	guardEnd: number?,
	guardPermille: number,
	armorPermille: number,
	stancePermille: number,
}
export type Attack = {
	id: string,
	target: string,
	mode: string,
	origin: Point,
	direction: Point,
	resolveAt: number,
	recoveryUntil: number,
	range: number,
	facingDot: number,
	damageMilli: number,
	resolved: boolean,
}
export type Rule = {
	mode: string,
	windupMillis: number,
	recoveryMillis: number,
	range: number,
	facingDot: number,
	damageMilli: number,
	ammo: number,
}
local function integer(value: number, low: number, high: number): boolean
	return value == value and value % 1 == 0 and value >= low and value <= high
end
local function point(value: Point): boolean
	return value.x == value.x
		and math.abs(value.x) < math.huge
		and value.y == value.y
		and math.abs(value.y) < math.huge
		and value.z == value.z
		and math.abs(value.z) < math.huge
end
function M.defense(): Defense
	return { guardPermille = 1000, armorPermille = 1000, stancePermille = 1000 }
end
function M.window(state: Defense, action: string, now: number, duration: number): Defense
	assert(integer(now, 0, 2 ^ 53 - 1) and integer(duration, 1, 86400000), "INVALID_WINDOW")
	assert(action == "dodge" or action == "guard", "INVALID_DEFENSE")
	local nextState = table.clone(state)
	if action == "dodge" then
		nextState.dodgeStart, nextState.dodgeEnd = now, now + duration
	else
		nextState.guardStart, nextState.guardEnd = now, now + duration
	end
	return nextState
end
function M.begin(
	id: string,
	target: string,
	rule: Rule,
	now: number,
	readyAt: number,
	origin: Point,
	direction: Point,
	ammunition: number,
	mounted: boolean
): (Attack?, number, string?)
	assert(integer(now, 0, 2 ^ 53 - 1) and integer(readyAt, 0, 2 ^ 53 - 1), "INVALID_CLOCK")
	assert(integer(rule.windupMillis, 1, 86400000) and integer(rule.recoveryMillis, 1, 86400000), "INVALID_TIMING")
	assert(integer(rule.damageMilli, 0, 2 ^ 31) and rule.range > 0 and rule.range < math.huge, "INVALID_ATTACK")
	assert(rule.facingDot >= -1 and rule.facingDot <= 1 and point(origin) and point(direction), "INVALID_SHAPE")
	assert(rule.mode == "melee" or rule.mode == "ranged", "INVALID_MODE")
	assert(integer(rule.ammo, 0, 1000) and integer(ammunition, 0, 2 ^ 31), "INVALID_MATERIALS")
	if mounted then
		return nil, ammunition, "MOUNTED"
	end
	if now < readyAt then
		return nil, ammunition, "RECOVERY"
	end
	if ammunition < rule.ammo then
		return nil, ammunition, "NO_AMMO"
	end
	if direction.x ^ 2 + direction.y ^ 2 + direction.z ^ 2 == 0 then
		return nil, ammunition, "NO_DIRECTION"
	end
	local attack: Attack = {
		id = id,
		target = target,
		mode = rule.mode,
		origin = table.clone(origin),
		direction = table.clone(direction),
		resolveAt = now + rule.windupMillis,
		recoveryUntil = now + rule.windupMillis + rule.recoveryMillis,
		range = rule.range,
		facingDot = rule.facingDot,
		damageMilli = rule.damageMilli,
		resolved = false,
	}
	return attack, ammunition - rule.ammo, nil
end
function M.resolve(
	attack: Attack,
	now: number,
	target: string,
	position: Point,
	lineOfSight: boolean,
	defense: Defense
): (Attack, number, string)
	assert(integer(now, 0, 2 ^ 53 - 1) and point(position), "INVALID_CLOCK_OR_POSITION")
	local nextAttack = table.clone(attack)
	if attack.resolved then
		return nextAttack, 0, "REPLAY"
	end
	if now < attack.resolveAt then
		return nextAttack, 0, "WINDUP"
	end
	nextAttack.resolved = true
	local dx, dy, dz = position.x - attack.origin.x, position.y - attack.origin.y, position.z - attack.origin.z
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	local direction = attack.direction
	local length = math.sqrt(direction.x ^ 2 + direction.y ^ 2 + direction.z ^ 2)
	local dot = if distance == 0
		then 1
		else (dx * direction.x + dy * direction.y + dz * direction.z) / distance / length
	if target ~= attack.target or not lineOfSight or distance > attack.range or dot < attack.facingDot then
		return nextAttack, 0, "MISS"
	end
	-- Evaluate at the authoritative strike time, never at a delayed update time.
	local strike = attack.resolveAt
	if defense.dodgeStart and defense.dodgeEnd and strike >= defense.dodgeStart and strike < defense.dodgeEnd then
		return nextAttack, 0, "DODGE"
	end
	for _, scale in { defense.guardPermille, defense.armorPermille, defense.stancePermille } do
		assert(integer(scale, 0, 2000), "INVALID_MITIGATION")
	end
	local guarded = defense.guardStart ~= nil
		and defense.guardEnd ~= nil
		and strike >= (defense.guardStart :: number)
		and strike < (defense.guardEnd :: number)
	local damage = attack.damageMilli
	if guarded then
		damage = damage * defense.guardPermille // 1000
	end
	damage = damage * defense.armorPermille // 1000
	damage = damage * defense.stancePermille // 1000
	return nextAttack, damage, if guarded then "GUARD" else "HIT"
end
return M
