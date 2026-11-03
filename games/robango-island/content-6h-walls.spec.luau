--!strict
-- First-6-hours walls (audit6h, Option A): the authored path up to level 50 must be playable from
-- what the live world actually spawns. Sources are the layout resource nodes RoleWorld builds
-- (".chapter." and ".cargo." ids are skipped there), wildlife drops of placed spawns, and recipes
-- or operations whose level, skill-node, station and material-level gates are met. A skill node
-- counts only when its proficiency costs at most SKILL_BUDGET actions in its category. Before
-- the fix every tier-1 tool sat behind ~619 processing actions, c03 deposited an item with no
-- live source, g09 needed a farming_5 sprinkler, g21+g30 needed 5 board deliveries from a
-- 3-contract day, and route 1's first predator stage was a pack of three raptors.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local GuideEvents = require("../../genres/survival-coop/module/GuideEvents")
local Farming = require("../../core/domain/home/Farming")
local SkillTree = require("../../core/domain/progression/SkillTree")

local WINDOW = 50 -- highest guide/chapter level gate on the first-6-hours path (audit6h §2)
local SKILL_BUDGET = 50 -- category actions a player spends on one skill line inside 6 hours (fun-first: no grind)
local RANK3_BUDGET = 20 -- category actions to the rank-3 node of every category

local function load(): any
	return serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
end

-- Category actions to reach `proficiency` (SkillTree.award: the first action gives level 1, then
-- each action adds actionXP against SkillTree.masteryRequired).
local function actions(document: any, proficiency: number): number
	local tree = document.progressionPolicy.tree
	if proficiency <= 1 then
		return 1
	end
	local count, level, xp = 1, 1, 0
	while level < proficiency do
		count += 1
		xp += tree.actionXP
		local required = SkillTree.masteryRequired(tree, level)
		if xp >= required then
			xp -= required
			level += 1
		end
	end
	return count
end

local function byId(rows: { any }): { [string]: any }
	local out = {}
	for _, row in rows or {} do
		out[row.id] = row
	end
	return out
end

-- Items, best material level, the stations built and the recipes craftable at character `level`.
local function world(document: any, level: number): any
	local nodes = byId(document.skillNodes)
	local function skilled(ids: { string }?): boolean
		for _, id in ids or {} do
			local node = nodes[id]
			if not node or actions(document, node.proficiency) > SKILL_BUDGET then
				return false
			end
		end
		return true
	end
	local open: { [string]: boolean } = {}
	for _, section in { "stages", "supportRegions" } do
		for _, row in document[section] do
			if row.gates.characterLevel <= level then
				open[row.layout] = true
			end
		end
	end
	local species = byId(document.wildlifeDetails)
	local have: { [string]: number } = {}
	local function supply(item: string, at: number): boolean
		if (have[item] or -1) < at then
			have[item] = at
			return true
		end
		return false
	end
	local details = byId(document.recipeDetails)
	local craftable: { [string]: boolean } = {}
	local stations: { [string]: number } = {}
	local changed = true
	while changed do
		changed = false
		for _, layout in document.layouts do
			if open[layout.id] then
				-- Authored station anchors (station.<id>.t<tier>) stand in the world already.
				for _, anchor in layout.anchors or {} do
					local id, tier = string.match(anchor.id, "^station%.(.+)%.t(%d)$")
					if id and (stations[id] or 0) < tonumber(tier) :: number then
						stations[id] = tonumber(tier) :: number
						changed = true
					end
				end
				for _, node in layout.resourceNodes do
					local live = not string.find(node.id, ".chapter.", 1, true)
						and not string.find(node.id, ".cargo.", 1, true)
					if
						live
						and (node.tool == nil or have[node.tool] ~= nil)
						and skilled((node.gates or {}).skillNodes)
					then
						changed = supply(node.item, node.level) or changed
					end
				end
				for _, spawn in layout.spawns do
					for _, drop in (species[spawn.speciesId] or {}).dropReservoirs or {} do
						if skilled(if drop.skillNode then { drop.skillNode } else nil) then
							changed = supply(drop.item, spawn.level) or changed
						end
					end
				end
			end
		end
		for _, structure in document.structures do
			local ready = structure.station == true
			for _, cost in structure.cost do
				ready = ready and have[cost.item] ~= nil
			end
			local base = string.gsub(structure.id, "%-t%d$", "")
			if ready and (stations[base] or 0) < (structure.tier or 1) then
				stations[base] = structure.tier or 1
				changed = true
			end
		end
		local steps = {}
		for _, recipe in document.recipes do
			table.insert(steps, { row = recipe, detail = details[recipe.id] or {}, recipe = true })
		end
		for _, operation in document.operations do
			table.insert(steps, { row = operation, detail = operation })
		end
		for _, step in steps do
			local row, detail = step.row, step.detail
			local gates = row.gates or {}
			local ready = (detail.minCharacterLevel or gates.characterLevel or 1) <= level
				and skilled(detail.skillNodes or gates.skillNodes)
				and (row.station == nil or (stations[row.station] or 0) >= (detail.stationTier or row.tier or 1))
			local total, weight = 0, 0
			for _, input in row.inputs do
				local at = have[input.item]
				ready = ready and at ~= nil
				if at and (detail.primaryInputs == nil or table.find(detail.primaryInputs, input.item)) then
					ready = ready and at >= (detail.primaryMaterialLevel or 0)
					total += at * input.quantity
					weight += input.quantity
				end
			end
			if ready then
				if step.recipe and not craftable[row.id] then
					craftable[row.id] = true
					changed = true
				end
				local at = if weight > 0 then math.floor(total / weight) else 1
				for _, output in row.outputs do
					changed = supply(output.item, at) or changed
				end
				if row.kind == "upgrade" and row.station and (stations[row.station] or 0) < (row.tier or 1) then
					stations[row.station] = row.tier
					changed = true
				end
			end
		end
	end
	return { have = have, craftable = craftable, skilled = skilled, open = open }
