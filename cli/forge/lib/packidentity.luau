--!strict
-- Shared pack naming and literal template substitution.

local M = {}

local function wordsOf(slug: string): { string }
	local words: { string } = {}
	for word in string.gmatch(slug, "[^-]+") do
		table.insert(words, word)
	end
	return words
end

function M.isValidSlug(slug: string): boolean
	if slug == "" then
		return false
	end
	if string.find(slug, "[^%l%d%-]") ~= nil then
		return false
	end
	if string.sub(slug, 1, 1) == "-" or string.sub(slug, -1) == "-" then
		return false
	end
	return string.find(slug, "--", 1, true) == nil
end

function M.titleCase(slug: string): string
	local words: { string } = {}
	for _, word in wordsOf(slug) do
		table.insert(words, string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2))
	end
	return table.concat(words, " ")
end

function M.pascalCase(slug: string): string
	local words: { string } = {}
	for _, word in wordsOf(slug) do
		table.insert(words, string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2))
	end
	return table.concat(words)
end

function M.fill(text: string, vars: { [string]: string }): string
	local out = text
	for key, value in vars do
		out = string.gsub(out, key, function(): string
			return value
		end)
	end
	return out
end

return M
