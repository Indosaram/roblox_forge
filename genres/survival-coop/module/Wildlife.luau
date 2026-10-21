--!strict
-- Copy-on-write encounter rules. The owning command transaction publishes combat
-- candidates, including inventory wear and the one death/drop entitlement together.
local Content = require("../../../core/domain/survival/Content")
local Archetype = require("../../../core/domain/survival/Archetype")
local Inventory = require("../../../core/domain/inventory/Inventory")
local CapacityPolicy = require("../../../core/domain/survival/CapacityPolicy")
local M = {}
--- Observer radius used by the world binding for hibernation LOD.
M.HIBERNATE_STUDS = Archetype.HIBERNATE_STUDS
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
	-- Actor that provoked this creature (damage or herd alarm); cleared on disengage.
	provoker: string?,
	-- Last clock at which the engagement made progress (new target, in strike range).
	engagedAt: number?,
	-- Durable capture window: while nowMillis < capturedUntil the creature is out of the world
	-- (tamed by captureId); afterwards it is back at home. Set only by the wildlife owner.
	capturedUntil: number?,
	captureId: string?,
}
--- True while a durable capture keeps this creature out of the world.
function M.captured(state: { capturedUntil: number? }, now: number): boolean
	return state.capturedUntil ~= nil and now < state.capturedUntil
end
export type Observation = {
	position: Position,
	actors: { Actor },
	pathFailed: boolean,
	lineOfSight: (string) -> boolean,
	-- Optional extensions; absent keeps the legacy behaviour exactly.
	observerStuds: number?, -- no living actor this close: hibernate
	resting: boolean?, -- caller's clock-derived rest window: an undisturbed creature sleeps
	provokedBy: string?, -- actor that damaged it (or alarmed its herd) since the last step
}
export type Intent = {
	destination: Position?,
	damage: { actorId: string, damageMilli: number, strikeId: string }?,
	healMilli: number?,
}
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
		assert(
			integer(rule.healthMilli, 1, CapacityPolicy.forVersion(content.version).healthMilli)
				and integer(rule.damageMilli, 0, 100000),
			"INVALID_SPECIES"
		)
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
local RESTING: { [string]: boolean } = { idle = true, roam = true, sleep = true, hibernate = true }
local ENGAGED: { [string]: boolean } = { warn = true, chase = true, telegraph = true }
-- Health restored by a return leg of `elapsed` milliseconds (integer, floor).
local function regen(maxMilli: number, elapsed: number): number
	return maxMilli * Archetype.RETURN_REGEN_PERMILLE_PER_SECOND * elapsed // 1000000
