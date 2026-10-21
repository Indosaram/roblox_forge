--!strict
-- Server-owned ecology candidates. Catalog reservoirs are the sole source of
-- carcass quantities; capture never creates a carcass or an automatic drop.
local Rng = require("../../../core/domain/random/Rng")
local M = {}
export type Reservoir = { item: string, quantity: number, skillNode: string }
export type Corpse = {
	id: string,
	party: { [string]: boolean },
	publicAt: number,
	expiresAt: number,
	remaining: { [string]: number },
	gates: { [string]: string },
	receipts: { [string]: number },
}
export type CaptureRules = {
	basePermille: number,
	levelPermille: number,
	bonusPermille: number,
	minPermille: number,
	maxPermille: number,
}
function M.captureChance(species: any, facts: any, rules: CaptureRules): (number?, string?)
	if species.captureClass == "never" then
		return nil, "NOT_TAMEABLE"
	end
	if not facts.survival3 or not facts.stunned then
		return nil, "CAPTURE_GATED"
	end
	if species.captureClass == "advanced" and (not facts.clanResearch or not facts.stronghold) then
		return nil, "ADVANCED_CAPTURE_GATED"
	end
	if facts.occupied >= facts.capacity then
		return nil, "CAPACITY"
	end
	if facts.rope < 1 then
		return nil, "NO_ROPE"
	end
	local chance = rules.basePermille
		+ rules.levelPermille * (facts.survivalSkill - species.level)
		+ (if facts.survival6 then rules.bonusPermille else 0)
	return math.clamp(chance, rules.minPermille, rules.maxPermille), nil
end
function M.rollCapture(species: any, facts: any, rules: CaptureRules, seed: number): (boolean?, number, string?)
	local chance, reason = M.captureChance(species, facts, rules)
	if chance == nil then
		return nil, facts.rope, reason
	end
	local rng = Rng.new(seed):fork("capture")
	return rng:nextInteger(1, 1000) <= chance, facts.rope - 1, nil
end
function M.carcass(
	id: string,
	reservoirs: { Reservoir },
	party: { [string]: boolean },
	now: number,
	publicMillis: number,
	lifetimeMillis: number,
	bonusMeat: boolean
): Corpse
	local corpse: Corpse = {
		id = id,
		party = table.clone(party),
		publicAt = now + publicMillis,
		expiresAt = now + lifetimeMillis,
		remaining = {},
		gates = {},
		receipts = {},
	}
	for _, reservoir in reservoirs do
		assert(reservoir.quantity >= 1 and reservoir.quantity % 1 == 0, "INVALID_RESERVOIR")
		corpse.remaining[reservoir.item] = reservoir.quantity
		corpse.gates[reservoir.item] = reservoir.skillNode
	end
	if bonusMeat then
		corpse.remaining.meat = (corpse.remaining.meat or 0) + 1
	end
	return corpse
end
function M.butcher(
	corpse: Corpse,
	actor: string,
	request: string,
	material: string,
	skills: { [string]: boolean },
	now: number
): (Corpse?, number, string?)
	local key = actor .. ":" .. request .. ":" .. material
	if corpse.receipts[key] then
		return corpse, 0, nil
	end
	if now >= corpse.expiresAt then
		return nil, 0, "CORPSE_EXPIRED"
	end
	if now < corpse.publicAt and not corpse.party[actor] then
		return nil, 0, "PARTY_RESERVED"
	end
	local remaining = corpse.remaining[material] or 0
	if remaining == 0 then
		return nil, 0, "EXHAUSTED"
	end
	local quantity = remaining
	if not skills[corpse.gates[material]] then
		-- Exactly one unskilled meat from the original reservoir, not one per actor.
		if material ~= "meat" or corpse.receipts["unskilled-meat"] then
			return nil, 0, "SKILL_GATED"
		end
		quantity = 1
	end
	local nextCorpse = table.clone(corpse)
	nextCorpse.remaining, nextCorpse.receipts = table.clone(corpse.remaining), table.clone(corpse.receipts)
	nextCorpse.remaining[material] -= quantity
	nextCorpse.receipts[key] = quantity
	if material == "meat" and not skills[corpse.gates[material]] then
		nextCorpse.receipts["unskilled-meat"] = 1
	end
	return nextCorpse, quantity, nil
end
-- A group token is keyed by target. Only the current full-windup owner may
-- release it; stale cancellation cannot release the next creature's attack.
function M.acquire(tokens: { [string]: string }, target: string, strike: string): ({ [string]: string }?, string?)
	if tokens[target] then
		return nil, "GROUP_ATTACK_BUSY"
	end
	local result = table.clone(tokens)
	result[target] = strike
	return result, nil
end
function M.release(tokens: { [string]: string }, target: string, strike: string): { [string]: string }
	local result = table.clone(tokens)
	if result[target] == strike then
		result[target] = nil
	end
	return result
end
return M
