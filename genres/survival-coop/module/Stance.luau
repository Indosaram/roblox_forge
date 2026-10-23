--!strict
-- Combat stances (fidelity contract: attack / defense / counter / onslaught / charge / shoot).
-- Pure rules over explicit clocks: a stance is unlocked by its skill node, switching has a shared
-- 2 s cooldown and is refused while an attack windup is pending. Multipliers are permille.
-- Counter is measured from the end of the actor's last guard window (the closest server fact
-- to "after a successful block"); it is a reconstruction, not a recovered parry rule.
local M = {}

export type State = { id: string, changedAt: number }

M.SWITCH_MILLIS = 2000
M.COUNTER_MILLIS = 2000
M.IDS = { "attack", "defense", "counter", "onslaught", "charge", "shoot" }
-- Unlock nodes from content.yml skillNodes (melee_1 attack, melee_3 counter, melee_4 onslaught,
-- melee_5 charge, ranged_1 shooting, defense_1 defense).
M.NODES = table.freeze({
	attack = "melee_1",
	defense = "defense_1",
	counter = "melee_3",
	onslaught = "melee_4",
	charge = "melee_5",
	shoot = "ranged_1",
})

--- Validated switch. `none` clears the stance and needs no node. windupUntil is the actor's
--- pending attack resolve time (combat.nextAttack's windup part), never client supplied.
function M.select(current: State?, progression: any, id: string, now: number, windupUntil: number): (State?, string?)
	if id ~= "none" and not M.NODES[id] then
		return nil, "UNKNOWN_STANCE"
	end
	if id ~= "none" and not (progression and progression.paid and progression.paid[M.NODES[id]]) then
		return nil, "STANCE_LOCKED"
	end
	if current and now < current.changedAt + M.SWITCH_MILLIS then
		return nil, "STANCE_COOLDOWN"
	end
	if now < windupUntil then
		return nil, "STANCE_WINDUP"
	end
	local nextState: State = { id = id :: string, changedAt = now }
	return nextState, nil
end

local function active(state: State?): string
	return if state then state.id else "none"
end

--- Outgoing damage scale for an attack of `mode` ("melee" or "ranged").
function M.damagePermille(state: State?, mode: string, counterReady: boolean): number
	local id = active(state)
	if id == "attack" then
		return 1100
	elseif id == "onslaught" then
		return 1250
	elseif id == "shoot" then
		return if mode == "ranged" then 1150 else 1000
	elseif id == "counter" then
		return if counterReady then 1300 else 1000
	end
	return 1000
end

--- Incoming damage scale.
function M.incomingPermille(state: State?): number
	local id = active(state)
	return if id == "defense" then 750 elseif id == "onslaught" then 1200 else 1000
end

--- Movement speed scale.
function M.speedPermille(state: State?): number
	local id = active(state)
	return if id == "defense" then 900 elseif id == "charge" then 1150 else 1000
end

--- True within COUNTER_MILLIS after the actor's last guard window closed.
function M.counterReady(defense: any?, now: number): boolean
	local closed = defense and defense.guardEnd
	return closed ~= nil and now >= defense.guardStart and now <= closed + M.COUNTER_MILLIS
end

return M
