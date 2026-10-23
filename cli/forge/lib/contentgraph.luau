--!strict
-- Static supply-path proof, not a simulation of simultaneous island stock.
local Operations = require("../../../genres/survival-coop/module/OperationExtension")
local MissionRewards = require("../../../genres/survival-coop/module/MissionRewards")
local M = {}

-- levelReachability budget: every character-level route gate must be reached within this many
-- runs of the content open before it. One run is one full clear of one destination (a support
-- region's wildlife, or a route's stages plus its missions). 12 runs is one 6-hour instability
-- index window (robango-fidelity-contracts R01) at about 30 minutes per run.
M.RUN_BUDGET = 12

local CATEGORIES = {
	"survival",
	"butchering",
	"gathering",
	"processing",
	"weapon_tool",
	"ranged",
	"melee",
	"construction",
	"farming",
	"tailoring",
	"cooking",
	"defense",
}

local function index(rows: { any }): { [string]: any }
	local result = {}
	for _, row in rows do
		result[row.id] = row
	end
	return result
end

local function cycles(edges: { [string]: { string } }): { { string } }
	local result, active, visited, path = {}, {}, {}, {}
	local function visit(id: string)
		if active[id] then
			local cycle = {}
			for i = active[id], #path do
				table.insert(cycle, path[i])
			end
			table.insert(cycle, id)
			table.insert(result, cycle)
			return
		end
		if visited[id] then
			return
		end
		visited[id] = true
		table.insert(path, id)
		active[id] = #path
		local successors: { string } = edges[id] or {}
		for _, nextId in successors do
			visit(nextId)
		end
		active[id] = nil
		table.remove(path)
	end
	local ids = {}
	for id in edges do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		visit(id)
	end
	return result
end

