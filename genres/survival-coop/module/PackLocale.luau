--!strict
-- Pack locale lookup for genre text tables. A pack ships its copy once (Robango: the Strings
-- LocalizationTable) and installs a (locale, key) -> string? lookup with M.use; tables wrapped by
-- M.rows keep only rows the pack table lacks and read the rest through the lookup as { en, ko }.
-- `prefixes` (default { "" }) are tried in order, so a module reads its own namespaced rows
-- (e.g. "soc.perm.title" for key "perm.title") without colliding with another module's keys.
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

function M.rows(rows: { [string]: { string } }, prefixes: { string }?): { [string]: { string } }
	local order: { string } = prefixes or { "" }
	return setmetatable(rows, {
		__index = function(_: any, key: string): { string }?
			for _, prefix in order do
				local en = lookup("en-us", prefix .. key)
				if en then
					return { en, lookup("ko-kr", prefix .. key) or en }
				end
			end
			return nil
		end,
	}) :: any
end

return M