end

-- The item an objective needs in hand (nil when the step needs no item).
local NEEDS: { [string]: (any) -> string? } = {
	gather = function(o)
		return o.target
	end,
	assemble = function(o)
		return o.target
	end,
	deposit = function(o)
		return o.target
	end,
	eat = function(o)
		return o.target
	end,
	feed = function(o)
		return o.target
	end,
	plant = function(o)
		return o.target .. "-seed"
	end,
	harvest = function(o)
		return o.target .. "-seed"
	end,
	-- GuideEvents: "water" comes only from home-area, which needs the area tool in home storage.
	water = function()
		return Farming.AREA_TOOL
	end,
}

-- Every blocked step on the first-6-hours path, as text.
local function walls(document: any): { string }
	local out = {}
	local cache: { [number]: any } = {}
	local families = byId(document.toolPolicy.families)
	local function check(owner: any)
		local level = owner.gates.characterLevel
		if level > WINDOW then
			return
		end
		cache[level] = cache[level] or world(document, level)
		local w = cache[level]
		for _, objective in owner.objectives do
			local need = NEEDS[objective.action]
			local ok = true
			if need then
				ok = w.have[need(objective) :: any] ~= nil
			elseif objective.action == "craft" then
				ok = w.craftable[objective.target] == true
				for _, member in (families[objective.target] or {}).members or {} do
					for _, recipe in document.recipes do
						ok = ok or (recipe.outputs[1].item == member.item and w.craftable[recipe.id] == true)
					end
				end
			elseif objective.action == "purchase" then
				ok = w.skilled({ objective.target })
			end
			if not ok then
				table.insert(
					out,
					string.format("%s L%d: %s %s", objective.id, level, objective.action, objective.target)
				)
			end
		end
	end
	for _, guide in GuideEvents.visible(document, true) do
		check(guide)
	end
	for _, chapter in document.chapters do
		check(chapter)
	end
	table.sort(out)
	return out
end

