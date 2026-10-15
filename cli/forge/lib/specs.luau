--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local M = {}

export type RunOptions = {
	-- Substring filters; a test runs when any filter is found in its spec path
	-- or in "path :: testName". Empty or nil runs everything.
	filters: { string }?,
	-- Print only FAIL lines plus the summary.
	quiet: boolean?,
	-- Print the N slowest tests before the summary.
	slowest: number?,
	-- Write a machine-readable report to this path.
	json: string?,
	-- Directories (relative to the working directory) to discover specs and
	-- compile sources in. Defaults to core, games, cli and genres.
	roots: { string }?,
}

type TestResult = { file: string, test: string, ok: boolean, ms: number, err: string? }

local dynamicRequire = require :: any

local DEFAULT_ROOTS = { "core", "games", "cli", "genres" }

function M.requireSpec(specPath: string): any
	return dynamicRequire(specPath)
end

local function collect(dir: string, pattern: string, list: { string })
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local fullPath = dir .. "/" .. entry
		if fs.isDir(fullPath) then
			collect(fullPath, pattern, list)
		elseif string.match(entry, pattern) then
			table.insert(list, fullPath)
		end
	end
end

function M.discover(dir: string, list: { string })
	collect(dir, "%.spec%.luau$", list)
end

local function firstLine(value: any): string
	local text = tostring(value)
	return string.match(text, "^[^\r\n]+") or text
end

local function parseFailure(path: string): string?
	local readOk, source = pcall(fs.readFile, path)
	if not readOk then
		return firstLine(source)
	end
	local compileOk, err = pcall(luau.compile, source)
	if not compileOk then
		return firstLine(err)
	end
	return nil
end

local function contains(haystack: string, needle: string): boolean
	return string.find(haystack, needle, 1, true) ~= nil
end

local function matchesAny(filters: { string }, subject: string): boolean
	for _, filter in filters do
		if contains(subject, filter) then
			return true
		end
	end
	return false
end

local function writeJson(path: string, report: { [string]: any })
	local encoded = serde.encode("json", report)
	-- serde encodes empty tables as objects; these two fields are always arrays.
	encoded = string.gsub(encoded, '"failures":{}', '"failures":[]')
	encoded = string.gsub(encoded, '"tests":{}', '"tests":[]')
	fs.writeFile(path, encoded)
end

function M.run(options: RunOptions): (boolean, string)
	local filters = options.filters or {}
	local filtered = #filters > 0
	local roots = options.roots or DEFAULT_ROOTS
	local quiet = options.quiet == true
	local startedAt = os.clock()

	local specs: { string } = {}
	local sources: { string } = {}
	for _, dir in roots do
		M.discover(dir, specs)
		collect(dir, "%.luau$", sources)
	end
	table.sort(specs)
	table.sort(sources)

	local logLines: { string } = {}

	-- Pre-parse every source before requiring anything. Requiring a module that
	-- fails to parse reports an error once, but requiring that same module again
	-- hangs forever (lune 0.10.5), so a shared broken module has to be caught here
	-- instead of while walking the specs. Filters never narrow this pass.
	local compileFailed = 0
	for _, sourceFile in sources do
		local err = parseFailure(sourceFile)
		if err ~= nil then
			compileFailed += 1
			table.insert(logLines, "FAIL " .. sourceFile .. " :: compile :: " .. err)
		end
	end
	if compileFailed > 0 then
		table.insert(logLines, string.format("specs: 0 passed, %d failed", compileFailed))
		return false, table.concat(logLines, "\n")
	end

	local results: { TestResult } = {}
	local files = 0
	for _, specFile in specs do
		local pathMatches = not filtered or matchesAny(filters, specFile)
		local relReqPath = "../../../" .. string.gsub(specFile, "%.luau$", "")
		local reqOk, specTable = pcall(M.requireSpec, relReqPath)
		local requireErr: string? = nil
		if not reqOk then
			requireErr = tostring(specTable)
		elseif type(specTable) ~= "table" then
			requireErr = "spec did not return a table"
		end
		if requireErr ~= nil then
			if pathMatches then
				files += 1
				table.insert(results, { file = specFile, test = "require", ok = false, ms = 0, err = requireErr })
			end
		else
			local names: { string } = {}
			for testName, testFn in pairs(specTable) do
				if type(testName) == "string" and type(testFn) == "function" then
					if pathMatches or matchesAny(filters, specFile .. " :: " .. testName) then
						table.insert(names, testName)
					end
				end
			end
			table.sort(names)
			if #names > 0 then
				files += 1
			end
			for _, testName in names do
				local testStart = os.clock()
				local runOk, runErr = pcall(specTable[testName])
				local ms = (os.clock() - testStart) * 1000
				table.insert(results, {
					file = specFile,
					test = testName,
					ok = runOk,
					ms = ms,
					err = if runOk then nil else tostring(runErr),
				})
			end
		end
	end

	if filtered and #results == 0 then
		return false, "specs: no tests matched " .. table.concat(filters, ", ")
	end

	local passed = 0
	local failed = 0
	local failures = {}
	local tests = {}
	for _, result in results do
		if result.ok then
			passed += 1
			if not quiet then
				table.insert(logLines, "PASS " .. result.file .. " :: " .. result.test)
			end
		else
			failed += 1
			local err = result.err or ""
			table.insert(logLines, "FAIL " .. result.file .. " :: " .. result.test .. " :: " .. err)
			table.insert(failures, { file = result.file, test = result.test, error = err })
		end
		table.insert(tests, { file = result.file, test = result.test, ok = result.ok, ms = result.ms })
	end

	local slowest = options.slowest
	if slowest ~= nil and slowest > 0 then
		local byDuration = table.clone(results)
		table.sort(byDuration, function(a, b)
			if a.ms ~= b.ms then
				return a.ms > b.ms
			end
			return a.file .. " :: " .. a.test < b.file .. " :: " .. b.test
		end)
		for index = 1, math.min(slowest, #byDuration) do
			local result = byDuration[index]
			table.insert(logLines, string.format("SLOW %.1f ms %s :: %s", result.ms, result.file, result.test))
		end
	end

	local elapsed = os.clock() - startedAt
	table.insert(
		logLines,
		string.format("specs: %d passed, %d failed, %d files, %.2f s", passed, failed, files, elapsed)
	)

	if options.json ~= nil then
		writeJson(options.json, {
			schemaVersion = 1,
			passed = passed,
			failed = failed,
			files = files,
			durationMs = elapsed * 1000,
			failures = failures,
			tests = tests,
		})
	end

	local success = (failed == 0) and (passed > 0)
	return success, table.concat(logLines, "\n")
end

function M.runAll(): (boolean, string)
	return M.run({})
end

return M
