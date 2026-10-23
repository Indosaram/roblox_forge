--!strict
-- Deterministic single-player pacing driver for survival-coop `crafting` packs (robango).
-- A scripted new player gathers at authored layout nodes (stock = charges, yield per gather,
-- respawn to full stock), crafts by recipe inputs and craftMillis, places station kits,
-- clears guides (development plus the declared xp/coins/items once per guide), delivers
-- first-day and daily contracts, runs archipelago index-1 expeditions whose missions pay
-- through the MissionRewards rule (first clear full, repeat REPEAT_PERMILLE), sells surplus raw
-- at the harbor buyback (core Buyback, shared daily cap) and pays Job.repairCost for weapon
-- repairs. It never spends Robux. Time is an explicit simulated clock in seconds; every random
-- draw comes from Rng.new(seed) forks. Action durations that the content does not author are
-- named ASSUMPTIONS and reported in the JSON.
local Rng = require("../../../core/domain/random/Rng")
local Buyback = require("../../../core/domain/market/Buyback")
local Job = require("../../../core/domain/crafting/Job")
local MissionRewards = require("../../../genres/survival-coop/module/MissionRewards")

local M = {}

M.ASSUMPTIONS = {
	gatherSeconds = 3, -- one swing plus a short walk between authored nodes (+0..2 s jitter)
	placeSeconds = 5, -- place a station kit
	restSeconds = 10, -- guide g03 rest mat
	harborTripSeconds = 60, -- walk/travel to the harbor and back
	travelSeconds = 60, -- archipelago departure or return
	stageMoveSeconds = 30, -- move between expedition stages
	surveyWalkSeconds = 15, -- walk to a survey point (plus missionPolicy.surveySeconds)
	rescueSeconds = 30,
	huntApproachSeconds = 20,
	repairBelowPermille = 300, -- repair the club when durability drops under 30%
	keepRaw = 40, -- raw units kept before selling surplus
	contractSeconds = 10, -- walk to the contract board and deliver
}

M.HOME_LAYOUT = "rw.home"
M.EXPEDITION_LAYOUT = "rw.a1.s1"
M.WEAPON = "starter-club"

export type Options = { seed: number, hours: number, startingBalance: number?, starter: { any }? }

