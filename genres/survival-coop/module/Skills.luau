--!strict
-- Skills: action-based craft mastery for the survival-coop crafting mode.
--
-- Pure, engine-free and clock-free. Disciplines, level thresholds and tool
-- tiers are content data (content.yml `skills` -> SurvivalContent.luau); this
-- module never invents a number. XP is earned only from server-confirmed
-- actions (gather and craft completion), so no client action names an XP value.
--
--   * level(d)     = count of thresholds[d] reached by the discipline's XP
--   * cap(d, tier) = min(#thresholds[d], toolTier + masteryStep[d])
--   * XP beyond the cap's threshold is not banked: it is simply not gained
--   * displayLevel = sum of discipline levels (display only, gates nothing)
--   * respec       = full deterministic refund of every earned XP into an
--                    unspent pool; nothing is lost and nothing is rerolled

local Content = require("../../../core/domain/survival/Content")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")

local M = {}

M.SAVE_VERSION = 1
local MAX_XP = 2 ^ 53 - 1

export type Discipline = { id: string, thresholds: { number }, tools: { [string]: number } }
export type Catalog = { baseStep: number, order: { string }, disciplines: { [string]: Discipline } }
export type Progress = { xp: number, step: number }
export type State = { disciplines: { [string]: Progress }, pool: number }

--- The mastery catalog a content document declares, or nil when the pack has
--- no skills section (every skills path is then inert).
function M.catalog(content: Content.Document): Catalog?
	local skills = content.skills
	if skills == nil then
		return nil
	end
	local result: Catalog = { baseStep = skills.baseStep, order = {}, disciplines = {} }
	for _, entry in skills.disciplines do
		local tools: { [string]: number } = {}
		for _, tool in entry.tools do
			tools[tool.item] = tool.tier
		end
		table.insert(result.order, entry.id)
		result.disciplines[entry.id] = { id = entry.id, thresholds = table.clone(entry.thresholds), tools = tools }
	end
	table.sort(result.order)
	return result
end

function M.new(catalog: Catalog): State
	local state: State = { disciplines = {}, pool = 0 }
	for _, id in catalog.order do
		state.disciplines[id] = { xp = 0, step = catalog.baseStep }
	end
	return state
end

function M.snapshot(state: State): State
	local result: State = { disciplines = {}, pool = state.pool }
	for id, progress in state.disciplines do
		result.disciplines[id] = { xp = progress.xp, step = progress.step }
	end
	return result
end

local function levelOf(discipline: Discipline, xp: number): number
	local level = 0
	for _, threshold in discipline.thresholds do
		if xp >= threshold then
			level += 1
		else
			break
		end
	end
	return level
end

function M.level(catalog: Catalog, state: State, id: string): number
	local discipline = catalog.disciplines[id]
	assert(discipline ~= nil, "UNKNOWN_DISCIPLINE")
	return levelOf(discipline, state.disciplines[id].xp)
end

--- Level cap = tool tier + mastery step, bounded by the declared thresholds.
function M.cap(catalog: Catalog, state: State, id: string, toolTier: number): number
	local discipline = catalog.disciplines[id]
	assert(discipline ~= nil, "UNKNOWN_DISCIPLINE")
	assert(Catalog.integer(toolTier, 0, Content.SKILL_CAPS.tier), "INVALID_TOOL_TIER")
	return math.min(#discipline.thresholds, toolTier + state.disciplines[id].step)
end

--- The highest tier among usable tools in `bag` for discipline `id`. `only`
--- restricts the search to a trusted equipped set when the caller has one.
function M.toolTier(catalog: Catalog, id: string, bag: Inventory.State, only: { [string]: boolean }?): number
	local discipline = catalog.disciplines[id]
	assert(discipline ~= nil, "UNKNOWN_DISCIPLINE")
	local best = 0
	for itemId, item in bag.items do
		local tier = discipline.tools[item.catalogId]
		if
			tier ~= nil
			and (only == nil or only[itemId] == true)
			and (item.durabilityMilli or 0) > 0
			and Inventory.available(bag, itemId) > 0
		then
			best = math.max(best, tier)
		end
	end
	return best
end

local function ceiling(catalog: Catalog, state: State, id: string, toolTier: number): number
	local cap = M.cap(catalog, state, id, toolTier)
	return if cap == 0 then 0 else catalog.disciplines[id].thresholds[cap]
end

--- Awards action XP to one discipline. Returns the new state and the XP
--- actually gained; XP above the current cap's threshold is not gained.
function M.award(catalog: Catalog, state: State, id: string, xp: number, toolTier: number): (State, number)
	assert(catalog.disciplines[id] ~= nil, "UNKNOWN_DISCIPLINE")
	assert(Catalog.integer(xp, 0, Content.SKILL_CAPS.grant), "INVALID_XP")
	local result = M.snapshot(state)
	local progress = result.disciplines[id]
	local gained = math.max(0, math.min(xp, ceiling(catalog, state, id, toolTier) - progress.xp))
	progress.xp += gained
	return result, gained
end

--- Display-only character level: the sum of discipline levels.
function M.displayLevel(catalog: Catalog, state: State): number
	local total = 0
	for _, id in catalog.order do
		total += levelOf(catalog.disciplines[id], state.disciplines[id].xp)
	end
	return total
end

--- Deterministic respec: every discipline's XP returns to the unspent pool in
--- full. Mastery steps are earned separately and are kept. No randomness.
function M.respec(catalog: Catalog, state: State): State
	local result = M.snapshot(state)
	for _, id in catalog.order do
		local progress = result.disciplines[id]
		result.pool += progress.xp
		progress.xp = 0
	end
	return result
end

--- Spends refunded pool XP into one discipline under the same cap as earned XP.
function M.allocate(catalog: Catalog, state: State, id: string, amount: number, toolTier: number): (State?, string?)
	if catalog.disciplines[id] == nil then
		return nil, "UNKNOWN_DISCIPLINE"
	end
	if not Catalog.integer(amount, 1, state.pool) then
		return nil, "INSUFFICIENT_POOL"
	end
	if state.disciplines[id].xp + amount > ceiling(catalog, state, id, toolTier) then
		return nil, "SKILL_CAP"
	end
	local result = M.snapshot(state)
	result.pool -= amount
	result.disciplines[id].xp += amount
	return result, nil
end

--- Awards one content grant to a saved skills record (the crafting save's
--- `skills` field) and returns the updated record. Used by server runtimes that
--- write the personal envelope directly. Unknown/absent grants are no-ops.
function M.grantSaved(
	catalog: Catalog,
	saved: any,
	grant: Content.SkillGrant?,
	bag: Inventory.State,
	only: { [string]: boolean }?
): (any, number)
	if grant == nil then
		return saved, 0
	end
	local state = if saved == nil then M.new(catalog) else M.fromSave(saved, catalog)
	local tier = M.toolTier(catalog, grant.id, bag, only)
	local awarded, gained = M.award(catalog, state, grant.id, grant.xp, tier)
	return M.save(awarded), gained
end

function M.save(state: State): any
	local saved: any = M.snapshot(state)
	saved.saveVersion = M.SAVE_VERSION
	return saved
end

--- Restores a saved state. Disciplines added to content since the save start
--- at zero; a saved discipline the content no longer declares is refused.
function M.fromSave(raw: any, catalog: Catalog): State
	assert(type(raw) == "table" and raw.saveVersion == M.SAVE_VERSION, "UNSUPPORTED_SKILLS_SAVE")
	for key in raw do
		assert(key == "saveVersion" or key == "disciplines" or key == "pool", "UNKNOWN_SKILLS_FIELD")
	end
	assert(Catalog.integer(raw.pool, 0, MAX_XP), "INVALID_SKILLS_POOL")
	assert(type(raw.disciplines) == "table", "INVALID_SKILLS_SAVE")
	local state = M.new(catalog)
	state.pool = raw.pool
	for id, progress in raw.disciplines do
		assert(catalog.disciplines[id] ~= nil, "UNKNOWN_DISCIPLINE")
		assert(type(progress) == "table", "INVALID_SKILL_PROGRESS")
		for key in progress do
			assert(key == "xp" or key == "step", "UNKNOWN_SKILL_FIELD")
		end
		assert(Catalog.integer(progress.xp, 0, MAX_XP), "INVALID_SKILL_XP")
		assert(Catalog.integer(progress.step, catalog.baseStep, Content.SKILL_CAPS.steps), "INVALID_SKILL_STEP")
		state.disciplines[id] = { xp = progress.xp, step = progress.step }
	end
	return state
end

return M
