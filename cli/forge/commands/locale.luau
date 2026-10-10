--!strict
-- `forge locale check [--pack <slug>]`:
-- Verifies that every player-facing client literal is covered by the pack's
-- locale/strings.csv and that no row is missing a Korean translation.
--
-- `forge locale sync [--pack <slug>] [--dry-run]`:
-- Builds the Localization Tables API payload from locale/strings.csv and, in
-- dry-run (also the default without ROBLOX_API_KEY or a deploy.yml
-- localizationTableId), writes reports/locale-sync-<pack>.json offline.
--
-- Client literals are the strings assigned with `Text = "..."` and the format
-- templates passed to `string.format(...)`. A literal counts as covered when its
-- trimmed text appears in the Source column of strings.csv.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local localeSync = require("../lib/localesync")
local cliutil = require("../lib/cliutil")

local M = {}

local DEFAULT_PACK = "kaiju-egg-raiders"
local COLUMNS = { "Key", "Source", "Context", "en-us", "ko-kr" }
local CLIENT_SUFFIX = ".client.luau"

local function trim(value: string): string
	return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

--- Minimal RFC4180-ish CSV reader: quoted fields, doubled quotes, CRLF or LF.
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

local function clientFiles(packDir: string): { string }
	local dir = packDir .. "/src/client"
	local files: { string } = {}
	if not fs.isDir(dir) then
		return files
	end
	for _, name in fs.readDir(dir) do
		if string.sub(name, -#CLIENT_SUFFIX) == CLIENT_SUFFIX then
			table.insert(files, dir .. "/" .. name)
		end
	end
	table.sort(files)
	return files
end

-- Genre modules the pack pulls gameplay/runtime code from (e.g. collect-raid's
-- HUD, audio, and world-render runtime) can carry their own player-facing
-- literals when a pack does not route every string through its own copy
-- table. Walk the pack's Rojo tree for every $path under
-- ReplicatedStorage.Forge.genres.*, and scan that genre module's `runtime`
-- folder (non-spec .luau files) the same way client files are scanned.
local SPEC_SUFFIX = ".spec.luau"
local LUAU_SUFFIX = ".luau"

-- Server-authoritative genre runtime modules (persistence, remotes, siege
-- scheduling) route every player-facing string through the pack's `messages`
-- table already; their remaining string.format calls are server console logs
-- and internal ids, not client copy, so they are excluded from the scan the
-- same way non-`.client.luau` pack files are.
local SERVER_RUNTIME_FILES: { [string]: boolean } = {
	["Server.luau"] = true,
	["Loop.luau"] = true,
}

-- Collapses `.`/`..` segments so a genre's `../../genres/...` $path joins the
-- pack dir into one canonical, readable path.
local function normalizePath(path: string): string
	local parts: { string } = {}
	for segment in string.gmatch(path, "[^/]+") do
		if segment == "." then
			continue
		elseif segment == ".." then
			table.remove(parts)
		else
			table.insert(parts, segment)
		end
	end
	return table.concat(parts, "/")
end

local function collectGenrePaths(node: any, paths: { string }): ()
	if typeof(node) ~= "table" then
		return
	end
	local path = node["$path"]
	if typeof(path) == "string" then
		table.insert(paths, path)
	end
	for key, child in node do
		if key ~= "$path" and typeof(child) == "table" then
			collectGenrePaths(child, paths)
		end
	end
end

local function genreRuntimeFiles(packDir: string): { string }
	local files: { string } = {}
	local projectPath = packDir .. "/default.project.json"
	if not fs.isFile(projectPath) then
		return files
	end
	local decodedOk, decoded = pcall(function()
		return serde.decode("json", fs.readFile(projectPath))
	end)
	if not decodedOk or typeof(decoded) ~= "table" then
		return files
	end

	local genresNode = decoded
	for _, key in { "tree", "ReplicatedStorage", "Forge", "genres" } do
		if typeof(genresNode) ~= "table" then
			return files
		end
		genresNode = genresNode[key]
	end

	local relativePaths: { string } = {}
	collectGenrePaths(genresNode, relativePaths)

	for _, relative in relativePaths do
		local runtimeDir = normalizePath(packDir .. "/" .. relative .. "/runtime")
		if fs.isDir(runtimeDir) then
			for _, name in fs.readDir(runtimeDir) do
				if
					string.sub(name, -#SPEC_SUFFIX) ~= SPEC_SUFFIX
					and string.sub(name, -#LUAU_SUFFIX) == LUAU_SUFFIX
					and not SERVER_RUNTIME_FILES[name]
				then
					table.insert(files, runtimeDir .. "/" .. name)
				end
			end
		end
	end
	table.sort(files)
	return files
end

--- Extracts `Text = "..."` literals and `string.format("...")` templates.
local function collectLiterals(source: string): { string }
	local literals: { string } = {}
	for captured in string.gmatch(source, 'Text%s*=%s*"([^"]*)"') do
		table.insert(literals, captured)
	end
	for captured in string.gmatch(source, 'string%.format%s*%(%s*"([^"]*)"') do
		table.insert(literals, captured)
	end
	return literals
end

--- Offline sync planner. Live upload to the Localization Tables API is not
--- implemented here (this task is offline-safe planning only), so a sync that
--- clears the dry-run default is refused with an explicit message.
local function runSync(pack: string, dryRun: boolean): boolean
	local packDir = "games/" .. pack
	local csvPath = packDir .. "/locale/strings.csv"
	if not fs.isFile(csvPath) then
		stdio.ewrite("Error: missing " .. csvPath .. "\n")
		return false
	end

	local apiKey = process.env["ROBLOX_API_KEY"]
	local hasKey = apiKey ~= nil and apiKey ~= ""
	local tableId: any = nil
	local deployPath = packDir .. "/deploy.yml"
	if fs.isFile(deployPath) then
		local ok, deploy = pcall(function()
			return serde.decode("yaml", fs.readFile(deployPath))
		end)
		if ok and typeof(deploy) == "table" then
			tableId = deploy.localizationTableId
		end
	end
	local hasTable = typeof(tableId) == "number" and tableId ~= 0

	local effectiveDryRun = dryRun or not (hasKey and hasTable)
	if not effectiveDryRun then
		stdio.ewrite("locale sync: live upload is not implemented (offline plan only); re-run with --dry-run\n")
		return false
	end

	local payload, err = localeSync.buildPayload(fs.readFile(csvPath))
	if payload == nil then
		stdio.ewrite("Error: " .. (err or "failed to parse " .. csvPath) .. "\n")
		return false
	end

	local built = payload :: localeSync.Payload
	local reportPath = "reports/locale-sync-" .. pack .. ".json"
	if not fs.isDir("reports") then
		fs.writeDir("reports")
	end
	fs.writeFile(reportPath, serde.encode("json", built, true) .. "\n")
	stdio.write(
		string.format("locale sync: %d entries, %d locales -> %s\n", #built.entries, #built.locales, reportPath)
	)
	return true
end

--- Checks the pack locale table against the client literals.
function M.run(args: { string }): boolean
	local subcommand = args[2]
	if subcommand ~= "check" and subcommand ~= "sync" then
		stdio.ewrite(
			"Error: forge locale supports 'check' and 'sync', e.g. lune run cli/forge locale check [--pack <slug>]\n"
		)
		return false
	end

	local pack = DEFAULT_PACK
	local dryRun = false
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag == "--pack" then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: --pack requires a value\n")
				return false
			end
			pack = value
			index += 2
		elseif flag == "--dry-run" and subcommand == "sync" then
			dryRun = true
			index += 1
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge locale\n")
			return false
		end
	end

	if subcommand == "sync" then
		return runSync(pack, dryRun)
	end

	local packDir = "games/" .. pack
	local csvPath = packDir .. "/locale/strings.csv"
	if not fs.isFile(csvPath) then
		stdio.ewrite("Error: missing " .. csvPath .. "\n")
		return false
	end

	local rows = parseCsv(cliutil.stripBom(fs.readFile(csvPath)))
	local header = rows[1]
	if header == nil then
		stdio.ewrite("Error: " .. csvPath .. " is empty\n")
		return false
	end

	local columnIndex: { [string]: number } = {}
	for position, name in header do
		columnIndex[trim(name)] = position
	end
	for _, name in COLUMNS do
		if columnIndex[name] == nil then
			stdio.ewrite("Error: " .. csvPath .. " is missing the '" .. name .. "' column\n")
			return false
		end
	end

	local keyIndex = columnIndex["Key"] :: number
	local sourceIndex = columnIndex["Source"] :: number
	local koIndex = columnIndex["ko-kr"] :: number

	local sources: { [string]: boolean } = {}
	local missingKorean: { string } = {}
	local stringCount = 0

	for rowIndex = 2, #rows do
		local row = rows[rowIndex]
		if not isBlankRow(row) then
			stringCount += 1
			local source = trim(row[sourceIndex] or "")
			if source ~= "" then
				sources[source] = true
			end
			if trim(row[koIndex] or "") == "" then
				local key = trim(row[keyIndex] or "")
				table.insert(missingKorean, if key ~= "" then key else "row " .. tostring(rowIndex))
			end
		end
	end

	local missingSources: { string } = {}
	local reported: { [string]: boolean } = {}
	local scanFiles = clientFiles(packDir)
	for _, file in genreRuntimeFiles(packDir) do
		table.insert(scanFiles, file)
	end
	for _, file in scanFiles do
		local content = fs.readFile(file)
		for _, literal in collectLiterals(content) do
			local normalized = trim(literal)
			if normalized ~= "" and not sources[normalized] and not reported[normalized] then
				reported[normalized] = true
				table.insert(missingSources, file .. ': "' .. normalized .. '"')
			end
		end
	end

	if #missingSources > 0 or #missingKorean > 0 then
		stdio.ewrite(string.format("locale check: FAIL (%s)\n", csvPath))
		for _, item in missingSources do
			stdio.ewrite("client literal missing from strings.csv Source: " .. item .. "\n")
		end
		for _, key in missingKorean do
			stdio.ewrite("empty ko-kr translation: " .. key .. "\n")
		end
		return false
	end

	stdio.write(string.format("locale check: PASS (%s, %d strings)\n", csvPath, stringCount))
	return true
end

return M