function M.check(document: any): any
	local result: any = {
		schemaVersion = 1,
		counts = {},
		unresolved = {},
		levelFailures = {},
		stationCycles = {},
		skillCycles = {},
		missingEntryActions = {},
		unhandledEntryActions = {},
		rankPrefix = {},
		unplacedSpecies = {},
		levelReachability = {},
		ok = true,
	}
	for _, name in
		{
			"items",
			"recipes",
			"structures",
			"wildlife",
			"materials",
			"operations",
			"recipeDetails",
			"skillCategories",
			"skillNodes",
			"layouts",
			"stages",
			"supportRegions",
			"missions",
			"guides",
			"chapters",
		}
	do
		result.counts[name] = #(document[name] or {})
	end
	if document.version ~= 2 then
		return result
	end
	local details = index(document.recipeDetails or {})
	local wildlife = index(document.wildlifeDetails or {})
	local levels: { [string]: number } = {}
	local placed, speciesLevels = {}, {}
	local function supply(item: string, level: number)
		levels[item] = math.max(levels[item] or 0, level)
	end
	for _, layout in document.layouts or {} do
		for _, node in layout.resourceNodes do
			supply(node.item, node.level)
		end
		for _, spawn in layout.spawns do
			placed[spawn.speciesId] = true
			speciesLevels[spawn.speciesId] = math.max(speciesLevels[spawn.speciesId] or 0, spawn.level)
		end
	end
	for id, level in speciesLevels do
		for _, drop in (wildlife[id] or {}).dropReservoirs or {} do
			supply(drop.item, level)
		end
	end
	-- Material profiles describe levels, not acquisition. Only actual resource,
	-- carcass or auxiliary operation supplies seed the proof.
	local steps = {}
	for _, recipe in document.recipes or {} do
		table.insert(steps, { row = recipe, detail = details[recipe.id] or {} })
	end
	for _, operation in document.operations or {} do
		table.insert(steps, { row = operation, detail = operation })
	end
	local function outputLevel(step: any, available: { [string]: number }): number?
		local total, weight = 0, 0
		local primary = step.detail.primaryInputs
		for _, input in step.row.inputs do
			local level: number? = available[input.item]
			local species = step.detail.sourceSpeciesId
			if species then
				for _, drop in (wildlife[species] or {}).dropReservoirs or {} do
					if drop.item == input.item then
						level = if level then math.min(level, speciesLevels[species] or 0) else nil
					end
				end
			end
			if level == nil then
				return nil
			end
			if primary == nil or table.find(primary, input.item) then
				if level < (step.detail.primaryMaterialLevel or 0) then
					return nil
				end
				total += level * input.quantity
				weight += input.quantity
			end
		end
		local species = step.detail.sourceSpeciesId
		if species and not placed[species] then
			return nil
		end
		return if weight > 0 then math.floor(total / weight) else 1
	end
	local raw = table.clone(levels)
	-- Separate identity closure from level eligibility so diagnostics distinguish
	-- an absent ingredient from an ingredient that exists only below its gate.
	local closure = table.clone(levels)
	local changed = true
	while changed do
		changed = false
		for _, step in steps do
			local ready = true
			for _, input in step.row.inputs do
				ready = ready and closure[input.item] ~= nil
			end
			if ready then
				for _, output in step.row.outputs do
					if closure[output.item] == nil then
						closure[output.item] = 1
						changed = true
					end
				end
			end
		end
	end
	changed = true
	while changed do
		changed = false
		for _, step in steps do
			local level = outputLevel(step, levels)
			if level then
				for _, output in step.row.outputs do
					if level > (levels[output.item] or 0) then
						supply(output.item, level)
						changed = true
					end
				end
			end
		end
	end
	for _, step in steps do
		for _, input in step.row.inputs do
			if closure[input.item] == nil then
				table.insert(result.unresolved, { recipe = step.row.id, item = input.item })
			end
			local available = levels[input.item] or 0
			local species = step.detail.sourceSpeciesId
			if species then
				for _, drop in (wildlife[species] or {}).dropReservoirs or {} do
					if drop.item == input.item then
						available = math.min(available, speciesLevels[species] or 0)
					end
				end
			end
			if
				table.find(step.detail.primaryInputs or {}, input.item)
				and available < (step.detail.primaryMaterialLevel or 0)
			then
				table.insert(result.levelFailures, {
					recipe = step.row.id,
					item = input.item,
					available = available,
					required = step.detail.primaryMaterialLevel,
				})
			end
		end
	end
	-- Re-run supply with deployed station tiers as prerequisites. This respects
	-- alternative producers: one circular producer cannot poison a legal path.
	local stations: { [string]: number } = {}
	local stationSupply = table.clone(raw)
	local function inputsReady(inputs: { any }): boolean
		for _, input in inputs do
			if stationSupply[input.item] == nil then
				return false
			end
		end
		return true
	end
	changed = true
	while changed do
		changed = false
		for _, structure in document.structures or {} do
			if structure.station and not stations[structure.id] and inputsReady(structure.cost) then
				stations[structure.id] = structure.tier or 1
				changed = true
			end
		end
		for _, step in steps do
			local row, detail = step.row, step.detail
			if
				inputsReady(row.inputs)
				and (not row.station or (stations[row.station] or 0) >= (detail.stationTier or row.tier or 1))
			then
				for _, output in row.outputs do
					if not stationSupply[output.item] then
						stationSupply[output.item] = 1
						changed = true
					end
				end
				if row.kind == "upgrade" and row.station and row.tier and row.tier > (stations[row.station] or 0) then
					stations[row.station] = row.tier
					changed = true
				end
			end
		end
	end
	for _, structure in document.structures or {} do
		if structure.station and not stations[structure.id] then
			local blocked = {}
			for _, input in structure.cost do
				if closure[input.item] and not stationSupply[input.item] then
					table.insert(blocked, input.item)
				end
			end
			if #blocked > 0 then
				table.insert(
					result.stationCycles,
					{ station = structure.id, tier = structure.tier or 1, items = blocked }
				)
			end
		end
	end
	for _, step in steps do
		local row = step.row
		if row.kind == "upgrade" and row.station and row.tier and (stations[row.station] or 0) < row.tier then
			local blocked = {}
			for _, input in row.inputs do
				if closure[input.item] and not stationSupply[input.item] then
					table.insert(blocked, input.item)
				end
			end
			if #blocked > 0 then
				table.insert(
					result.stationCycles,
					{ operation = row.id, station = row.station, tier = row.tier, items = blocked }
				)
			end
		end
	end
	local edges = {}
	for _, node in document.skillNodes or {} do
		edges[node.id] = node.prerequisites
	end
	result.skillCycles = cycles(edges)
	local actions = index(document.operations or {})
	for _, recipe in document.recipes or {} do
		actions[recipe.id] = { inputs = recipe.inputs, gates = { skillNodes = (details[recipe.id] or {}).skillNodes } }
	end
	-- Engine actions have no operation row; these exact bootstrap events are
	-- specified by the skill catalog. Authored practice/craft actions must resolve.
	local engineActions = {
		["feeding"] = true,
		["firstjourney"] = true,
		["carcass"] = true,
		["hand"] = true,
		["ranged-hit"] = true,
		["basicclubhit"] = true,
		["settlement-place"] = true,
		["guard-block"] = true,
		-- Home commands award their action id after commit (SurvivalFactory session wrapper).
		["home-place"] = true,
		["home-plant"] = true,
		["home-harvest"] = true,
	}
	local recipeIds = index(document.recipes or {})
	local operationRows = index(document.operations or {})
	local categories = index(document.skillCategories or {})
	for _, category in CATEGORIES do
		local valid = false
		for _, id in (categories[category] or {}).entryActions or {} do
			local action = actions[id]
			if
				engineActions[id]
				or (action and #((action.gates or {}).skillNodes or {}) == 0 and inputsReady(action.inputs))
			then
				valid = true
			end
		end
		if not valid then
			table.insert(result.missingEntryActions, category)
		end
		-- Every entry action must be something the runtime can actually emit: an engine event,
		-- a recipe (craft-complete) or an operation of a kind OperationExtension executes.
		for _, id in (categories[category] or {}).entryActions or {} do
			local operation = operationRows[id]
			if
				not engineActions[id]
				and not recipeIds[id]
				and not (operation and Operations.KINDS[operation.kind or ""])
			then
				table.insert(result.unhandledEntryActions, { category = category, action = id })
			end
		end
	end
	local ranks = {}
	for _, section in { "stages", "supportRegions", "missions", "guides", "chapters", "operations" } do
		for _, row in document[section] or {} do
			local rank = (row.gates or {}).developmentRank or 0
			if rank > 0 then
				ranks[rank] = true
			end
		end
	end
	local rankIds = {}
	for rank in ranks do
		table.insert(rankIds, rank)
	end
	table.sort(rankIds)
	for _, rank in rankIds do
		local completed, available = {}, 0
		changed = true
		while changed do
			changed = false
			for _, guide in document.guides or {} do
				local gate = guide.gates or {}
				local ready = (gate.developmentRank or 0) < rank and not completed[guide.id]
				for _, id in gate.completed or {} do
					ready = ready and completed[id] == true
				end
				for _, objective in guide.objectives do
					if objective.stageId then
						local stage = index(document.stages or {})[objective.stageId]
						ready = ready and stage ~= nil and (stage.gates.developmentRank or 0) < rank
					end
				end
				if ready then
					completed[guide.id] = true
					available += guide.rewards.development or 0
					changed = true
				end
			end
		end
		table.insert(
			result.rankPrefix,
			{ rank = rank, available = available, required = rank * 100, ok = available >= rank * 100 }
		)
	end
	for _, species in document.wildlife or {} do
		if not placed[species.id] then
			table.insert(result.unplacedSpecies, species.id)
		end
	end
	result.levelReachability = M.levelReachability(document)
	for _, name in
		{
			"unresolved",
			"levelFailures",
			"stationCycles",
			"skillCycles",
			"missingEntryActions",
			"unhandledEntryActions",
			"unplacedSpecies",
		}
	do
		result.ok = result.ok and #result[name] == 0
	end
	for _, prefix in result.rankPrefix do
		result.ok = result.ok and prefix.ok
	end
	for _, gate in result.levelReachability do
		result.ok = result.ok and gate.ok
	end
	return result
end

--- Runs needed to reach each route character gate from level 1, greedily taking the richest
--- destination open at the current level. XP counts kills (actionXP + killXP per placed spawn),
--- missions (first clear in full, later clears at MissionRewards.REPEAT_PERMILLE plus the
--- repeat bonus) and one-shot guides and chapters once their level gate opens. Gathering XP is
--- left out, so the bound is conservative. Stages sharing a character gate form one route.
function M.levelReachability(document: any): { any }
	local tree = (document.progressionPolicy or {}).tree
	if not tree or #(document.stages or {}) == 0 then
		return {}
	end
	local layouts = index(document.layouts or {})
	local killXP = tree.actionXP + (tree.killXP or 0)
	local function kills(layoutId: string): number
		local total = 0
		for _, spawn in (layouts[layoutId] or {}).spawns or {} do
			total += (spawn.count or 1) * killXP
		end
		return total
	end
	local destinations: { any } = {}
	for _, region in document.supportRegions or {} do
		table.insert(
			destinations,
			{ level = (region.gates or {}).characterLevel or 1, base = kills(region.layout), missions = {} }
		)
	end
	local stages = index(document.stages)
	local routes: { [number]: any } = {}
	local gates = {}
	for _, stage in document.stages do
		local level = (stage.gates or {}).characterLevel or 1
		if not routes[level] then
			routes[level] = { level = level, base = 0, missions = {}, layouts = {} }
			table.insert(destinations, routes[level])
			table.insert(gates, level)
		end
		local route = routes[level]
		if not route.layouts[stage.layout] then
			route.layouts[stage.layout] = true
			route.base += kills(stage.layout)
		end
	end
	table.sort(gates)
	for _, mission in document.missions or {} do
		local level = 0
		for _, objective in mission.objectives do
			local stage = stages[objective.stageId or ""]
			level = math.max(level, if stage then (stage.gates or {}).characterLevel or 1 else 0)
		end
		if routes[level] then
			table.insert(routes[level].missions, mission)
		end
	end
	local oneShots: { any } = {}
	for _, section in { "guides", "chapters" } do
		for _, row in document[section] or {} do
			table.insert(oneShots, row)
		end
	end
	local level, xp = 1, 0
	local cleared, claimed = {}, {}
	local function add(amount: number)
		xp += amount
		while level < tree.maxLevel and xp >= tree.xpBase + tree.xpStep * level do
			xp -= tree.xpBase + tree.xpStep * level
			level += 1
		end
	end
	local result = {}
	for _, gate in gates do
		local from, runs = level, 0
		while level < gate and runs <= M.RUN_BUDGET do
			for _, row in oneShots do
				if not claimed[row.id] and ((row.gates or {}).characterLevel or 1) <= level then
					claimed[row.id] = true
					add((row.rewards or {}).xp or 0)
				end
			end
			if level >= gate then
				break
			end
			local best, bestXP = nil, 0
			for _, destination in destinations do
				if destination.level <= level then
					local total = destination.base
					for _, mission in destination.missions do
						local reward = (mission.rewards or {}).xp or 0
						total += if cleared[mission.id]
							then reward * MissionRewards.REPEAT_PERMILLE // 1000 + MissionRewards.repeatBonus(
								document,
								level
							)
							else reward
					end
					if total > bestXP then
						best, bestXP = destination, total
					end
				end
			end
			if not best then
				runs = M.RUN_BUDGET + 1
				break
			end
			runs += 1
			add(bestXP)
			for _, mission in best.missions do
				cleared[mission.id] = true
			end
		end
		table.insert(result, {
			gate = gate,
			from = from,
			reached = level,
			runs = runs,
			budget = M.RUN_BUDGET,
			ok = level >= gate and runs <= M.RUN_BUDGET,
		})
	end
	return result
end

return M
