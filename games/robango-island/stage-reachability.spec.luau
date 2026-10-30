--!strict
-- Robango redesign gate: every gather objective of an archipelago stage must be
-- gatherable on that stage's own island at the stage entry level, with a tool
-- whose recipe is craftable by then. a1 is the first route a fresh player is sent to.
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local function load(): any
	return serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
end

local function violations(document: any): { string }
	local layouts, details, failures = {}, {}, {}
	for _, layout in document.layouts do
		layouts[layout.id] = layout
	end
	for _, detail in document.recipeDetails or {} do
		details[detail.id] = detail
	end
	for _, stage in document.stages do
		local entry = stage.gates.characterLevel or 1
		for _, objective in stage.objectives do
			if objective.action == "gather" then
				local found = false
				for _, node in (layouts[stage.layout] or { resourceNodes = {} }).resourceNodes do
					local gate = if node.gates then node.gates.characterLevel or 1 else 1
					local tool = if node.tool then details[node.tool] else nil
					if
						node.item == objective.target
						and (node.level or 1) <= entry
						and gate <= entry
						and (node.tool == nil or (tool ~= nil and (tool.minCharacterLevel or 1) <= entry))
					then
						found = true
					end
				end
				if not found then
					table.insert(failures, stage.id .. ":" .. objective.target .. "@" .. tostring(entry))
				end
			end
		end
	end
	return failures
end

-- C1 first-axe proof on the onboarding island: from a fresh profile (level 1, no skill node,
-- empty bag, no station) the reachable closure over ungated nodes and hand recipes holds an
-- axe-family tool. A node needs its exact tool or a same-family tool of equal or higher tier
-- (ToolTiers.accepts). Returns the order in which items became reachable, or nil.
local function firstAxe(document: any): { string }?
	local layout
	for _, candidate in document.layouts do
		layout = if candidate.id == "rw.onboarding" then candidate else layout
	end
	local tiers: { [string]: { family: string, tier: number } } = {}
	for _, family in document.toolPolicy.families do
		for _, member in family.members do
			tiers[member.item] = { family = family.id, tier = member.tier }
		end
	end
	local have: { [string]: boolean }, order = {}, {}
	local function accepts(required: string): boolean
		for item in have do
			local want, got = tiers[required], tiers[item]
			if item == required or (want and got and want.family == got.family and got.tier >= want.tier) then
				return true
			end
		end
		return false
	end
	local function add(item: string): boolean
		if have[item] then
			return false
		end
		have[item] = true
		table.insert(order, item)
		return true
	end
	local changed = true
	while changed do
		changed = false
		for _, node in layout.resourceNodes do
			local gates = node.gates or {}
			if
				(gates.characterLevel or 1) <= 1
				and #(gates.skillNodes or {}) == 0
				and (node.tool == nil or accepts(node.tool))
			then
				changed = add(node.item) or changed
			end
		end
		for _, recipe in document.recipes do
			local ok = recipe.station == nil
			for _, input in recipe.inputs do
				ok = ok and have[input.item] == true
			end
			if ok then
				for _, output in recipe.outputs do
					changed = add(output.item) or changed
				end
			end
		end
	end
	for item in have do
		if tiers[item] and tiers[item].family == "axe" then
			return order
		end
	end
	return nil
end

local function onboardingNode(document: any, id: string): any
	for _, layout in document.layouts do
		if layout.id == "rw.onboarding" then
			for _, node in layout.resourceNodes do
				if node.id == id then
					return node
				end
			end
		end
	end
	error("missing " .. id)
end

return {
	["C1 a fresh profile reaches the first axe bare-handed on the onboarding island"] = function()
		local document = load()
		local order = assert(firstAxe(document), "no axe reachable from a fresh profile")
		local at: { [string]: number } = {}
		for index, item in order do
			at[item] = index
		end
		assert(at.bone and at.fiber and at["bone-knife"] and at.flint and at["stone-axe"], table.concat(order, ","))
		assert(at.bone < at["bone-knife"] and at["bone-knife"] < at.flint and at.flint < at["stone-axe"], "chain order")
		-- The chain's nodes sit within 30 studs of spawn or of each other (opening-script section 3).
		local carcass = onboardingNode(document, "rw.onboarding.carcass")
		local flint = onboardingNode(document, "rw.onboarding.extra-1")
		local fiber = onboardingNode(document, "rw.onboarding.fiber")
		local function d(a: any, b: any): number
			return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
		end
		local spawn = { x = 0, z = 72 }
		assert(d(carcass.position, spawn) <= 30, "bone heap near spawn")
		assert(d(carcass.position, flint.position) <= 30, "flint scree beside the bone heap")
		assert(d(carcass.position, fiber.position) <= 30, "fiber beside the bone heap")
		assert(flint.tool == "bone-knife" and flint.gates == nil, "flint opens with the bone knife, ungated")
		assert(carcass.tool == nil and carcass.gates == nil and carcass.stock >= 2, "bone heap bare-handed")
	end,
	["NEGATIVE: the old pickaxe and gathering_1 flint gate deadlocks the first axe"] = function()
		local document = load()
		local flint = onboardingNode(document, "rw.onboarding.extra-1")
		flint.tool, flint.gates = "starter-pickaxe", { skillNodes = { "gathering_1" } }
		-- starter-axe needs the workbench; without the station shown, no hand path remains.
		assert(firstAxe(document) == nil, "the old gate must fail the bare-handed proof")
	end,
	["every stage gather objective has a node at or below the stage entry level"] = function()
		local failures = violations(load())
		assert(#failures == 0, "unreachable stage gather objectives: " .. table.concat(failures, ", "))
	end,
	["first route a1 nodes mint the lowest profile material level"] = function()
		-- Node level is the minted material level; on the first route it is the
		-- lowest level the item's material profile allows (1 when unprofiled).
		local document = load()
		local lowest: { [string]: number } = {}
		for _, profile in document.materials do
			lowest[profile.item] = math.min(table.unpack(profile.levels))
		end
		for _, layout in document.layouts do
			if string.match(layout.id, "^rw%.a1%.s%d$") then
				for _, node in layout.resourceNodes do
					local floor = lowest[node.item] or 1
					assert(node.level == floor, node.id .. " level " .. tostring(node.level) .. " on the first route")
				end
			end
		end
	end,
	["the gate rejects a1.s1 wood above the route entry level"] = function()
		local document = load()
		for _, layout in document.layouts do
			if layout.id == "rw.a1.s1" then
				for _, node in layout.resourceNodes do
					if node.id == "rw.a1.s1.material.wood" then
						node.level = 31
					end
				end
			end
		end
		local failures = violations(document)
		assert(table.find(failures, "rw.a1.s1.gather:wood@2") ~= nil, "old content must fail the gate")
	end,
}
