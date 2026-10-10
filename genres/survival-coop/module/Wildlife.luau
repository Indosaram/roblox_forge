--!strict
-- Copy-on-write encounter rules. The owning command transaction publishes combat
-- candidates, including inventory wear and the one death/drop entitlement together.
local Content = require("../../../core/domain/survival/Content")
local Inventory = require("../../../core/domain/inventory/Inventory")
local M = {}
export type Position = { x: number, y: number, z: number }
export type Actor = { id: string, position: Position, alive: boolean }
export type Species = { healthMilli: number, damageMilli: number, drops: { Content.Quantity } }
export type Weapon = {
	damageMilli: number,
	wearMilli: number,
	rangeStuds: number,
	facingDot: number,
	cooldownMillis: number,
}
export type Catalog = { species: { [string]: Species }, weapons: { [string]: Weapon } }
export type State = {
	id: string,
	catalogId: string,
	home: Position,
	healthMilli: number,
	mode: string,
	target: string?,
	deadline: number,
	nextAttack: number,
	lastMillis: number,
	strike: number,
	version: number,
	killer: string?,
}
export type Observation = {
	position: Position,
	actors: { Actor },
	pathFailed: boolean,
	lineOfSight: (string) -> boolean,
}
export type Intent = { destination: Position?, damage: { actorId: string, damageMilli: number, strikeId: string }? }
export type Access = {
	actorId: string,
	alive: boolean,
	position: Position,
	facing: Position,
	targetPosition: Position,
	lineOfSight: boolean,
	equipped: { [string]: boolean },
}
export type Candidate = {
	wildlife: State,
	inventory: Inventory.State,
	nextAttack: number,
	drops: { Content.Quantity },
	deathId: string?,
}
local function integer(n: number, low: number, high: number): boolean
	return n == n and n % 1 == 0 and n >= low and n <= high
end
function M.distance(a: Position, b: Position): number
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end
function M.catalog(content: Content.Document, catalog: Catalog): Catalog
	local result: Catalog = { species = {}, weapons = {} }
	local items: { [string]: Content.Item } = {}
	for _, item in content.items do
		items[item.id] = item
	end
	for _, definition in content.wildlife do
		local rule = assert(catalog.species[definition.id], "MISSING_SPECIES")
		assert(integer(rule.healthMilli, 1, 1000000) and integer(rule.damageMilli, 0, 100000), "INVALID_SPECIES")
		local drops = {}
		for _, drop in rule.drops do
			assert(items[drop.item] and integer(drop.quantity, 1, 1000), "INVALID_DROP")
			table.insert(drops, table.clone(drop))
		end
		result.species[definition.id] =
			{ healthMilli = rule.healthMilli, damageMilli = rule.damageMilli, drops = drops }
	end
	for id, rule in catalog.weapons do
		assert(items[id] and (items[id].maxDurabilityMilli or 0) > 0, "INVALID_WEAPON")
		assert(integer(rule.damageMilli, 1, 100000) and integer(rule.wearMilli, 1, 1000000), "INVALID_WEAPON_EFFECT")
		assert(integer(rule.rangeStuds, 1, 8) and integer(rule.cooldownMillis, 1, 86400000), "INVALID_WEAPON_RANGE")
		assert(rule.facingDot == rule.facingDot and rule.facingDot >= 0 and rule.facingDot <= 1, "INVALID_FACING")
		result.weapons[id] = table.clone(rule)
	end
	return result
