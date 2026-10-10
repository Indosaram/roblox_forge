--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local cliutil = require("../lib/cliutil")
local M = {}
function M.ensureDir(path: string)
	if not fs.isDir(path) then
		fs.writeDir(path)
	end
end

function M.writeJson(path: string, value: any)
	fs.writeFile(path, serde.encode("json", value, true) .. "\n")
end

function M.yamlQuote(value: string): string
	local escaped = string.gsub(value, "\\", "\\\\")
	escaped = string.gsub(escaped, '"', '\\"')
	escaped = string.gsub(escaped, "\n", "\\n")
	return '"' .. escaped .. '"'
end

-- Reads games/<pack>/game.yml poly_budget, falling back to an empty map so
-- procgen uses its per-kind defaults.
function M.loadPolyBudget(packDir: string): any
	local polyBudget: any = {}
	local gamePath = packDir .. "/game.yml"
	if fs.isFile(gamePath) then
		local gameOk, game = pcall(function()
			return serde.decode("yaml", fs.readFile(gamePath))
		end)
		if gameOk and typeof(game) == "table" and typeof(game.poly_budget) == "table" then
			polyBudget = game.poly_budget
		end
	end
	return polyBudget
end

function M.manifestHasKey(manifestPath: string, key: string): boolean
	if not fs.isFile(manifestPath) then
		return false
	end
	local ok, decoded = pcall(function()
		return serde.decode("yaml", fs.readFile(manifestPath))
	end)
	if not ok or typeof(decoded) ~= "table" or typeof(decoded.assets) ~= "table" then
		return false
	end
	for _, asset in decoded.assets do
		if typeof(asset) == "table" and asset.key == key then
			return true
		end
	end
	return false
end

-- Splits a document into lines without a trailing empty element.
local function splitLines(text: string): { string }
	local lines: { string } = {}
	local start = 1
	while true do
		local newline = string.find(text, "\n", start, true)
		if newline == nil then
			table.insert(lines, string.sub(text, start))
			break
		end
		table.insert(lines, string.sub(text, start, newline - 1))
		start = newline + 1
	end
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

local function blockLines(block: string): { string }
	local lines: { string } = {}
	for line in string.gmatch(block, "([^\n]+)") do
		table.insert(lines, line)
	end
	return lines
end

-- Upserts one asset entry while preserving the rest of the hand-written
-- document: an existing block for `key` is replaced in place, otherwise the
-- entry is appended (expanding an empty `assets: []` in place).
function M.upsertAsset(manifestPath: string, key: string, block: string)
	if not fs.isFile(manifestPath) then
		fs.writeFile(manifestPath, "assets:\n" .. block)
		return
	end

	local lines = splitLines(fs.readFile(manifestPath))
	if #lines == 0 then
		fs.writeFile(manifestPath, "assets:\n" .. block)
		return
	end
	local sequence = cliutil.assetSequence(lines)
	local startIndex = cliutil.findKeyLine(lines, key)
	local incoming = blockLines(block)
	local incomingIndent = string.match(incoming[1], "^( *)") or ""
	local itemIndent = if sequence ~= nil then sequence.indent else incomingIndent
	for i, line in incoming do
		incoming[i] = itemIndent .. string.sub(line, #incomingIndent + 1)
	end
	if startIndex ~= nil then
		local lastIndex = cliutil.findBlockEnd(lines, startIndex)
		local merged: { string } = {}
		for i = 1, startIndex - 1 do
			table.insert(merged, lines[i])
		end
		for _, line in incoming do
			table.insert(merged, line)
		end
		for i = lastIndex + 1, #lines do
			table.insert(merged, lines[i])
		end
		fs.writeFile(manifestPath, table.concat(merged, "\n") .. "\n")
		return
	end

	local insertIndex = #lines + 1
	if sequence ~= nil then
		insertIndex = sequence.limit
		local header = sequence.header :: number
		if string.match(lines[header], "^assets:%s*%[%]%s*$") then
			lines[header] = "assets:"
		end
	else
		table.insert(lines, "assets:")
		insertIndex = #lines + 1
	end
	for i, line in incoming do
		table.insert(lines, insertIndex + i - 1, line)
	end
	fs.writeFile(manifestPath, table.concat(lines, "\n") .. "\n")
end

return M
