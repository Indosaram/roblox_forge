--!strict
-- `forge trends [--fixture <path>] [--out <path>]`:
-- collect the top Roblox experiences, summarize them per genre, flag genres
-- that have no module under genres/ as new-module candidates, and write a
-- markdown report (default: reports/trends-<YYYY-MM-DD>.md).
--
-- Live mode fetches the Explore "top-playing-now" sort. The old
-- games.roblox.com/v1/games/sorts endpoint is deprecated, so use
-- apis.roblox.com/explore-api. --fixture reads a saved JSON payload instead,
-- which is how specs and offline runs avoid the network.

local datetime = require("@lune/datetime")
local fs = require("@lune/fs")
local net = require("@lune/net")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local trends = require("../lib/trends")

local M = {}

local SORT_URL = "https://apis.roblox.com/explore-api/v1/get-sort-content?sessionId=forge&sortId=top-playing-now"

local function ensureDir(path: string)
	if not fs.isDir(path) then
		fs.writeDir(path)
	end
end

-- F11: `--out` may point outside reports/ entirely; fs.writeFile throws on a
-- missing parent directory, so it must be created first.
local function ensureParentDir(path: string)
	local parent = string.match(path, "^(.*)/[^/]+$")
	if parent ~= nil and parent ~= "" then
		ensureDir(parent)
	end
end

local function knownGenres(): { string }
	local names: { string } = {}
	if fs.isDir("genres") then
		for _, entry in fs.readDir("genres") do
			if fs.isDir("genres/" .. entry) then
				table.insert(names, entry)
			end
		end
	end
	table.sort(names)
	return names
end

--- Fetches the live sort. Returns false plus a clear message on any failure so
--- the command can exit 1 without a stack trace.
local function fetchLive(): (boolean, string)
	local ok, response = pcall(function()
		local headers: { [string]: string } = { Accept = "application/json" }
		return net.request({ url = SORT_URL, method = "GET", headers = headers })
	end)
	if not ok then
		return false, "trends live fetch failed: " .. tostring(response)
	end
	if not response.ok then
		return false, string.format("trends live fetch failed: HTTP %d %s", response.statusCode, response.statusMessage)
	end
	return true, response.body
end

function M.run(args: { string }): boolean
	local fixture: string? = nil
	local out: string? = nil
	local index = 2
	while index <= #args do
		local flag = args[index]
		if flag == "--fixture" or flag == "--out" then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false
			end
			if flag == "--fixture" then
				fixture = value
			else
				out = value
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge trends\n")
			return false
		end
	end

	local raw: string
	if fixture ~= nil then
		if not fs.isFile(fixture) then
			stdio.ewrite("Error: fixture not found: " .. fixture .. "\n")
			return false
		end
		raw = fs.readFile(fixture)
	else
		local ok, bodyOrError = fetchLive()
		if not ok then
			stdio.ewrite(bodyOrError .. "\n")
			return false
		end
		raw = bodyOrError
	end

	local decodedOk, decoded = pcall(function()
		return serde.decode("json", raw)
	end)
	if not decodedOk then
		stdio.ewrite("Error: could not decode trends payload as JSON: " .. tostring(decoded) .. "\n")
		return false
	end

	local list = trends.parse(decoded)
	if #list == 0 then
		stdio.ewrite("Error: trends payload contained no experiences\n")
		return false
	end

	local rows = trends.summarize(list)
	local unknown = trends.unknownGenres(rows, knownGenres())
	local markdown = trends.render(rows, unknown)

	local date = datetime.now():formatUniversalTime("%Y-%m-%d")
	local outPath = out or ("reports/trends-" .. date .. ".md")
	ensureParentDir(outPath)
	fs.writeFile(outPath, markdown)

	stdio.write(string.format("trends: %d experiences across %d genres -> %s\n", #list, #rows, outPath))
	if #unknown > 0 then
		stdio.write("trends: new module candidates: " .. table.concat(unknown, ", ") .. "\n")
	end
	return true
end

return M