end
-- Heals `nextState` to `target` health and records the delta on the intent.
local function heal(nextState: State, intent: Intent, target: number)
	if target > nextState.healthMilli then
		intent.healMilli = (intent.healMilli or 0) + target - nextState.healthMilli
		nextState.healthMilli = target
	end
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
	local archetype = assert(Archetype.get(definition.behavior), "UNKNOWN_BEHAVIOR")
	local flag = definition.flag or archetype.flag
	local band = definition.dangerBand or 1
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
	if observation.provokedBy then
		nextState.provoker = observation.provokedBy
	end
	local closest: Actor? = nil
	local distance = math.huge
	local provoker: Actor? = nil
	for _, actor in observation.actors do
		if actor.alive then
			local d = M.distance(observation.position, actor.position)
			if d < distance or (d == distance and closest ~= nil and actor.id < closest.id) then
				closest, distance = actor, d
			end
			if actor.id == nextState.provoker then
				provoker = actor
			end
		end
	end
	-- A provoker that died, left or teleported away is forgotten: no aggro may
	-- outlive the actor it points at.
	if not provoker then
		nextState.provoker = nil
	end
	local homeDistance = M.distance(observation.position, state.home)
	-- LOD: nobody can observe it, so it stops perceiving. It walks home if it
	-- strayed and is whole again once it arrives.
	local observerStuds = observation.observerStuds
	if observerStuds and not provoker and distance > observerStuds then
		nextState.target, nextState.deadline, nextState.engagedAt = nil, 0, nil
		if homeDistance > 1 then
			nextState.mode = "return"
			heal(
				nextState,
				intent,
				math.min(rule.healthMilli, state.healthMilli + regen(rule.healthMilli, now - state.lastMillis))
			)
			intent.destination = table.clone(state.home)
		else
			nextState.mode = "hibernate"
			heal(nextState, intent, rule.healthMilli)
		end
		return nextState, intent
	end
	local senseBase = if archetype.engine == "grazer"
		then assert(definition.senseStuds, "MISSING_BEHAVIOR_FIELD")
		else assert(definition.warnStuds, "MISSING_BEHAVIOR_FIELD")
	local detect = Archetype.detection(senseBase, band)
	-- Sleep inside the caller's rest window; only provocation or an actor well
	-- inside the detection radius wakes it.
	if
		observation.resting
		and RESTING[state.mode]
		and not provoker
		and distance > detect * Archetype.WAKE_PERMILLE / 1000
	then
		nextState.mode, nextState.target, nextState.deadline, nextState.engagedAt = "sleep", nil, 0, nil
		return nextState, intent
	end
	if archetype.engine == "grazer" then
		local threat: Actor? = provoker or closest
		local threatDistance = if provoker then M.distance(observation.position, provoker.position) else distance
		local radius = if state.mode == "flee" then assert(definition.fleeStuds, "MISSING_BEHAVIOR_FIELD") else detect
		if threat and (threatDistance <= radius or observation.provokedBy == threat.id) then
			nextState.mode, nextState.target = "flee", threat.id
			local dx, dz = observation.position.x - threat.position.x, observation.position.z - threat.position.z
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
			nextState.mode, nextState.target, nextState.provoker = "roam", nil, nil
			intent.destination = table.clone(state.home)
		end
		return nextState, intent
	end
	-- Whoever provoked it is engaged first; otherwise retaliators stay calm and
	-- aggressors take the closest actor.
	local candidate: Actor? = if provoker then provoker elseif flag == "retaliate" then nil else closest
	local candidateDistance = if candidate then M.distance(observation.position, candidate.position) else math.huge
	local leash = assert(definition.leashStuds, "MISSING_BEHAVIOR_FIELD")
	local stale = ENGAGED[state.mode] and now - (state.engagedAt or now) >= Archetype.DISENGAGE_MILLIS
	if
		state.mode == "return"
		or stale
		or homeDistance > leash
		or (candidate and M.distance(candidate.position, state.home) > leash)
	then
		nextState.target, nextState.provoker, nextState.engagedAt = nil, nil, nil
		if homeDistance <= 1 then
			nextState.mode = "idle"
			heal(nextState, intent, rule.healthMilli)
		else
			nextState.mode = "return"
			heal(
				nextState,
				intent,
				math.min(rule.healthMilli, state.healthMilli + regen(rule.healthMilli, now - state.lastMillis))
			)
			intent.destination = table.clone(state.home)
		end
		return nextState, intent
	end
	if not candidate or (RESTING[state.mode] and candidateDistance > detect and candidate.id ~= nextState.provoker) then
		nextState.mode, nextState.target, nextState.engagedAt = "idle", nil, nil
		return nextState, intent
	end
	local attackStuds = assert(definition.attackStuds, "MISSING_BEHAVIOR_FIELD")
	if candidateDistance <= attackStuds then
		nextState.engagedAt = now
	end
	-- A changed target must receive its own full warning, never inherit a strike.
	if state.target ~= candidate.id or RESTING[state.mode] then
		nextState.mode, nextState.target, nextState.deadline, nextState.engagedAt =
			"warn", candidate.id, now + assert(definition.telegraphMillis, "MISSING_BEHAVIOR_FIELD"), now
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
		if candidateDistance <= attackStuds and observation.lineOfSight(candidate.id) then
			nextState.strike += 1
			intent.damage = {
				actorId = candidate.id,
				damageMilli = rule.damageMilli,
				strikeId = state.id .. ":" .. tostring(nextState.strike),
			}
		end
		return nextState, intent
	end
	if candidateDistance <= attackStuds and now >= state.nextAttack then
		nextState.mode, nextState.deadline =
			"telegraph", now + assert(definition.telegraphMillis, "MISSING_BEHAVIOR_FIELD")
	else
		nextState.mode = "chase"
		intent.destination = table.clone(candidate.position)
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
