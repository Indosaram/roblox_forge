--!strict
-- Robango redesign gate: every archipelago stage opens on a readable trail. From the
-- trail spawn the stage objective nodes and at least six gather nodes sit 25-90 studs
-- away, never stacked, and the arrival view holds a gather node, a landmark and a
-- creature within 60 studs plus enough dressing that no stretch reads as empty field.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Dressing = require("./src/server/WorldDressing")

local function load(): any
	return serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
end

local function flat(a: any, b: any): number
	return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

local function ledger(node: any): boolean
	return string.find(node.id, ".cargo.", 1, true) ~= nil or string.find(node.id, ".chapter.", 1, true) ~= nil
end

-- Items a stage's objectives send the player to gather on this island.
local function objectiveItems(document: any, layoutId: string): { [string]: boolean }
	local items: { [string]: boolean } = {}
	local recipes: { [string]: any } = {}
	for _, recipe in document.recipes do
		recipes[recipe.id] = recipe
	end
	for _, stage in document.stages do
		if stage.layout == layoutId then
			for _, objective in stage.objectives do
				if objective.action == "gather" or objective.action == "transport" then
					items[objective.target] = true
				elseif objective.action == "craft" and recipes[objective.target] then
					for _, input in recipes[objective.target].inputs do
						items[input.item] = true
					end
				end
			end
		end
	end
	return items
end

local function violations(document: any): ({ string }, number)
	local failures, checked = {}, 0
	for _, layout in document.layouts do
		local head = Dressing.trailhead(layout)
		if not head then
			continue
		end
		checked += 1
		local spawn = head.position
		local items = objectiveItems(document, layout.id)
		local nearestObjective, gatherNear, nearestGather = math.huge, 0, math.huge
		for index, node in layout.resourceNodes do
			local d = flat(node.position, spawn)
			if items[node.item] or string.find(node.id, ".material.", 1, true) then
				nearestObjective = math.min(nearestObjective, d)
			end
			if d < 25 or d > 90 then
				table.insert(failures, string.format("%s %s is %.0f studs from spawn", layout.id, node.id, d))
			end
			if not ledger(node) then
				nearestGather = math.min(nearestGather, d)
				if d <= 90 then
					gatherNear += 1
				end
			end
			for other = index + 1, #layout.resourceNodes do
				local gap = flat(node.position, layout.resourceNodes[other].position)
				if gap < 6 then
					table.insert(
						failures,
						string.format("%s %s stacked with %s", layout.id, node.id, layout.resourceNodes[other].id)
					)
				end
			end
		end
		if nearestObjective > 90 then
			table.insert(failures, string.format("%s objective node %.0f studs away", layout.id, nearestObjective))
		end
		if gatherNear < 6 then
			table.insert(failures, layout.id .. " has " .. gatherNear .. " gather nodes within 90")
		end
		if nearestGather > 60 then
			table.insert(failures, layout.id .. " no gather node within 60 of the spawn camera")
		end
		-- Dressing density, measured on the production dressing plan.
		local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
		local landmark, creature = math.huge, math.huge
		local kits: { [string]: boolean } = {}
		local kitCount = 0
		for _, part in plan.parts do
			local root = part.ground or part.position
			local d = flat(root, spawn)
			if
				string.find(part.id, "landmark", 1, true)
				or (layout.art and string.find(part.id, layout.art.landmark.id, 1, true))
			then
				landmark = math.min(landmark, d)
			end
			local kit = string.match(part.id, "^(.+)%.[^.]+$") or part.id
			if d <= 90 and not kits[kit] then
				kits[kit] = true
				kitCount += 1
			end
		end
		for _, animal in plan.fauna or {} do
			creature = math.min(creature, flat(animal.position, spawn))
		end
		for _, authored in layout.spawns do
			creature = math.min(creature, flat(authored.position, spawn))
		end
		if landmark > 60 then
			table.insert(failures, string.format("%s nearest landmark %.0f studs", layout.id, landmark))
		end
		if creature > 60 then
			table.insert(failures, string.format("%s nearest creature %.0f studs", layout.id, creature))
		end
		if kitCount < 8 then
			table.insert(failures, layout.id .. " only " .. kitCount .. " dressing kits within 90 studs")
		end
	end
	return failures, checked
end

return {
	["every archipelago stage opens on a dense readable trail"] = function()
		local document = load()
		local failures, checked = violations(document)
		assert(checked == 20, "all 20 archipelago layouts checked, got " .. checked)
		local stages = 0
		for _, stage in document.stages do
			stages += if string.match(stage.layout, "^rw%.a%d+%.s%d+$") then 1 else 0
		end
		assert(stages == 40, "all 40 archipelago stages covered, got " .. stages)
		assert(#failures == 0, table.concat(failures, "\n"))
	end,
	["NEGATIVE: a far yard, stacked nodes and a bare arrival are detected"] = function()
		local document = load()
		local layout
		for _, candidate in document.layouts do
			if candidate.id == "rw.a1.s1" then
				layout = candidate
			end
		end
		for index, node in layout.resourceNodes do
			node.position = { x = -300 + (index % 2) * 2, y = 4, z = 0 }
		end
		layout.spawns = {}
		local failures = violations(document)
		local text = table.concat(failures, "\n")
		assert(string.find(text, "rw.a1.s1 objective node", 1, true), "far objective")
		assert(string.find(text, "gather nodes within 90", 1, true), "sparse gather")
		assert(string.find(text, "stacked", 1, true), "stacked nodes")
	end,
}
