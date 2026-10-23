--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

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
	-- Worker processes. 1 (or nil) runs every spec in this process; N > 1 shards
	-- the spec files across N child `specs-run` processes and merges their reports.
	jobs: number?,
	-- Exact spec files to run (internal: a shard). An entry "path\ttest" runs only
	-- that test of the file. Skips discovery and the compile pre-pass, which the
	-- parent already did.
	files: { string }?,
}

-- Per-file durations from the last full run, used to balance shards.
local TIMINGS_PATH = "build/cache/spec-timings.json"
-- A shard that runs longer than this is killed and reported as failed.
local SHARD_TIMEOUT_SECONDS = 1800
-- Shard unit test name meaning "every test of the file the timing record lacks".
local REST = "<unrecorded>"

type TestResult = { file: string, test: string, ok: boolean, ms: number, err: string? }

local dynamicRequire = require :: any

local DEFAULT_ROOTS: { string } = { "core", "games", "cli", "genres" }

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

local loadTimings: () -> any
local recordedCache: any = nil
local function recordedTests(file: string): { [string]: number }
	if recordedCache == nil then
		recordedCache = loadTimings()
	end
	return recordedCache.tests[file] or {}
end

function M.run(options: RunOptions): (boolean, string)
	local filters: { string } = options.filters or {}
	local filtered = #filters > 0
	local roots: { string } = options.roots or DEFAULT_ROOTS
	local quiet = options.quiet == true
	local startedAt = os.clock()

	local specs: { string } = {}
	local sources: { string } = {}
	local onlyTests: { [string]: { [string]: boolean }? } = {}
	if options.files == nil then
		for _, dir in roots do
			M.discover(dir, specs)
			collect(dir, "%.luau$", sources)
		end
	else
		for _, entry in options.files do
			local path, test = string.match(entry, "^([^\t]+)\t(.+)$")
			if path ~= nil and test ~= nil then
				if onlyTests[path] == nil then
					onlyTests[path] = {}
					table.insert(specs, path)
				end
				(onlyTests[path] :: { [string]: boolean })[test] = true
			else
				table.insert(specs, entry)
			end
		end
	end
	table.sort(specs)
	table.sort(sources)

	local logLines: { string } = {}

	-- Pre-parse every source before requiring anything. Requiring a module that
	-- fails to parse reports an error once, but requiring that same module again
	-- hangs forever (lune 0.10.5), so a shared broken module has to be caught here
	-- instead of while walking the specs. Filters never narrow this pass: it costs
	-- under a second for the whole repo, unlike requiring every spec.
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

	-- With filters, require only spec files whose path matches one: requiring
	-- every spec runs ~200 modules' top-level code and dominated filtered runs.
	-- A filter that matches no spec path can only match a test name, so in that
	-- case every spec is still required to search "path :: testName".
	local toRequire = specs
	if filtered then
		local pathMatched: { string } = {}
		for _, specFile in specs do
			if matchesAny(filters, specFile) then
				table.insert(pathMatched, specFile)
			end
		end
		local everyFilterMatchesPath = true
		for _, filter in filters do
			local found = false
			for _, specFile in pathMatched do
				if contains(specFile, filter) then
					found = true
					break
				end
			end
			if not found then
				everyFilterMatchesPath = false
				break
			end
		end
		if everyFilterMatchesPath then
			toRequire = pathMatched
		end
	end

	local results: { TestResult } = {}
	local files = 0
	local jobs = math.min(options.jobs or 1, #toRequire)
	if jobs > 1 then
		local shardResults, _, shardErrors = M.runShards(toRequire, filters, jobs)
		results = shardResults
		-- A heavy file can be split across shards; count each spec file once.
		local seenFiles: { [string]: boolean } = {}
		for _, result in shardResults do
			if not seenFiles[result.file] then
				seenFiles[result.file] = true
				files += 1
			end
		end
		for _, line in shardErrors do
			table.insert(logLines, line)
		end
		if #shardErrors > 0 then
			-- A crashed shard is a failure even when every reported test passed.
			table.insert(results, {
				file = "(shards)",
				test = "worker",
				ok = false,
				ms = 0,
				err = table.concat(shardErrors, "; "),
			})
		end
	end
	local inProcess: { string } = if jobs > 1 then {} else toRequire
	for _, specFile in inProcess do
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
				local allowed = onlyTests[specFile]
				local selected = allowed == nil
					or allowed[testName] == true
					or (allowed[REST] == true and recordedTests(specFile)[testName] == nil)
				if type(testName) == "string" and type(testFn) == "function" and selected then
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

	-- A shard may legitimately match nothing; the parent decides on zero matches.
	if filtered and #results == 0 and options.files == nil then
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

	if not filtered and options.files == nil and options.roots == nil then
		M.saveTimings(results)
	end

	local success = (failed == 0) and (passed > 0)
	return success, table.concat(logLines, "\n")
end

type Timings = { files: { [string]: number }, tests: { [string]: { [string]: number } } }

function loadTimings(): Timings
	local ok, decoded = pcall(function()
		return serde.decode("json", fs.readFile(TIMINGS_PATH))
	end)
	if ok and type(decoded) == "table" and type(decoded.files) == "table" then
		return { files = decoded.files, tests = if type(decoded.tests) == "table" then decoded.tests else {} }
	end
	return { files = {}, tests = {} }
end

-- A file whose recorded duration exceeds one shard's fair share is split into
-- one unit per recorded test, so one slow spec file cannot set the floor.
-- Tests absent from the record (new since the last run) stay with the file
-- remainder unit, which runs every test not split out.
function M.units(files: { string }, jobs: number, timings: Timings): ({ string }, { [string]: number })
	local total = 0
	for _, file in files do
		total += timings.files[file] or 0
	end
	local share = total / math.max(1, jobs)
	local units: { string } = {}
	local weights: { [string]: number } = {}
	for _, file in files do
		local tests = timings.tests[file]
		local ms = timings.files[file]
		if ms ~= nil and tests ~= nil and ms > share * 0.5 then
			local names: { string } = {}
			for name in tests do
				table.insert(names, name)
			end
			table.sort(names)
			for _, name in names do
				local unit = file .. "\t" .. name
				table.insert(units, unit)
				weights[unit] = tests[name]
			end
			-- Remainder: tests not in the record. Encoded as the file with an
			-- exclusion marker the shard resolves.
			local rest = file .. "\t" .. REST
			table.insert(units, rest)
			weights[rest] = 0
		else
			table.insert(units, file)
		end
	end
	return units, weights
end

function M.saveTimings(results: { TestResult })
	local perFile: { [string]: number } = {}
	local perTest: { [string]: { [string]: number } } = {}
	for _, result in results do
		perFile[result.file] = (perFile[result.file] or 0) + result.ms
		local tests = perTest[result.file] or {}
		tests[result.test] = result.ms
		perTest[result.file] = tests
	end
	pcall(function()
		if not fs.isDir("build/cache") then
			fs.writeDir("build/cache")
		end
		fs.writeFile(TIMINGS_PATH, serde.encode("json", { schemaVersion = 1, files = perFile, tests = perTest }))
	end)
end

-- Longest-processing-time-first assignment: heaviest file to the lightest shard.
-- Files without a recorded duration weigh their source size, scaled to the
-- recorded files' ms-per-byte so both units mix sensibly.
function M.partition(files: { string }, jobs: number, timings: Timings): { { string } }
	local units, weights = M.units(files, jobs, timings)
	local knownMs, knownBytes = 0, 0
	local sizes: { [string]: number } = {}
	for _, file in files do
		local okSize, meta = pcall(fs.metadata, file)
		sizes[file] = if okSize and meta.exists then (meta :: any).size or 1 else 1
		if timings.files[file] ~= nil then
			knownMs += timings.files[file]
			knownBytes += sizes[file]
		end
	end
	local msPerByte = if knownBytes > 0 then knownMs / knownBytes else 0.01
	for _, unit in units do
		if weights[unit] == nil then
			weights[unit] = timings.files[unit] or (sizes[unit] or 1) * msPerByte
		end
	end
	files = units
	local ordered = table.clone(files)
	table.sort(ordered, function(a, b)
		if weights[a] ~= weights[b] then
			return weights[a] > weights[b]
		end
		return a < b
	end)
	local shards: { { string } } = {}
	local loads: { number } = {}
	for index = 1, jobs do
		shards[index] = {}
		loads[index] = 0
	end
	for _, file in ordered do
		local lightest = 1
		for index = 2, jobs do
			if loads[index] < loads[lightest] then
				lightest = index
			end
		end
		table.insert(shards[lightest], file)
		loads[lightest] += weights[file]
	end
	local nonEmpty: { { string } } = {}
	for _, shard in shards do
		if #shard > 0 then
			table.sort(shard)
			table.insert(nonEmpty, shard)
		end
	end
	return nonEmpty
end

local function drain(reader: any, sink: { string })
	while true do
		local chunk = reader:read()
		if chunk == nil or chunk == "" then
			return
		end
		table.insert(sink, chunk)
	end
end

-- Runs each shard as `lune run cli/forge specs-run --files <list> --json <report>`
-- with its own TEMP root (specs name scratch dirs from os.clock, which is not
-- unique across processes), then merges the shard reports.
function M.runShards(files: { string }, filters: { string }, jobs: number): ({ TestResult }, number, { string })
	local shards = M.partition(files, jobs, loadTimings())
	local scratch = string.gsub(process.env.TEMP or process.env.TMPDIR or "build", "\\", "/")
		.. "/forge-specs-"
		.. string.sub(serde.hash("sha256", tostring(os.clock()) .. tostring(os.time())), 1, 12)
	fs.writeDir(scratch)
	local reports: { any } = {}
	local errors: { string } = {}
	local pending = #shards
	for index, shard in shards do
		task.spawn(function()
			local dir = scratch .. "/shard-" .. index
			fs.writeDir(dir .. "/tmp")
			local listPath = dir .. "/files.txt"
			local reportPath = dir .. "/report.json"
			fs.writeFile(listPath, table.concat(shard, "\n"))
			local args =
				{ "run", "cli/forge", "specs-run", "--quiet", "--jobs", "1", "--files", listPath, "--json", reportPath }
			for _, filter in filters do
				table.insert(args, filter)
			end
			local tmp = string.gsub(dir .. "/tmp", "/", if process.os == "windows" then "\\" else "/")
			local okCreate, child = pcall(process.create, M.luneExecutable(), args, {
				env = { TEMP = tmp, TMP = tmp, TMPDIR = tmp },
			})
			if not okCreate then
				table.insert(errors, string.format("SHARD %d could not start: %s", index, tostring(child)))
				pending -= 1
				return
			end
			local out: { string } = {}
			local err: { string } = {}
			local readers = 2
			task.spawn(function()
				drain(child.stdout, out)
				readers -= 1
			end)
			task.spawn(function()
				drain(child.stderr, err)
				readers -= 1
			end)
			local started = os.clock()
			local killed = false
			while readers > 0 do
				if os.clock() - started > SHARD_TIMEOUT_SECONDS and not killed then
					killed = true
					child:kill()
				end
				task.wait(0.05)
			end
			local status = child:status()
			local okReport, report = pcall(function()
				return serde.decode("json", fs.readFile(reportPath))
			end)
			if okReport and type(report) == "table" then
				table.insert(reports, report)
			end
			if killed then
				table.insert(
					errors,
					string.format("SHARD %d timed out after %d s: %s", index, SHARD_TIMEOUT_SECONDS, shard[1])
				)
			elseif not okReport then
				local tail = string.sub(table.concat(out) .. table.concat(err), -600)
				table.insert(errors, string.format("SHARD %d exited %d without a report: %s", index, status.code, tail))
			end
			pending -= 1
		end)
	end
	while pending > 0 do
		task.wait(0.05)
	end
	pcall(fs.removeDir, scratch)

	local failureErr: { [string]: string } = {}
	local results: { TestResult } = {}
	local fileCount = 0
	for _, report in reports do
		fileCount += report.files or 0
		for _, failure in report.failures or {} do
			failureErr[failure.file .. " :: " .. failure.test] = failure.error
		end
		for _, entry in report.tests or {} do
			table.insert(results, {
				file = entry.file,
				test = entry.test,
				ok = entry.ok,
				ms = entry.ms,
				err = if entry.ok then nil else failureErr[entry.file .. " :: " .. entry.test],
			})
		end
	end
	-- Same order a serial run reports: by spec file, then by test name.
	table.sort(results, function(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.test < b.test
	end)
	table.sort(errors)
	return results, fileCount, errors
end

function M.luneExecutable(): string
	if process.os == "windows" then
		local profile = process.env.USERPROFILE
		if profile and fs.isFile(profile .. "/.rokit/bin/lune.exe") then
			return profile .. "/.rokit/bin/lune.exe"
		end
	end
	return "lune"
end

-- "auto" picks one worker per core minus one, at least 1.
function M.autoJobs(): number
	local cores = tonumber(process.env.NUMBER_OF_PROCESSORS or "")
	if cores == nil then
		local okExec, res = pcall(process.exec, "nproc", {})
		cores = if okExec and res.ok then tonumber((string.gsub(res.stdout, "%s+", ""))) else nil
	end
	return math.max(1, (cores or 4) - 1)
end

function M.runAll(): (boolean, string)
	return M.run({})
end

return M
