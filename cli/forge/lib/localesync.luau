--!strict
-- LocaleSync: offline payload builder for the Roblox Localization Tables API.
-- Reads the pack's locale/strings.csv (same grammar as
-- cli/forge/commands/locale.luau) and emits entries carrying key, source,
-- context, and one translation per locale column. No network calls.

local M = {}

export type Entry = {
	key: string,
	source: string,
	context: string,
	translations: { [string]: string },
}

export type Payload = {
	entries: { Entry },
	locales: { string },
}

local REQUIRED_COLUMNS = { "Key", "Source", "Context" }

local function trim(value: string): string
	return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

--- Minimal RFC4180-ish CSV reader: quoted fields, doubled quotes, CRLF or LF.
--- Mirrors the reader in cli/forge/commands/locale.luau.
local function parseCsv(text: string): { { string } }
	local rows: { { string } } = {}
	local row: { string } = {}
	local field: { string } = {}
	local index = 1
	local length = #text
	local inQuotes = false

	local function pushField()
		table.insert(row, table.concat(field))
		field = {}
	end

	local function pushRow()
		pushField()
		table.insert(rows, row)
		row = {}
	end

	while index <= length do
		local char = string.sub(text, index, index)
		if inQuotes then
			if char == '"' then
				if string.sub(text, index + 1, index + 1) == '"' then
					table.insert(field, '"')
					index += 2
				else
					inQuotes = false
					index += 1
				end
			else
				table.insert(field, char)
				index += 1
			end
		elseif char == '"' then
			inQuotes = true
			index += 1
		elseif char == "," then
			pushField()
			index += 1
		elseif char == "\n" then
			pushRow()
			index += 1
		elseif char == "\r" then
			index += 1
		else
			table.insert(field, char)
			index += 1
		end
	end

	if #field > 0 or #row > 0 then
		pushRow()
	end

	return rows
end

local function isBlankRow(row: { string }): boolean
	for _, field in row do
		if trim(field) ~= "" then
			return false
		end
	end
	return true
end

--- Builds the Localization Tables payload. Returns (nil, reason) when the
--- header is missing a required column or the file is empty.
function M.buildPayload(csvText: string): (Payload?, string?)
	-- Excel/Google Sheets "CSV UTF-8" exports prefix the file with a UTF-8 BOM
	-- (EF BB BF), which would otherwise land inside the first header cell and
	-- make "Key" read as "\u{FEFF}Key".
	local text = csvText
	if string.sub(text, 1, 3) == "\239\187\191" then
		text = string.sub(text, 4)
	end
	local rows = parseCsv(text)
	local header = rows[1]
	if header == nil then
		return nil, "empty csv"
	end

	local columnIndex: { [string]: number } = {}
	local headerOrder: { string } = {}
	for position, name in header do
		local trimmed = trim(name)
		columnIndex[trimmed] = position
		table.insert(headerOrder, trimmed)
	end

	for _, name in REQUIRED_COLUMNS do
		if columnIndex[name] == nil then
			return nil, "missing column: " .. name
		end
	end

	local locales: { string } = {}
	for _, name in headerOrder do
		if name ~= "Key" and name ~= "Source" and name ~= "Context" then
			table.insert(locales, name)
		end
	end

	local keyIndex = columnIndex["Key"] :: number
	local sourceIndex = columnIndex["Source"] :: number
	local contextIndex = columnIndex["Context"] :: number

	local entries: { Entry } = {}
	for rowIndex = 2, #rows do
		local row = rows[rowIndex]
		if not isBlankRow(row) then
			local key = trim(row[keyIndex] or "")
			if key ~= "" then
				local translations: { [string]: string } = {}
				for _, locale in locales do
					translations[locale] = trim(row[columnIndex[locale]] or "")
				end
				table.insert(entries, {
					key = key,
					source = trim(row[sourceIndex] or ""),
					context = trim(row[contextIndex] or ""),
					translations = translations,
				})
			end
		end
	end

	return { entries = entries, locales = locales }, nil
end

return M