end
function M.new(id: string, kind: string, home: Position, catalog: Catalog): State
	assert(#id > 0 and #id <= 64 and catalog.species[kind], "INVALID_WILDLIFE")
	return {
		id = id,
		catalogId = kind,
		home = table.clone(home),
		healthMilli = catalog.species[kind].healthMilli,
		mode = "idle",
		deadline = 0,
		nextAttack = 0,
		lastMillis = 0,
		strike = 0,
		version = 0,
	}
end
function M.step(
	state: State,
	definition: Content.Wildlife,
	rule: Species,
	now: number,
	observation: Observation
): (State, Intent)
	assert(integer(now, state.lastMillis, 2 ^ 53 - 1), "INVALID_CLOCK")
	assert(definition.id == state.catalogId, "WRONG_SPECIES")
	local nextState = table.clone(state)
	nextState.home = table.clone(state.home)
	nextState.lastMillis = now
	local intent: Intent = {}
	if state.healthMilli == 0 then
		nextState.mode = "dead"
		return nextState, intent
	end
	if observation.pathFailed then
		nextState.mode, nextState.target, nextState.deadline = "idle", nil, 0
		return nextState, intent
	end
	local closest: Actor? = nil
	local distance = math.huge
	for _, actor in observation.actors do
		if actor.alive then
			local d = M.distance(observation.position, actor.position)
			if d < distance or (d == distance and closest ~= nil and actor.id < closest.id) then
				closest, distance = actor, d
			end
		end
	end
	if definition.behavior == "grazer" then
		local radius = if state.mode == "flee"
			then assert(definition.fleeStuds, "MISSING_BEHAVIOR_FIELD")
			else assert(definition.senseStuds, "MISSING_BEHAVIOR_FIELD")
		if closest and distance <= radius then
			nextState.mode, nextState.target = "flee", closest.id
			local dx, dz = observation.position.x - closest.position.x, observation.position.z - closest.position.z
			local length = math.sqrt(dx * dx + dz * dz)
			if length == 0 then
				dx, dz, length = 1, 0, 1
			end
			intent.destination = {
				x = observation.position.x + dx / length * assert(definition.fleeStuds, "MISSING_BEHAVIOR_FIELD"),
				y = observation.position.y,
				z = observation.position.z + dz / length * assert(definition.fleeStuds, "MISSING_BEHAVIOR_FIELD"),
			}
		else
			nextState.mode, nextState.target = "roam", nil
			intent.destination = table.clone(state.home)
		end
		return nextState, intent
	end
	if
		state.mode == "return"
		or M.distance(observation.position, state.home) > assert(definition.leashStuds, "MISSING_BEHAVIOR_FIELD")
		or (
			closest
			and M.distance(closest.position, state.home) > assert(definition.leashStuds, "MISSING_BEHAVIOR_FIELD")
		)
	then
		nextState.mode, nextState.target =
			if M.distance(observation.position, state.home) <= 1 then "idle" else "return", nil
		intent.destination = table.clone(state.home)
		return nextState, intent
	end
	if
		not closest
		or (
			(state.mode == "idle" or state.mode == "roam")
			and distance > assert(definition.warnStuds, "MISSING_BEHAVIOR_FIELD")
		)
	then
		nextState.mode, nextState.target = "idle", nil
		return nextState, intent
	end
	-- A changed target must receive its own full warning, never inherit a strike.
	if state.target ~= closest.id or state.mode == "idle" then
		nextState.mode, nextState.target, nextState.deadline =
			"warn", closest.id, now + assert(definition.telegraphMillis, "MISSING_BEHAVIOR_FIELD")
		return nextState, intent
	end
	if state.mode == "warn" then
		if now < state.deadline then
			return nextState, intent
		end
		nextState.mode = "chase"
	end
	if state.mode == "telegraph" then
		if now < state.deadline then
			return nextState, intent
		end
		nextState.mode, nextState.nextAttack =
			"chase", now + assert(definition.cooldownMillis, "MISSING_BEHAVIOR_FIELD")
		if
			distance <= assert(definition.attackStuds, "MISSING_BEHAVIOR_FIELD") and observation.lineOfSight(closest.id)
		then
			nextState.strike += 1
			intent.damage = {
				actorId = closest.id,
				damageMilli = rule.damageMilli,
				strikeId = state.id .. ":" .. tostring(nextState.strike),
			}
		end
		return nextState, intent
	end
	if distance <= assert(definition.attackStuds, "MISSING_BEHAVIOR_FIELD") and now >= state.nextAttack then
		nextState.mode, nextState.deadline =
			"telegraph", now + assert(definition.telegraphMillis, "MISSING_BEHAVIOR_FIELD")
	else
		nextState.mode = "chase"
		intent.destination = table.clone(closest.position)
	end
	return nextState, intent
end
-- Re-evaluate inside the existing fenced owner callback, after durable replay
-- lookup. Client input is only target ID; Access comes from the engine binding.
function M.attack(
	state: State,
	bag: Inventory.State,
	catalog: Catalog,
	now: number,
	nextAttack: number,
	access: Access
): (Candidate?, string?)
	if not integer(now, 0, 2 ^ 53 - 1) or now < nextAttack then
		return nil, "COOLDOWN"
	end
	if not access.alive then
		return nil, "NOT_ALIVE"
	end
	if state.healthMilli == 0 then
		return nil, "ALREADY_DEAD"
	end
	local ids = {}
	for id in access.equipped do
		table.insert(ids, id)
	end
	table.sort(ids)
	local selected: Inventory.Item? = nil
	local weapon: Weapon? = nil
	for _, id in ids do
		local item = bag.items[id]
		local rule = if item then catalog.weapons[item.catalogId] else nil
		if access.equipped[id] and item and rule and Inventory.available(bag, id) > 0 and item.durabilityMilli > 0 then
			selected, weapon = item, rule
			break
		end
	end
	if not selected or not weapon then
		return nil, "WEAPON_UNAVAILABLE"
	end
	local distance = M.distance(access.position, access.targetPosition)
	if distance > weapon.rangeStuds then
		return nil, "OUT_OF_RANGE"
	end
	if not access.lineOfSight then
		return nil, "BLOCKED"
	end
	local length = M.distance(access.facing, { x = 0, y = 0, z = 0 })
	local dot = if length > 0 and distance > 0
		then (
			(access.targetPosition.x - access.position.x) * access.facing.x
			+ (access.targetPosition.y - access.position.y) * access.facing.y
			+ (access.targetPosition.z - access.position.z) * access.facing.z
		)
			/ length
			/ distance
		else -1
	if dot < weapon.facingDot then
		return nil, "NOT_FACING"
	end
	local npc = table.clone(state)
	npc.home = table.clone(state.home)
	npc.healthMilli = math.max(0, state.healthMilli - weapon.damageMilli)
	npc.version += 1
	local inventory = Inventory.snapshot(bag)
	inventory.items[selected.itemId].durabilityMilli = math.max(0, selected.durabilityMilli - weapon.wearMilli)
	inventory.version += 1
	local drops = {}
	local deathId: string? = nil
	if npc.healthMilli == 0 then
		npc.mode, npc.killer = "dead", access.actorId
		deathId = state.id .. ":death"
		for _, drop in catalog.species[state.catalogId].drops do
			table.insert(drops, table.clone(drop))
		end
	end
	return {
		wildlife = npc,
		inventory = inventory,
		nextAttack = now + weapon.cooldownMillis,
		drops = drops,
		deathId = deathId,
	},
		nil
end
return M
