--!strict
-- Pure Luau localization string table.
-- Parses the CSV format used by games/*/locale/strings.csv:
--   header "Key,Source,Context,en-us,ko-kr" then rows; fields may be quoted
--   with double quotes (a quoted field may contain commas and "" for a
--   literal quote).

local Strings = {}

export type ParsedCsv = {
	header: { string },
	rows: { { string } },
}

-- Split raw CSV text into logical records, honoring double-quoted fields that
-- may contain commas, escaped quotes ("") and embedded newlines.
local function splitRecords(text: string): { { string } }
	local records: { { string } } = {}
	local field = ""
	local row: { string } = {}
	local inQuotes = false
	local i = 1
	local n = #text

	while i <= n do
		local c = string.sub(text, i, i)
		if inQuotes then
			if c == '"' then
				if string.sub(text, i + 1, i + 1) == '"' then
					field = field .. '"'
					i += 2
					continue
				end
				inQuotes = false
				i += 1
				continue
			end
			field = field .. c
			i += 1
			continue
		end

		if c == '"' then
			inQuotes = true
			i += 1
			continue
		elseif c == "," then
			table.insert(row, field)
			field = ""
			i += 1
			continue
		elseif c == "\r" then
			if string.sub(text, i + 1, i + 1) == "\n" then
				i += 1
			end
			table.insert(row, field)
			table.insert(records, row)
			row = {}
			field = ""
			i += 1
			continue
		elseif c == "\n" then
			table.insert(row, field)
			table.insert(records, row)
			row = {}
			field = ""
			i += 1
			continue
		end

		field = field .. c
		i += 1
	end

	if #field > 0 or #row > 0 then
		table.insert(row, field)
		table.insert(records, row)
	end

	return records
end

-- Drop rows that are entirely empty, which covers a trailing newline.
local function isBlankRow(row: { string }): boolean
	if #row == 0 then
		return true
	end
	for _, value in row do
		if value ~= "" then
			return false
		end
	end
	return true
end

function Strings.parseCsv(text: string): ParsedCsv
	local records = splitRecords(text)
	local header: { string } = {}
	local rows: { { string } } = {}

	for _, row in records do
		if isBlankRow(row) then
			continue
		end
		if #header == 0 then
			header = row
		else
			table.insert(rows, row)
		end
	end

	return { header = header, rows = rows }
end

export type Localization = {
	get: (self: Localization, key: string, locale: string?) -> string,
	format: (self: Localization, key: string, locale: string?, ...any) -> string,
	locales: (self: Localization) -> { string },
	missing: (self: Localization, locale: string) -> { string },
}

local LocalizationClass = {}
LocalizationClass.__index = LocalizationClass

function LocalizationClass.get(self: Localization, key: string, locale: string?): string
	local records: { [string]: { string } } = (self :: any).records
	local record = records[key]
	if record == nil then
		return key
	end

	local columns: { [string]: number } = (self :: any).columns
	local localeName = locale or (self :: any).defaultLocale
	local localeColumn = columns[localeName]
	if localeColumn ~= nil then
		local value = record[localeColumn]
		if value ~= nil and value ~= "" then
			return value
		end
	end

	local fallback = columns["en-us"]
	if fallback ~= nil and fallback ~= localeColumn then
		local value = record[fallback]
		if value ~= nil and value ~= "" then
			return value
		end
	end

	local source = record[(self :: any).sourceColumn]
	if source ~= nil and source ~= "" then
		return source
	end

	return key
end

function LocalizationClass.format(self: Localization, key: string, locale: string?, ...: any): string
	local template = LocalizationClass.get(self, key, locale)
	local args = table.pack(...)
	local ok, result = pcall(string.format, template, table.unpack(args, 1, args.n))
	if ok then
		return result
	end
	return template
end

function LocalizationClass.locales(self: Localization): { string }
	local result: { string } = {}
	for _, name in (self :: any).localeColumns do
		table.insert(result, name)
	end
	return result
end

function LocalizationClass.missing(self: Localization, locale: string): { string }
	local columns: { [string]: number } = (self :: any).columns
	local column = columns[locale]
	local result: { string } = {}
	if column == nil then
		return result
	end

	local records: { [string]: { string } } = (self :: any).records
	for key, record in records do
		local value = record[column]
		if value == nil or value == "" then
			table.insert(result, key)
		end
	end

	table.sort(result)
	return result
end

function Strings.fromCsv(text: string): Localization
	local parsed = Strings.parseCsv(text)
	local columns: { [string]: number } = {}
	local contextColumn = 0

	for index, name in parsed.header do
		columns[name] = index
		if name == "Context" then
			contextColumn = index
		end
	end

	-- Locale columns are the columns after Context, in header order.
	local localeColumns: { string } = {}
	if contextColumn > 0 then
		for index = contextColumn + 1, #parsed.header do
			table.insert(localeColumns, parsed.header[index])
		end
	else
		-- No Context column: fall back to every column after Key, Source, Context.
		for _, name in parsed.header do
			if name ~= "Key" and name ~= "Source" and name ~= "Context" then
				table.insert(localeColumns, name)
			end
		end
	end

	local records: { [string]: { string } } = {}
	local keyColumn = columns["Key"] or 1

	for _, row in parsed.rows do
		local key = row[keyColumn]
		if key ~= nil and key ~= "" then
			records[key] = row
		end
	end

	local self = setmetatable({
		header = parsed.header,
		columns = columns,
		records = records,
		localeColumns = localeColumns,
		sourceColumn = columns["Source"] or 2,
		defaultLocale = localeColumns[1] or "en-us",
	}, LocalizationClass)

	return (self :: any) :: Localization
end

return Strings
