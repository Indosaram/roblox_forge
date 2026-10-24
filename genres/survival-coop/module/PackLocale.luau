--!strict
-- Pack locale lookup for genre text tables. A pack ships its copy once (Robango: the Strings
-- LocalizationTable) and installs a (locale, key) -> string? lookup with M.use; tables wrapped by
-- M.rows keep only rows the pack table lacks and read the rest through the lookup as { en, ko }.
local M = {}

local lookup: (string, string) -> string? = function(_locale: string, _key: string): string?
	return nil
end

function M.use(fn: (string, string) -> string?)
	lookup = fn
end

function M.get(locale: string, key: string): string?
	return lookup(locale, key)
end

function M.rows(rows: { [string]: { string } }): { [string]: { string } }
	return setmetatable(rows, {
		__index = function(_: any, key: string): { string }?
			local en = lookup("en-us", key)
			return if en then { en, lookup("ko-kr", key) or en } else nil
		end,
	}) :: any
end

return M
