--!strict
-- The player-facing entity names (src/shared/EntityNames.luau) must equal the
-- `entity <id>` rows of locale/strings.csv, and every item, recipe output and
-- structure in the content document must have a name: a missing row shows a raw
-- id such as "brick-floor-kit" in the craft and build sheets, or "berry-bush" on a
-- gather prompt.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local PACK = "games/robango-island"

local function parseCsvLine(line: string): { string }
	local fields: { string } = {}
	local field, quoted, index = "", false, 1
	while index <= #line do
		local char = string.sub(line, index, index)
		if quoted then
			if char == '"' and string.sub(line, index + 1, index + 1) == '"' then
				field ..= '"'
				index += 1
			elseif char == '"' then
				quoted = false
			else
				field ..= char
			end
		elseif char == '"' then
			quoted = true
		elseif char == "," then
			table.insert(fields, field)
			field = ""
		else
			field ..= char
		end
		index += 1
	end
	table.insert(fields, field)
	return fields
end

-- Expected names from strings.csv: item_/structure_ rows by entity id, then recipe_
-- rows (minus the " recipe"/" 제작법" suffix) for outputs no item row names.
local function expected(): { [string]: { en: string, ko: string } }
	local names: { [string]: { en: string, ko: string } } = {}
	local recipes: { { id: string, en: string, ko: string } } = {}
	for _, line in string.split(fs.readFile(PACK .. "/locale/strings.csv"), "\n") do
		line = string.gsub(line, "\r$", "")
		local row = parseCsvLine(line)
		local key, context, en, ko = row[1] or "", row[3] or "", row[4] or "", row[5] or ""
		local recipe = string.match(context, "^entity (.+)%-recipe$")
		local entity = string.match(context, "^entity (.+)$")
		local listing = string.match(context, "^shop listing (.+)$")
		if listing ~= nil and string.sub(key, 1, 5) == "shop_" then
			names["shop:" .. listing] = { en = en, ko = ko }
		end
		local project = string.match(context, "^camp project (.+)$")
		if project ~= nil and string.sub(key, 1, 13) == "camp_project_" then
			names["camp:" .. project] = { en = en, ko = ko }
		end
		if recipe ~= nil and string.sub(key, 1, 7) == "recipe_" then
			table.insert(recipes, {
				id = recipe,
				en = (string.gsub(en, " recipe$", "")),
				ko = (string.gsub(ko, " 제작법$", "")),
			})
		elseif
			entity ~= nil
			and (
				string.sub(key, 1, 5) == "item_"
				or string.sub(key, 1, 10) == "structure_"
				or string.sub(key, 1, 5) == "node_"
			)
		then
			names[entity] = { en = en, ko = ko }
		end
	end
	for _, recipe in recipes do
		if names[recipe.id] == nil then
			names[recipe.id] = { en = recipe.en, ko = recipe.ko }
		end
	end
	return names
end

local function load(locale: string): { [string]: string }
	local chunk = assert(loadstring(fs.readFile(PACK .. "/src/shared/EntityNames.luau")))
	return (chunk() :: any)(locale)
end

return {
	["entity names equal the strings.csv entity rows in both locales"] = function()
		local want = expected()
		local en, ko = load("en-us"), load("ko-kr")
		for id, entry in want do
			assert(en[id] == entry.en, "en name drifted for " .. id .. ": " .. tostring(en[id]))
			assert(ko[id] == entry.ko, "ko name drifted for " .. id .. ": " .. tostring(ko[id]))
		end
		for id in en do
			assert(want[id] ~= nil, "EntityNames has an id strings.csv does not: " .. id)
		end
	end,

	["every item, recipe and structure in content.yml has a player-facing name"] = function()
		local names = load("ko-kr")
		local content = serde.decode("yaml", fs.readFile(PACK .. "/content.yml"))
		local missing: { string } = {}
		local function need(id: string)
			if names[id] == nil then
				table.insert(missing, id)
			end
		end
		for _, item in content.items do
			need(item.id)
		end
		for _, recipe in content.recipes do
			need(recipe.id)
		end
		for _, structure in content.structures do
			need(structure.id)
		end
		-- Gather prompts show the node kind as their object text.
		for _, node in content.nodes or {} do
			need(node.kind or node.id)
		end
		assert(#missing == 0, "ids without a name: " .. table.concat(missing, ", "))
	end,

	["NEGATIVE: a Korean locale never falls back to English"] = function()
		local en, ko = load("en"), load("ko")
		assert(en["brick-floor-kit"] ~= ko["brick-floor-kit"], "ko must differ from en")
	end,
}