local function sortedIds(map: { [string]: any }): { string }
	local ids = {}
	for id in map do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function M.simulate(content: any, options: Options): { [string]: any }
	local A = M.ASSUMPTIONS
	local rng = Rng.new(options.seed)
	local jitter = rng:fork("action-jitter")
	local contractRng = rng:fork("daily-contracts")
	local limit = options.hours * 3600
	local tree = content.progressionPolicy.tree

	local now = 0
	local bag: { [string]: number } = {}
	for _, stack in options.starter or {} :: { any } do
		bag[stack.catalogId] = (bag[stack.catalogId] or 0) + stack.quantity
	end
	local placed: { [string]: boolean } = {}
	local tools: { [string]: { durability: number, maximum: number } } = {}
	local level, xp, totalXP = 1, 0, 0
	local balance = options.startingBalance or 0
	local faucets = { starting = balance, missions = 0, contracts = 0, buyback = 0, guides = 0 }
	local sinks = { repair = 0 }
	local counts = {
		gathers = 0,
		crafts = 0,
		expeditions = 0,
		missionClears = 0,
		repeatClears = 0,
		repairs = 0,
		weaponRecrafts = 0,
	}
	local milestones: { [string]: any } = {}
	local devPoints = 0
	local devDefinitions: { [string]: boolean } = {}
	local hourly = {}
	local nextHour = 3600
	local buyState: any = nil

	local function mark(name: string)
		if milestones[name] == nil then
			milestones[name] = now
		end
	end

	local function snapshotHours()
		while now >= nextHour and #hourly < options.hours do
			table.insert(hourly, {
				hour = #hourly + 1,
				coins = balance,
				xp = totalXP,
				level = level,
				faucets = table.clone(faucets),
				sinks = table.clone(sinks),
			})
			nextHour += 3600
		end
	end

	local function advance(seconds: number)
		now += seconds
		snapshotHours()
	end

	local function grantXP(amount: number)
		totalXP += amount
		xp += amount
		while level < tree.maxLevel do
			local required = tree.xpBase + tree.xpStep * level
			if xp < required then
				break
			end
			xp -= required
			level += 1
		end
		if level >= 5 then
			mark("level5")
		end
		if level >= 10 then
			mark("level10")
		end
		if level >= 20 then
			mark("level20")
		end
		if level >= 30 then
			mark("level30")
		end
	end

	-- Layout nodes become runtime gather nodes exactly as RoleWorld does (charges = stock).
	local function layoutNodes(layoutId: string): { any }
		local result = {}
		for _, layout in content.layouts do
			if layout.id == layoutId then
				for _, node in layout.resourceNodes do
					table.insert(result, {
						id = node.id,
						item = node.item,
						yield = node.yield,
						stock = node.stock,
						charges = node.stock,
						respawn = node.respawnSeconds,
						tool = node.tool,
						deadline = nil :: number?,
					})
				end
			end
		end
		return result
	end
	local home = layoutNodes(M.HOME_LAYOUT)

	local recipesByOutput: { [string]: { any } } = {}
	for _, recipe in content.recipes do
		for _, output in recipe.outputs do
			recipesByOutput[output.item] = recipesByOutput[output.item] or {}
			table.insert(recipesByOutput[output.item], recipe)
		end
	end
	local recipeById: { [string]: any } = {}
	for _, recipe in content.recipes do
		recipeById[recipe.id] = recipe
	end
	local details: { [string]: any } = {}
	for _, detail in content.recipeDetails or {} do
		details[detail.id] = detail
	end
	local itemDefs: { [string]: any } = {}
	for _, item in content.items do
		itemDefs[item.id] = item
	end

	local function nodeFor(nodes: { any }, item: string): any
		for _, node in nodes do
			if node.item == item then
				return node
			end
		end
		return nil
	end

	local function recipeFor(item: string): any
		local best: any = nil
		for _, recipe in recipesByOutput[item] or {} :: { any } do
			-- Legacy recipes stay for old saves; a new player uses the authored one.
			local legacy = string.sub(recipe.id, 1, 7) == "legacy-"
			if not legacy and (best == nil or recipe.id < best.id) then
				best = recipe
			end
		end
		return best
	end

	-- Static check (no side effects): can the scripted player make `item` from home nodes?
	local function obtainable(item: string, depth: number): boolean
		if depth > 8 then
			return false
		end
		local node = nodeFor(home, item)
		if node then
			return node.tool == nil or obtainable(node.tool, depth + 1)
		end
		local recipe = recipeFor(item)
		if recipe == nil then
			return false
		end
		local detail = details[recipe.id]
		if detail and (detail.minCharacterLevel > level or #detail.skillNodes > 0) then
			return false
		end
		if recipe.station and not placed[recipe.station] and not obtainable(recipe.station .. "-kit", depth + 1) then
			return false
		end
		for _, input in recipe.inputs do
			if not obtainable(input.item, depth + 1) then
				return false
			end
		end
		return true
	end

	local obtain: (item: string, quantity: number) -> ()

	local function awardCraft(recipeId: string)
		for _, category in content.skillCategories do
			local matches = table.find(category.entryActions, recipeId) ~= nil
			local detail = details[recipeId]
			for _, node in if detail then detail.skillNodes else {} do
				matches = matches or string.match(node, "^(.*)_%d+$") == category.id
			end
			if matches then
				grantXP(tree.actionXP)
			end
		end
	end

	local function gather(nodes: { any }, item: string)
		local node = assert(nodeFor(nodes, item), "no authored node yields " .. item)
		if node.tool and not tools[node.tool] then
			obtain(node.tool, 1)
		end
		if node.charges == 0 then
			advance(math.max(0, (node.deadline :: number) - now))
			node.charges = node.stock
			node.deadline = nil
		end
		advance(A.gatherSeconds + jitter:nextInteger(0, 2))
		node.charges -= 1
		if node.charges == 0 then
			node.deadline = now + node.respawn
		end
		bag[item] = (bag[item] or 0) + node.yield
		counts.gathers += 1
		grantXP(tree.actionXP)
	end

	local function place(station: string)
		obtain(station .. "-kit", 1)
		bag[station .. "-kit"] -= 1
		advance(A.placeSeconds)
		placed[station] = true
		mark(station)
	end

	local function craft(recipe: any)
		local detail = details[recipe.id]
		assert(detail == nil or detail.minCharacterLevel <= level, "level gate for " .. recipe.id)
		if recipe.station and not placed[recipe.station] then
			place(recipe.station)
		end
		for _, input in recipe.inputs do
			obtain(input.item, input.quantity)
		end
		for _, input in recipe.inputs do
			bag[input.item] -= input.quantity
		end
		advance(recipe.craftMillis / 1000)
		for _, output in recipe.outputs do
			bag[output.item] = (bag[output.item] or 0) + output.quantity
			local def = itemDefs[output.item]
			if def and def.maxDurabilityMilli and not tools[output.item] then
				tools[output.item] = { durability = def.maxDurabilityMilli, maximum = def.maxDurabilityMilli }
			end
		end
		counts.crafts += 1
		awardCraft(recipe.id)
		mark("craft:" .. recipe.id)
	end

	obtain = function(item: string, quantity: number)
		while (bag[item] or 0) < quantity do
			if nodeFor(home, item) then
				gather(home, item)
			else
				local recipe = recipeFor(item)
				assert(recipe ~= nil, "no recipe or node for " .. item)
				craft(recipe)
			end
		end
	end

	-- Guide completion: development (SurvivalFactory.recordDevelopment) plus the declared
	-- xp/coins/items once per guide (MissionRewards.enqueueGuide outbox).
	local function guideDone(id: string)
		if not devDefinitions[id] then
			devDefinitions[id] = true
			for _, guide in content.guides do
				if guide.id == id then
					devPoints += guide.rewards.development or 0
					balance += guide.rewards.coins or 0
					faucets.guides += guide.rewards.coins or 0
					for _, stack in guide.rewards.items or {} do
						bag[stack.item] = (bag[stack.item] or 0) + stack.quantity
					end
					grantXP(guide.rewards.xp or 0)
				end
			end
		end
	end

	local function grade(): number
		return math.min(10, devPoints // 100)
	end

	local function deliverContract(entry: any)
		for _, need in entry.deliver do
			obtain(need.item, need.quantity)
		end
		for _, need in entry.deliver do
			bag[need.item] -= need.quantity
		end
		for _, reward in entry.reward or {} do
			bag[reward.item] = (bag[reward.item] or 0) + reward.quantity
		end
		advance(A.contractSeconds)
		balance += entry.coins or 0
		faucets.contracts += entry.coins or 0
	end

	local prices: { [string]: number } = {}
	for _, row in content.harborPolicy.buyback do
		prices[row.item] = row.price
	end
	local policy: Buyback.Policy = {
		prices = prices,
		dailyUnits = content.harborPolicy.dailyUnits,
		daySeconds = content.harborPolicy.daySeconds,
	}

	local function sellSurplus()
		local remaining = Buyback.remaining(policy, buyState, now)
		if remaining == 0 then
			return
		end
		local sold = false
		for _, id in sortedIds(prices) do
			local surplus = math.min((bag[id] or 0) - A.keepRaw, Buyback.remaining(policy, buyState, now))
			if surplus > 0 then
				local coins, nextState = Buyback.sell(policy, buyState, id, surplus, now)
				if coins then
					buyState = nextState
					bag[id] -= surplus
					balance += coins
					faucets.buyback += coins
					sold = true
				end
			end
		end
		if sold then
			advance(A.harborTripSeconds)
		end
	end

	local repairOperation: any = nil
	for _, operation in content.operations or {} do
		if operation.kind == "repair" then
			repairOperation = operation
		end
	end
	-- item-repair (HarborBuybackExtension) repairs a durable item only when it carries one of
	-- the repair operation's eligibleTags.
	local repairEligible = repairOperation ~= nil
		and itemDefs[M.WEAPON] ~= nil
		and (itemDefs[M.WEAPON].maxDurabilityMilli or 0) > 0
	if repairEligible and repairOperation.eligibleTags ~= nil then
		local matched = false
		for _, tag in repairOperation.eligibleTags do
			matched = matched or table.find(itemDefs[M.WEAPON].tags or {}, tag) ~= nil
		end
		repairEligible = matched
	end

	local function maybeRepair()
		local tool = tools[M.WEAPON]
		if tool == nil or tool.durability * 1000 >= tool.maximum * A.repairBelowPermille then
			return
		end
		local cost = if repairOperation then Job.repairCost(repairOperation, M.WEAPON) else 0
		if repairEligible and balance >= cost then
			balance -= cost
			sinks.repair += cost
			counts.repairs += 1
			tool.maximum -= math.max(1, tool.maximum // 10)
			tool.durability = tool.maximum
			advance(repairOperation.seconds or 5)
		elseif tool.durability == 0 then
			-- Not repairable (or no Coins): a broken weapon is recrafted from materials.
			tools[M.WEAPON] = nil
			bag[M.WEAPON] = 0
			counts.weaponRecrafts += 1
			obtain(M.WEAPON, 1)
		end
	end

	local missionPolicy = content.missionPolicy
	local wildlife: { [string]: any } = {}
	for _, row in content.wildlifeDetails or {} do
		wildlife[row.id] = row
	end

	local expeditionNodes: { any } = {}
	local function runObjective(objective: any)
		local action, target = objective.action, objective.target
		if action == "gather" or action == "transport" then
			local nodes = if nodeFor(expeditionNodes, target) then expeditionNodes else home
			local start = bag[target] or 0
			while (bag[target] or 0) - start < objective.quantity do
				gather(nodes, target)
			end
			if action == "transport" then
				-- Delivered cargo leaves the bag.
				bag[target] = start
			end
			return
		end
		for _ = 1, objective.quantity do
			if action == "craft" then
				local recipe = recipeById[target]
				assert(recipe ~= nil, "unknown craft target " .. target)
				craft(recipe)
			elseif action == "survey" then
				advance(A.surveyWalkSeconds + missionPolicy.surveySeconds)
			elseif action == "rescue" then
				advance(A.rescueSeconds)
			elseif action == "hunt" then
				obtain(M.WEAPON, 1)
				local species = assert(wildlife[target], "unknown species " .. target)
				local hits = math.ceil(species.health * 1000 / missionPolicy.weaponDamageMilli)
				advance(A.huntApproachSeconds)
				for _ = 1, hits do
					advance(missionPolicy.weaponCooldownMillis / 1000)
					local tool = tools[M.WEAPON]
					tool.durability = math.max(0, tool.durability - missionPolicy.weaponWearMilli)
				end
				-- WildlifeRuntime awards melee (actionXP) plus killXP once per kill, never per hit.
				grantXP(tree.actionXP + (tree.killXP or 0))
			else
				advance(A.stageMoveSeconds)
			end
		end
	end

	local function runExpedition(index: number): boolean
		local missions = {}
		for _, mission in content.missions do
			if string.match(mission.id, "^rw%.m(%d+)%.") == tostring(index) then
				local gates = mission.gates or {}
				if level >= (gates.characterLevel or 1) and grade() >= (gates.developmentRank or 0) then
					table.insert(missions, mission)
				end
			end
		end
		if #missions == 0 then
			return false
		end
		expeditionNodes = layoutNodes(M.EXPEDITION_LAYOUT)
		advance(A.travelSeconds)
		counts.expeditions += 1
		for _, mission in missions do
			for _, objective in mission.objectives do
				advance(A.stageMoveSeconds)
				runObjective(objective)
			end
			local repeatClear = devDefinitions[mission.id] == true
			local permille = if repeatClear then MissionRewards.REPEAT_PERMILLE else 1000
			local coins = ((mission.rewards.coins or 0) * permille) // 1000
			balance += coins
			faucets.missions += coins
			local bonus = if repeatClear then MissionRewards.repeatBonus(content, level) else 0
			grantXP(((mission.rewards.xp or 0) * permille) // 1000 + bonus)
			if not repeatClear then
				devDefinitions[mission.id] = true
				devPoints += mission.rewards.development or 0
				counts.missionClears += 1
			else
				counts.repeatClears += 1
			end
			mark("firstMission")
		end
		advance(A.travelSeconds)
		return true
	end

	-- Scripted session ---------------------------------------------------------------
	-- Tutorial order (design.md section 9): gather -> stone axe -> camp -> first contract.
	local g01: { { item: string, quantity: number } } =
		{ { item = "branch", quantity = 5 }, { item = "stone", quantity = 3 }, { item = "fiber", quantity = 3 } }
	for _, need in g01 do
		-- Guide g01 counts gathered units, not bag stock, so the starter fiber does not count.
		local start = bag[need.item] or 0
		while (bag[need.item] or 0) - start < need.quantity do
			gather(home, need.item)
		end
	end
	guideDone("rw.g01.first-gather")
	obtain("stone-axe", 1)
	mark("stoneAxe")
	guideDone("rw.g02.first-axe")
	obtain("campfire-kit", 1)
	place("campfire")
	advance(A.restSeconds)
	assert(recipeById["dry-twig"] ~= nil, "dry-twig recipe")
	craft(recipeById["dry-twig"])
	for _, entry in content.contracts.entries do
		if entry.pool == "first-day" then
			deliverContract(entry)
			guideDone("rw.g03.first-contract")
		end
	end
	-- The first camp donation (guide g04) happens with the windbreak delivery below.
	guideDone("rw.g04.camp-donation")
	-- Camp ladder rung 1.
	for _, project in content.camp.projects do
		if project.id == "windbreak" then
			for _, cost in project.cost do
				obtain(cost.item, cost.quantity)
			end
			for _, cost in project.cost do
				bag[cost.item] -= cost.quantity
			end
			mark("windbreak")
		end
	end
	-- Daily contracts for day 1: dailyCount entries drawn with the recorded seed.
	local daily = {}
	for _, entry in content.contracts.entries do
		if entry.pool == "daily" then
			table.insert(daily, entry)
		end
	end
	local delivered = {}
	for _ = 1, math.min(content.contracts.dailyCount, #daily) do
		local pick = table.remove(daily, contractRng:nextInteger(1, #daily))
		local ok = true
		for _, need in pick.deliver do
			ok = ok and obtainable(need.item, 0)
		end
		if ok then
			deliverContract(pick)
			table.insert(delivered, pick.id)
		end
	end
	-- Main loop: expedition, then sell surplus and repair; grind gathering while gated.
	while now < limit do
		if not runExpedition(1) then
			gather(home, "branch")
		end
		sellSurplus()
		maybeRepair()
	end
	snapshotHours()
	-- The last action may end past the limit; report totals as of the final hour boundary.
	local last = hourly[#hourly]
	local lastFaucets = last.faucets

	local outMilestones: { [string]: any } = {}
	for _, name in { "stoneAxe", "campfire", "windbreak", "firstMission", "level5", "level10", "level20", "level30" } do
		local at = milestones[name]
		outMilestones[name] = if at ~= nil and at <= limit then { seconds = at, minutes = at / 60 } else nil
	end
	outMilestones.outpost = {
		reached = false,
		reason = "outpost capture needs a clan team of " .. tostring(content.outpostPolicy.minTeam) .. "-" .. tostring(
			content.outpostPolicy.maxTeam
		) .. " players; a solo driver cannot reach it",
	}
	local craftOrder = {}
	for name, at in milestones do
		if string.sub(name, 1, 6) == "craft:" then
			table.insert(craftOrder, { id = string.sub(name, 7), seconds = at })
		end
	end
	table.sort(craftOrder, function(a, b)
		return if a.seconds == b.seconds then a.id < b.id else a.seconds < b.seconds
	end)
	local stations = {}
	for _, id in sortedIds(placed) do
		table.insert(stations, { id = id, seconds = milestones[id] })
	end

	return {
		schemaVersion = 1,
		mode = "crafting",
		seed = options.seed,
		hours = options.hours,
		assumptions = table.clone(A),
		robuxSpent = 0,
		hourly = hourly,
		milestones = outMilestones,
		firstCrafts = craftOrder,
		stations = stations,
		dailyContracts = delivered,
		final = { coins = last.coins, xp = last.xp, level = last.level, developmentPoints = devPoints },
		faucets = lastFaucets,
		sinks = last.sinks,
		faucetTotal = lastFaucets.starting
			+ lastFaucets.missions
			+ lastFaucets.contracts
			+ lastFaucets.buyback
			+ lastFaucets.guides,
		sinkTotal = last.sinks.repair,
		repairEligible = repairEligible,
		counts = counts,
	}
end

return M
