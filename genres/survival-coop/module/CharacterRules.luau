--!strict
-- Engine-free character/progression rules: gear slots, equip/unequip, stat comparison and the
-- read models behind the character, island-rank, research, support and modify screens.
-- No clock or randomness is read here; callers pass `now` explicitly.
local Tree = require("../../../core/domain/progression/SkillTree")
local Late = require("../../../core/domain/survival/LateEquipment")
local Progression = require("./ProgressionExtension")
local Data = require("../../../core/domain/genre/SerializedData")
local M = {}

M.CLOTHING = { "head", "top", "bottom", "shoes", "gloves", "bag" }
M.SLOTS = { "head", "top", "bottom", "shoes", "gloves", "bag", "weapon" }
-- RECONSTRUCTED: exploration rank is a fixed 100 development points per rank, rank 0-10.
M.RANK_POINTS = 100
M.MAX_RANK = 10
M.LINES = { "life", "light", "heavy" }
local TOOLS =
	{ "axe", "pickaxe", "pick", "hammer", "maul", "hoe", "knife", "club", "spear", "sword", "bow", "crossbow" }
local ATTRIBUTES = { "sharpness", "hardness", "insulation", "flexibility" }

--- Gear slot a catalog item occupies, or nil when it is not wearable/wieldable.
function M.slotOf(catalogId: string): string?
	for _, slot in M.CLOTHING do
		if string.sub(catalogId, -(#slot + 1)) == "-" .. slot then
			return slot
		end
	end
	local stem = string.gsub(catalogId, "%-t%d$", "")
	local last = string.match(stem, "(%a+)$")
	return if last and table.find(TOOLS, last) then "weapon" else nil
end

-- RECONSTRUCTED base value: 5 per tier (-tN suffix, otherwise tier 1).
function M.base(catalogId: string): number
	return 5 * (tonumber(string.match(catalogId, "%-t(%d)$")) or 1)
end

--- Equipment record for a bag item (the shape LateEquipment and Progression.equipment consume).
function M.record(item: any): any
	local slot = assert(M.slotOf(item.catalogId), "NOT_EQUIPMENT")
	local attributes: any = {}
	local source = if type(item.material) == "table" then item.material.attributes or {} else {}
	for _, key in ATTRIBUTES do
		attributes[key] = if type(source[key]) == "number" then source[key] else 0
	end
	return {
		itemId = item.itemId,
		catalogId = item.catalogId,
		tags = { if slot == "weapon" then "weapon-tool" else "clothing" },
		base = M.base(item.catalogId),
		material = { item = item.catalogId, attributes = attributes },
		modifications = {},
		completed = {},
	}
end

local function reserved(bag: any, itemId: string): boolean
	for _, quantities in bag.reservations or {} do
		if (quantities[itemId] or 0) > 0 then
			return true
		end
	end
	return false
end

--- Equips a bag item into its slot. `state` = { equipped = {slot -> itemId}, equipment = {itemId -> record} }.
--- Records persist per item, so modifications survive unequip/re-equip.
function M.equip(state: any, bag: any, itemId: string): (any?, string?)
	local item = if type(bag) == "table" and type(bag.items) == "table" then bag.items[itemId] else nil
	if type(item) ~= "table" or (item.quantity or 0) < 1 then
		return nil, "ITEM_NOT_OWNED"
	end
	local slot = M.slotOf(item.catalogId)
	if not slot then
		return nil, "NOT_EQUIPMENT"
	elseif (item.durabilityMilli or 0) <= 0 then
		return nil, "ITEM_BROKEN"
	elseif reserved(bag, itemId) then
		return nil, "ITEM_RESERVED"
	elseif (state.equipped or {})[slot] == itemId then
		return nil, "ALREADY_EQUIPPED"
	end
	local result = Data.clone(state)
	result.equipped = result.equipped or {}
	result.equipment = result.equipment or {}
	result.equipment[itemId] = result.equipment[itemId] or M.record(item)
	result.equipped[slot] = itemId
	return result, nil
end

function M.unequip(state: any, slot: string): (any?, string?)
	if not table.find(M.SLOTS, slot) then
		return nil, "INVALID_SLOT"
	elseif (state.equipped or {})[slot] == nil then
		return nil, "SLOT_EMPTY"
	end
	local result = Data.clone(state)
	result.equipped[slot] = nil
	return result, nil
end

--- Equipped records still backed by the bag (a sold or dropped item no longer counts).
function M.worn(state: any, bag: any): { [string]: any }
	local out = {}
	for slot, itemId in state.equipped or {} do
		local item = bag and bag.items and bag.items[itemId]
		local record = (state.equipment or {})[itemId]
		if item and record and (item.quantity or 0) > 0 then
			out[slot] = record
		end
	end
	return out
end

local ZERO = { performance = 0, armor = 0, cold = 0, heat = 0 }
function M.stats(content: any, record: any?): any
	if not record then
		return ZERO
	end
	return Progression.equipment(content, record, content.progressionPolicy)
end

--- Candidate minus current for every displayed stat.
function M.compare(content: any, current: any?, candidate: any): any
	local a, b = M.stats(content, current), M.stats(content, candidate)
	return {
		performance = b.performance - a.performance,
		armor = b.armor - a.armor,
		cold = b.cold - a.cold,
		heat = b.heat - a.heat,
	}
end

-- RECONSTRUCTED Robango redesign values for worn gear (carried-but-unworn gear has no effect):
-- one climate point = 100 milli exposure resistance (10%), capped at full resistance;
-- one armor point = 10 permille (1%) less incoming damage, capped at 600 permille (60%);
-- one weapon performance point = +1000 milli (one whole damage point) on that weapon's strike.
M.CLIMATE_MILLI_PER_POINT = 100
M.ARMOR_PERMILLE_PER_POINT = 10
M.MAX_ARMOR_PERMILLE = 600
M.WEAPON_MILLI_PER_POINT = 1000

--- Worn records in slot order (the gear list the climate/readiness calculation consumes).
function M.wornList(gear: any?, bag: any?): { any }
	local worn = M.worn(gear or {}, bag)
	local out = {}
	for _, slot in M.SLOTS do
		if worn[slot] then
			table.insert(out, worn[slot])
		end
	end
	return out
end

--- Summed effect of worn gear: armor/cold/heat over every slot, performance of the worn weapon only.
function M.wornStats(content: any, gear: any?, bag: any?): any
	local total: any = { performance = 0, armor = 0, cold = 0, heat = 0, weapon = nil }
	if not content.progressionPolicy then
		return total
	end
	for slot, record in M.worn(gear or {}, bag) do
		local stats = M.stats(content, record)
		total.armor += stats.armor
		total.cold += stats.cold
		total.heat += stats.heat
		if slot == "weapon" then
			total.performance, total.weapon = stats.performance, record.itemId
		end
	end
	return total
end

--- Exposure resistance (Exposure/Vitals milli scale) from worn clothing for one climate.
function M.resistanceMilli(content: any, gear: any?, bag: any?, climate: string): number
	local stats = M.wornStats(content, gear, bag)
	local points = if climate == "cold" then stats.cold elseif climate == "heat" then stats.heat else 0
	return math.clamp(math.floor(points * M.CLIMATE_MILLI_PER_POINT + 0.5), 0, 1000)
end

--- The existing climate readiness calculation, fed only with worn gear.
function M.climate(
	content: any,
	gear: any?,
	bag: any?,
	vitals: any,
	from: number,
	now: number,
	climate: string,
	intensity: number,
	resting: boolean
): any
	return Progression.readiness(
		content,
		vitals,
		M.wornList(gear, bag),
		from,
		now,
		climate,
		intensity,
		resting,
		content.progressionPolicy
	)
end

--- Incoming damage after worn armor (integer milli in, integer milli out).
function M.mitigate(content: any, gear: any?, bag: any?, damage: number): number
	local armor = M.wornStats(content, gear, bag).armor
	local permille = math.clamp(math.floor(armor * M.ARMOR_PERMILLE_PER_POINT), 0, M.MAX_ARMOR_PERMILLE)
	return damage - damage * permille // 1000
end

--- Strike damage for `itemId`: the authored base, plus the worn weapon's performance when it is the worn one.
function M.weaponDamage(content: any, gear: any?, bag: any?, itemId: string, base: number): number
	local stats = M.wornStats(content, gear, bag)
	if stats.weapon ~= itemId then
		return base
	end
	return base + math.floor(stats.performance * M.WEAPON_MILLI_PER_POINT + 0.5)
end

--- Gather tool evidence: tools held in hand plus the worn weapon/tool slot (usable, owned, unbroken).
function M.toolEvidence(gear: any?, bag: any?, held: { [string]: boolean }?): { [string]: boolean }
	local out = table.clone(held or {})
	local itemId = ((gear or {}).equipped or {}).weapon
	local item = if itemId and bag and bag.items then bag.items[itemId] else nil
	if item and (item.quantity or 0) > 0 and (item.durabilityMilli or 0) > 0 and not reserved(bag, itemId) then
		out[itemId] = true
	end
	return out
end

-- Visual attachment per slot: R15 body part (R6 fallback), size and offset in that part's space.
local ATTACH: { [string]: { any } } = {
	head = { "Head", "Head", { 1.3, 0.5, 1.3 }, { 0, 0.55, 0 } },
	top = { "UpperTorso", "Torso", { 2.1, 1.2, 1.2 }, { 0, 0, 0 } },
	bottom = { "LowerTorso", "Torso", { 2.05, 0.5, 1.15 }, { 0, -0.2, 0 } },
	shoes = { "RightFoot", "Right Leg", { 0.9, 0.4, 1.1 }, { 0, -0.3, 0 } },
	gloves = { "RightHand", "Right Arm", { 0.6, 0.5, 0.6 }, { 0, -0.2, 0 } },
	bag = { "UpperTorso", "Torso", { 1.4, 1.4, 0.6 }, { 0, 0, 0.9 } },
	weapon = { "RightHand", "Right Arm", { 0.25, 2.2, 0.25 }, { 0, -0.4, -0.6 } },
}
local PALETTE = {
	cold = { 196, 220, 236 },
	tropical = { 230, 186, 92 },
	temperate = { 146, 116, 78 },
}

--- Pure dressing plan for worn gear (engine adapters weld one light part per entry).
function M.dressing(gear: any?, bag: any?): { any }
	local worn = M.worn(gear or {}, bag)
	local out = {}
	for _, slot in M.SLOTS do
		local record = worn[slot]
		if record then
			local attach = ATTACH[slot]
			local family = string.match(record.catalogId, "^(%a+)%-")
			table.insert(out, {
				slot = slot,
				itemId = record.itemId,
				catalogId = record.catalogId,
				part = attach[1],
				fallback = attach[2],
				size = { x = attach[3][1], y = attach[3][2], z = attach[3][3] },
				offset = { x = attach[4][1], y = attach[4][2], z = attach[4][3] },
				color = if slot == "weapon" then { 113, 77, 43 } else PALETTE[family or ""] or { 128, 122, 112 },
			})
		end
	end
	return out
end

--- Archipelago rank cells: one per island layout, bounds from the layout data, rank from its stage gates.
function M.cells(content: any, rank: number?): { any }
	local gates: { [string]: number } = {}
	for _, stage in content.stages or {} do
		local need = (stage.gates or {}).developmentRank or 0
		gates[stage.layout] = math.min(gates[stage.layout] or math.huge, need)
	end
	local out = {}
	for _, layout in content.layouts or {} do
		local island, stage = string.match(layout.id, "^rw%.a(%d+)%.s(%d+)$")
		if island and layout.bounds then
			local need = gates[layout.id] or 0
			table.insert(out, {
				id = layout.id,
				island = tonumber(island),
				stage = tonumber(stage),
				bounds = Data.clone(layout.bounds),
				width = layout.bounds.max.x - layout.bounds.min.x,
				depth = layout.bounds.max.z - layout.bounds.min.z,
				rank = if need == math.huge then 0 else need,
				open = (rank or 0) >= (if need == math.huge then 0 else need),
			})
		end
	end
	table.sort(out, function(a, b)
		return if a.island ~= b.island then a.island < b.island else a.stage < b.stage
	end)
	return out
end

function M.rank(points: number): number
	return math.clamp(math.floor(points / M.RANK_POINTS), 0, M.MAX_RANK)
end

-- Lowest development rank any research row requires (the lab unlock).
function M.labRank(content: any): number
	local rank = M.MAX_RANK
	for _, row in content.operations or {} do
		if row.kind == "research" then
			rank = math.min(rank, (row.gates or {}).developmentRank or 0)
		end
	end
	return rank
end

function M.character(content: any, tree: any, points: number): any
	local policy = content.progressionPolicy.tree
	local paid = 0
	for _, cost in tree.paid or {} do
		paid += cost
	end
	local rank = M.rank(points)
	return {
		level = tree.level,
		maxLevel = policy.maxLevel,
		xp = tree.xp or 0,
		nextXP = if tree.level >= policy.maxLevel then 0 else policy.xpBase + policy.xpStep * tree.level,
		sp = tree.sp,
		totalSP = tree.sp + paid,
		rank = rank,
		points = points,
		nextRankAt = if rank >= M.MAX_RANK then nil else (rank + 1) * M.RANK_POINTS,
		labRank = M.labRank(content),
		labUnlocked = rank >= M.labRank(content),
	}
end

--- Versioned reset quote: every paid node is removed, its paid SP refunded, mastery kept.
function M.resetQuote(tree: any): any
	local quote = Tree.quote(tree)
	local nodes = {}
	for id in tree.paid or {} do
		table.insert(nodes, id)
	end
	table.sort(nodes)
	return { version = quote.version, refund = quote.refund, nodes = nodes }
end

--- First-award catalog: missions that grant development points, and whether each is earned.
function M.awards(content: any, definitions: { [string]: boolean }?): { any }
	local out = {}
	for _, mission in content.missions or {} do
		local points = if mission.rewards then mission.rewards.development or 0 else 0
		if points > 0 then
			table.insert(out, { id = mission.id, points = points, earned = (definitions or {})[mission.id] == true })
		end
	end
	return out
end

local function runningJob(late: any, match: (any) -> boolean): (string?, any?)
	local ids = {}
	for id in late.jobs or {} do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local job = late.jobs[id]
		if job.status == "running" and match(job) then
			return id, job
		end
	end
	return nil, nil
end

-- Static gate the server will also apply (station/material checks stay server-side).
local function gate(row: any, tree: any, rank: number, completed: { [string]: boolean }, coins: number): string?
	local reason = Tree.gate(tree, row.gates or {})
	if reason then
		return reason
	elseif rank < ((row.gates or {}).developmentRank or 0) then
		return "DEVELOPMENT_GATE"
	elseif completed[row.id] then
		return "ALREADY_COMPLETED"
	end
	for _, prerequisite in (row.gates or {}).completed or {} do
		if not completed[prerequisite] then
			return "UPGRADE_PREREQUISITE"
		end
	end
	if coins < (row.cost or 0) then
		return "INSUFFICIENT_COINS"
	end
	return nil
end

--- Research lines x tiers with status: done / running (jobId, finishAt, refund) / ready / locked (reason).
function M.research(content: any, late: any, tree: any, rank: number, coins: number): { any }
	late = late or Late.new()
	local effects = Late.effects(content, late)
	local out = {}
	for _, line in M.LINES do
		local tiers = {}
		for tier = 1, 3 do
			local row = Late.operation(content, "research-" .. line .. "-" .. tier)
			if row then
				local jobId, job = runningJob(late, function(candidate)
					return candidate.id == row.id
				end)
				local reason = if jobId then nil else gate(row, tree, rank, late.completed or {}, coins)
				table.insert(tiers, {
					row = row,
					status = if late.completed[row.id]
						then "done"
						elseif jobId then "running"
						elseif reason then "locked"
						else "ready",
					reason = if reason ~= "ALREADY_COMPLETED" then reason else nil,
					jobId = jobId,
					finishAt = if job then job.finishAt else nil,
					refund = if job then math.floor(job.cost / 2) else nil,
				})
			end
		end
		table.insert(out, { line = line, benefit = effects[line .. "-reduction"] or 0, tiers = tiers })
	end
	return out
end

--- Support tiers for one equipped record: current effect, each tier's new effect and status.
function M.support(content: any, late: any, tree: any, record: any?, coins: number): any
	late = late or Late.new()
	local current = 0
	if record and record.support then
		local row = Late.operation(content, record.support)
		for _, effect in if row then row.effects else {} do
			current = if effect.id == "base-performance" then effect.value else current
		end
	end
	local tiers = {}
	for tier = 1, 3 do
		local row = Late.operation(content, "support-tier-" .. tier)
		if row and record then
			local jobId, job = runningJob(late, function(candidate)
				return candidate.target == record.itemId
			end)
			local reason = if jobId then nil else gate(row, tree, M.MAX_RANK, record.completed or {}, coins)
			table.insert(tiers, {
				row = row,
				value = row.effects[1].value,
				status = if (record.completed or {})[row.id]
					then "done"
					elseif jobId then (if job.id == row.id then "running" else "locked")
					elseif reason then "locked"
					else "ready",
				reason = if jobId and job.id ~= row.id
					then "JOB_PENDING"
					elseif reason ~= "ALREADY_COMPLETED" then reason
					else nil,
				jobId = if jobId and job.id == row.id then jobId else nil,
			})
		end
	end
	return { current = current, tiers = tiers, levelGate = 60, level = tree.level }
end

--- Modifier rows eligible for one equipped record, with its two slots' current effects.
function M.modify(content: any, late: any, tree: any, record: any?): any
	late = late or Late.new()
	local rows = {}
	if record then
		for _, row in content.operations or {} do
			if row.kind == "modifier" then
				local eligible = false
				for _, tag in row.eligibleTags or {} do
					eligible = eligible or table.find(record.tags, tag) ~= nil
				end
				if eligible then
					table.insert(rows, { row = row, reason = Tree.gate(tree, row.gates or {}) })
				end
			end
		end
	end
	local slots = {}
	for slot = 1, 2 do
		local effects = if record then (record.modifications or {})[tostring(slot)] else nil
		slots[slot] = if effects and effects[1] then effects[1] else nil
	end
	local jobId, job = runningJob(late, function(candidate)
		return record ~= nil and candidate.target == record.itemId
	end)
	return { rows = rows, slots = slots, jobId = jobId, job = job }
end

return M
