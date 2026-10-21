--!strict
-- Pure candidate transitions for an injected durable Session transaction.
-- The adapter must commit these candidates with item/currency debits atomically.
local Tree = require("../../../core/domain/progression/SkillTree")
local Materials = require("../../../core/domain/crafting/MaterialGrowth")
local Volcano = require("../../../core/domain/survival/Volcano")
local LateEquipment = require("../../../core/domain/survival/LateEquipment")
local M = {}

function M.volcanicReadiness(
	content: any,
	vitals: any,
	gear: { any },
	research: any,
	layout: any,
	position: any,
	from: number,
	now: number,
	worldOrigin: number
): any
	local policy = content.progressionPolicy.volcano
	local boots = false
	for _, item in gear do
		boots = boots or (item.material.item == policy.bootsItem and (item.durability == nil or item.durability > 0))
	end
	local effects = LateEquipment.effects(content, research)
	return Volcano.advance(
		vitals,
		from,
		now,
		worldOrigin,
		Volcano.zone(layout, position),
		boots,
		policy,
		1 + (effects["life-reduction"] or 0) / 100
	)
end

function M.staminaExpenditure(content: any, research: any, baseCost: number, carrying: boolean): number
	local effects = LateEquipment.effects(content, research)
	return baseCost
		* (1 + (effects["light-reduction"] or 0) / 100)
		* (if carrying then 1 + (effects["heavy-reduction"] or 0) / 100 else 1)
end

local function operation(content: any, id: string): any
	for _, row in content.operations do
		if row.id == id then
			return row
		end
	end
	return nil
end

function M.craft(
	content: any,
	state: Tree.State,
	id: string,
	inputs: { Materials.Material }
): (Materials.Material?, string?)
	local row, detail = Materials.recipe(content, id)
	if not row or not detail then
		return nil, "UNKNOWN_RECIPE"
	end
	local reason =
		Tree.gate(state, detail.gates or { characterLevel = detail.minCharacterLevel, skillNodes = detail.skillNodes })
	if reason then
		return nil, reason
	end
	return Materials.craft(content, id, inputs)
end

function M.gather(state: Tree.State, resource: any): string?
	return Tree.gate(state, resource.gates or {})
end

-- Receipt settlement and cancellation state are supplied by the durable job
-- owner, not RPC. The caller persists the refund with its completion receipt.
function M.refunds(
	content: any,
	state: Tree.State,
	id: string,
	inputs: { Materials.Material },
	category: string,
	seed: number,
	receipt: string,
	cancelled: boolean
): { [string]: number }
	if cancelled or not state.paid[category .. "_6"] then
		return {}
	end
	local _, detail = Materials.recipe(content, id)
	if not detail then
		return {}
	end
	local categoryMatches = false
	for _, nodeId in detail.skillNodes or (detail.gates or {}).skillNodes or {} do
		categoryMatches = categoryMatches or string.match(nodeId, "^(.*)_%d+$") == category
	end
	-- Exact tutorial exemptions have no purchased node gate; their entry action
	-- still declares the category, rather than accepting a client category.
	for _, entry in content.skillCategories do
		if entry.id == category and table.find(entry.entryActions, id) then
			categoryMatches = true
		end
	end
	if not categoryMatches then
		return {}
	end
	for _, node in content.skillNodes do
		if node.id == category .. "_6" then
			for _, effect in node.effects do
				if string.find(effect.unit, "refund", 1, true) then
					return Materials.refunds(inputs, detail.primaryInputs, effect.value / 100, seed, receipt)
				end
			end
		end
	end
	return {}
end

-- Research/support outputs replace their preceding tier; they are not summed.
-- Completed IDs, currency, station tier and material debit belong to the same
-- owner transaction that accepts this candidate.
function M.upgrade(
	content: any,
	state: Tree.State,
	completed: { [string]: boolean },
	id: string,
	facts: any
): (any, string?)
	local row = operation(content, id)
	if not row or (row.kind ~= "research" and row.kind ~= "support-tier") then
		return nil, "UNKNOWN_UPGRADE"
	end
	local reason = Tree.gate(state, row.gates or {})
	if reason then
		return nil, reason
	elseif completed[id] then
		return nil, "ALREADY_COMPLETED"
	elseif facts.developmentRank < ((row.gates or {}).developmentRank or 0) then
		return nil, "DEVELOPMENT_GATE"
	elseif facts.station ~= row.station or facts.stationTier < (row.stationTier or 1) then
		return nil, "STATION_GATE"
	elseif facts.coins < (row.cost or 0) then
		return nil, "INSUFFICIENT_COINS"
	end
	for _, prerequisite in (row.gates or {}).completed or {} do
		if not completed[prerequisite] then
			return nil, "UPGRADE_PREREQUISITE"
		end
	end
	return { id = id, effects = row.effects, cost = row.cost or 0, inputs = row.inputs, seconds = row.seconds }, nil
end

