--!strict
-- Player-facing pack copy read from locale/strings.csv, which ships once as the
-- LocalizationTable Forge.games["robango-island"].Strings (default.project.json). The client
-- passes its GetEntries(); Lune specs pass the parsed CSV rows, so there is no mirrored table.
export type Row = { key: string, context: string, en: string, ko: string }
local M = {}

--- Rows from LocalizationTable:GetEntries() ({ Key, Context, Values = { ["en-us"], ["ko-kr"] } }).
function M.fromEntries(entries: { any }): { Row }
	local rows: { Row } = {}
	for _, entry in entries do
		local values = entry.Values or {}
		table.insert(rows, {
			key = entry.Key,
			context = entry.Context or "",
			en = values["en-us"] or "",
			ko = values["ko-kr"] or "",
		})
	end
	return rows
end

--- Rows from Strings.parseCsv(strings.csv).rows (Key, Source, Context, en-us, ko-kr).
function M.fromCsvRows(csv: { { string } }): { Row }
	local rows: { Row } = {}
	for _, row in csv do
		table.insert(rows, { key = row[1] or "", context = row[3] or "", en = row[4] or "", ko = row[5] or "" })
	end
	return rows
end

--- Authored journal and mission NPC lines (rw.* keys): (locale, key) -> text or nil.
function M.authored(rows: { Row }): (string, string) -> string?
	local lines: { [string]: Row } = {}
	for _, row in rows do
		if string.sub(row.key, 1, 3) == "rw." then
			lines[row.key] = row
		end
	end
	return function(locale: string, key: string): string?
		local row = lines[key]
		return if row then (if string.sub(locale, 1, 2) == "ko" then row.ko else row.en) else nil
	end
end

--- Entity names by id: item_/structure_/node_ `entity <id>` rows, recipe_ rows (minus the
--- " recipe"/" 제작법" suffix) for outputs no entity row names, and shop:/shopdesc:/camp: rows.
function M.names(rows: { Row }): (string) -> { [string]: string }
	return function(locale: string): { [string]: string }
		local korean = string.sub(string.lower(locale), 1, 2) == "ko"
		local out: { [string]: string } = {}
		local recipes: { { string } } = {}
		for _, row in rows do
			local key, context = row.key, row.context
			local text = if korean then row.ko else row.en
			local listing = string.match(context, "^shop listing (.+)$")
			if listing and string.sub(key, 1, 5) == "shop_" then
				out["shop:" .. listing] = text
			end
			local described = string.match(context, "^shop description (.+)$")
			if described and string.sub(key, 1, 10) == "shop_desc_" then
				out["shopdesc:" .. described] = text
			end
			local project = string.match(context, "^camp project (.+)$")
			if project and string.sub(key, 1, 13) == "camp_project_" then
				out["camp:" .. project] = text
			end
			local recipe = string.match(context, "^entity (.+)%-recipe$")
			local entity = string.match(context, "^entity (.+)$")
			if recipe and string.sub(key, 1, 7) == "recipe_" then
				table.insert(recipes, { recipe, (string.gsub(text, if korean then " 제작법$" else " recipe$", "")) })
			elseif
				entity
				and (
					string.sub(key, 1, 5) == "item_"
					or string.sub(key, 1, 10) == "structure_"
					or string.sub(key, 1, 5) == "node_"
				)
			then
				out[entity] = text
			end
		end
		for _, recipe in recipes do
			if out[recipe[1]] == nil then
				out[recipe[1]] = recipe[2]
			end
		end
		return out
	end
end

return M