return {
	["every first-6-hours guide and chapter step is doable from what the world spawns"] = function()
		local bad = walls(load())
		assert(#bad == 0, "walled steps: " .. table.concat(bad, "; "))
	end,
	["tier-1 recipes accept the material levels the home island mints"] = function()
		local document = load()
		local home: { [string]: number } = {}
		for _, layout in document.layouts do
			if layout.id == "rw.home" then
				for _, node in layout.resourceNodes do
					home[node.item] = math.max(home[node.item] or 0, node.level)
				end
			end
		end
		for _, detail in document.recipeDetails do
			if detail.minCharacterLevel <= 10 then
				for _, item in detail.primaryInputs or {} do
					assert(
						home[item] == nil or home[item] >= detail.primaryMaterialLevel,
						detail.id
							.. " needs "
							.. item
							.. " level "
							.. detail.primaryMaterialLevel
							.. ", home mints "
							.. tostring(home[item])
					)
				end
			end
		end
	end,
	["every spawned node mints a level its material profile declares"] = function()
		-- journey6h on v71: the audit6h explore10 clam node (level 10) crashed every gather with
		-- INVALID_MATERIAL_LEVEL because clam-profile only listed 20 and 30.
		local document = load()
		local levels: { [string]: { number } } = {}
		for _, profile in document.materials do
			levels[profile.item] = profile.levels
		end
		local function walk(value: any)
			if type(value) ~= "table" then
				return
			end
			if
				type(value.id) == "string"
				and type(value.item) == "string"
				and type(value.level) == "number"
				and value.stock ~= nil
			then
				local allowed = levels[value.item]
				assert(
					allowed == nil or table.find(allowed, value.level) ~= nil,
					value.id .. " mints " .. value.item .. " level " .. value.level .. " outside its profile"
				)
			end
			for _, child in value do
				walk(child)
			end
		end
		walk(document)
	end,
	["rank 3 of every skill category is reachable within 100 category actions"] = function()
		local document = load()
		for _, node in document.skillNodes do
			if string.match(node.id, "_3$") then
				local cost = actions(document, node.proficiency)
				assert(cost <= RANK3_BUDGET, node.id .. " proficiency " .. node.proficiency .. " costs " .. cost)
			end
		end
	end,
	["post-onboarding contract guides fit one day's board"] = function()
		local document = load()
		local needed = 0
		for _, guide in document.guides do
			for _, objective in guide.objectives do
				-- Start guides (developmentRank 0) are served by the fixed first-day contracts.
				if objective.action == "deliver" and (guide.gates.developmentRank or 0) > 0 then
					needed += objective.quantity
				end
			end
		end
		assert(needed <= document.contracts.dailyCount, needed .. " deliveries vs " .. document.contracts.dailyCount)
	end,
	["every route 1 stage holds at most one predator"] = function()
		local document = load()
		local species = byId(document.wildlifeDetails)
		for _, layout in document.layouts do
			if string.match(layout.id, "^rw%.a1%.") then
				local predators = 0
				for _, spawn in layout.spawns do
					if species[spawn.speciesId].behaviour == "predator" then
						predators += spawn.count
					end
				end
				assert(predators <= 1, layout.id .. " has " .. predators .. " predators")
			end
		end
	end,
	["every item placed on a skipped chapter node in the window also has a live source"] = function()
		local document = load()
		local w = world(document, WINDOW)
		for _, layout in document.layouts do
			for _, node in if w.open[layout.id] then layout.resourceNodes else {} do
				if string.find(node.id, ".chapter.", 1, true) then
					assert(w.have[node.item] ~= nil, node.id .. ": " .. node.item .. " has no live source")
				end
			end
		end
	end,
	["NEGATIVE: the pre-fix proficiency thresholds, chapter-only samples and sprinkler step are walls"] = function()
		local document = load()
		for _, node in document.skillNodes do
			local rank = tonumber(string.match(node.id, "_(%d)$"))
			local old = ({ [2] = 10, [3] = 20, [4] = 30, [5] = 45, [6] = 60 })[rank or 0]
			if old and not (node.id == "survival_2" or node.id == "melee_2" or node.id == "survival_3") then
				node.proficiency = old
			end
		end
		for _, layout in document.layouts do
			for _, node in layout.resourceNodes do
				node.id = string.gsub(node.id, "%.material%.survey%-sample$", ".chapter.survey-sample")
			end
		end
		for _, guide in document.guides do
			if guide.id == "rw.g09.farming" then
				table.insert(
					guide.objectives,
					4,
					{ id = "rw.g09.farming.4", action = "water", target = "corn", quantity = 1 }
				)
			end
		end
		local text = table.concat(walls(document), "; ")
		for _, expected in { "rw.g09.farming.4", "rw.c02.home-station.2", "rw.c03.grassland-samples.4" } do
			assert(string.find(text, expected, 1, true), expected .. " not reported in: " .. text)
		end
	end,
}