function M.modify(content: any, state: Tree.State, equipment: any, id: string, slot: number): (any, string?)
	local row = operation(content, id)
	if not row or row.kind ~= "modifier" then
		return nil, "UNKNOWN_MODIFICATION"
	elseif slot ~= 1 and slot ~= 2 then
		return nil, "INVALID_MODIFICATION_SLOT"
	end
	local reason = Tree.gate(state, row.gates or {})
	if reason then
		return nil, reason
	end
	local eligible = false
	for _, tag in row.eligibleTags or {} do
		eligible = eligible or table.find(equipment.tags, tag) ~= nil
	end
	if not eligible then
		return nil, "INELIGIBLE_MODIFICATION"
	end
	local node = if table.find(equipment.tags, "clothing") or table.find(equipment.tags, "saddle")
		then "tailoring_4"
		else "weapon_tool_4"
	if not state.paid[node] then
		return nil, "SKILL_GATE"
	end
	local result = table.clone(equipment)
	result.modifications = table.clone(equipment.modifications or {})
	result.modifications[slot] = row.effects
	return result, nil
end

-- Base stats and coefficients are an authored injected policy, never client
-- values. Support multiplies base performance once; it never changes capacity.
function M.equipment(content: any, item: any, policy: any): any
	local attributes = table.clone(item.material.attributes)
	for _, effects in item.modifications or {} do
		for _, effect in effects do
			attributes[effect.id] = (attributes[effect.id] or 0) + effect.value
		end
	end
	local support = 1
	if item.support then
		local row = assert(operation(content, item.support), "UNKNOWN_SUPPORT")
		for _, effect in row.effects do
			if effect.id == "base-performance" then
				support += effect.value / 100
			end
		end
	end
	local sharpness = 1 + attributes.sharpness * policy.sharpnessPerPoint
	local climate = policy.clothing[item.material.item]
	local clothing = table.find(item.tags, "clothing") ~= nil
	local weaponTool = table.find(item.tags, "weapon-tool") ~= nil
	return {
		performance = if weaponTool
			then math.floor(item.base * support * sharpness * policy.precision + 0.5) / policy.precision
			else item.base,
		armor = if clothing then math.floor(item.base * support + attributes.hardness + 0.5) else 0,
		cold = (if climate then climate.cold else 0)
			+ (if clothing then attributes.insulation * policy.insulationCold else 0),
		heat = if climate then climate.heat else 0,
		wearMultiplier = if clothing or table.find(item.tags, "saddle")
			then math.max(policy.minimumWear, 1 - attributes.flexibility * policy.flexibilityWear)
			else 1,
	}
end

function M.eat(content: any, vitals: any, material: Materials.Material, now: number, policy: any): (any, string?)
	local eating = operation(content, "eat-" .. material.item)
	local edible = eating ~= nil and eating.kind == "food"
	for _, item in content.items do
		if item.id == material.item then
			edible = edible or item.foodEffects ~= nil
			break
		end
	end
	if not edible or policy.feed[material.item] then
		return nil, "NOT_PLAYER_FOOD"
	end
	local result: any = table.clone(vitals)
	result.energy = math.min(
		policy.maxVital,
		vitals.energy + policy.energyBase + policy.energyNutrition * material.attributes.nutrition
	)
	result.health = math.min(policy.maxVital, vitals.health + policy.healthBase + material.attributes.nutrition)
	result.buffs = table.clone(vitals.buffs)
	local family = policy.foodFamilies[material.item]
	if family then
		local prior = result.buffs[family]
		result.buffs[family] = {
			strength = math.max(
				if prior and prior.untilTime > now then prior.strength else 0,
				policy.buffStrength[family]
			),
			untilTime = now + policy.buffSeconds,
		}
	end
	return result, nil
end

-- Splits at buff expiry exactly, so arbitrary heartbeat partitioning preserves
-- health and fatigue. Rest rate comes directly from SurvivalContent.vitals.
function M.readiness(
	content: any,
	vitals: any,
	gear: { any },
	from: number,
	now: number,
	climate: string,
	intensity: number,
	resting: boolean,
	policy: any
): any
	assert(now >= from, "INVALID_CLOCK")
	local result: any = table.clone(vitals)
	local cold, heat = 0, 0
	for _, item in gear do
		local stats = M.equipment(content, item, policy)
		cold += stats.cold
		heat += stats.heat
	end
	local cuts = { from, now }
	for _, buff in vitals.buffs do
		if buff.untilTime > from and buff.untilTime < now then
			table.insert(cuts, buff.untilTime)
		end
	end
	table.sort(cuts)
	for i = 2, #cuts do
		local start, dt = cuts[i - 1], cuts[i] - cuts[i - 1]
		local resistance = if climate == "cold" then cold elseif climate == "heat" then heat else intensity
		local buff = vitals.buffs.resistance
		if buff and buff.untilTime > start then
			resistance += buff.strength
		end
		local exposure = math.max(0, intensity - resistance)
		local recovery = vitals.buffs.recovery
		local healing = if recovery and recovery.untilTime > start then recovery.strength else 0
		result.health =
			math.clamp(result.health + (healing - exposure * policy.exposureHealth) * dt, 0, policy.maxVital)
		result.fatigue = math.clamp(
			result.fatigue
				+ (
						exposure * policy.exposureFatigue
						- (if resting then content.vitals.restMilliPerSecond / 1000 else 0)
					)
					* dt,
			0,
			policy.maxVital
		)
	end
	local stamina = vitals.buffs.stamina
	result.staminaCost = if stamina and stamina.untilTime > now then 1 - stamina.strength else 1
	return result
end

return M
