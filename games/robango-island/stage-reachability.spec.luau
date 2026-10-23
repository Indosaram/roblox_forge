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

return {
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
		assert(table.find(failures, "rw.a1.s1.gather:wood@30") ~= nil, "old content must fail the gate")
	end,
}
