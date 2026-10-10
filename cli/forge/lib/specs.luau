--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local M = {}

local dynamicRequire = require :: any

local SOURCE_DIRS = { "core", "games", "cli", "genres" }
local SPEC_DIRS = { "core", "games", "cli", "genres" }

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

function M.runAll(): (boolean, string)
	local specs: { string } = {}
	for _, dir in SPEC_DIRS do
		M.discover(dir, specs)
	end

	local sources: { string } = {}
	for _, dir in SOURCE_DIRS do
		collect(dir, "%.luau$", sources)
	end

	local passed = 0
	local failed = 0
	local logLines: { string } = {}

	-- Pre-parse every source before requiring anything. Requiring a module that
	-- fails to parse reports an error once, but requiring that same module again
	-- hangs forever (lune 0.10.5), so a shared broken module has to be caught here
	-- instead of while walking the specs.
	for _, sourceFile in sources do
		local err = parseFailure(sourceFile)
		if err ~= nil then
			failed += 1
			table.insert(logLines, "FAIL " .. sourceFile .. " :: compile :: " .. err)
		end
	end
	if failed > 0 then
		table.insert(logLines, string.format("specs: %d passed, %d failed", passed, failed))
		return false, table.concat(logLines, "\n")
	end

	for _, specFile in specs do
		local relReqPath = "../../../" .. string.gsub(specFile, "%.luau$", "")
		local reqOk, specTable = pcall(M.requireSpec, relReqPath)
		if not reqOk then
			failed += 1
			table.insert(logLines, "FAIL " .. specFile .. " :: require :: " .. tostring(specTable))
		elseif type(specTable) ~= "table" then
			failed += 1
			table.insert(logLines, "FAIL " .. specFile .. " :: require :: spec did not return a table")
		else
			for testName, testFn in pairs(specTable) do
				if type(testFn) == "function" then
					local runOk, runErr = pcall(testFn)
					if runOk then
						passed += 1
						table.insert(logLines, "PASS " .. specFile .. " :: " .. testName)
					else
						failed += 1
						table.insert(logLines, "FAIL " .. specFile .. " :: " .. testName .. " :: " .. tostring(runErr))
					end
				end
			end
		end
	end

	table.insert(logLines, string.format("specs: %d passed, %d failed", passed, failed))

	local success = (failed == 0) and (passed > 0)
	local output = table.concat(logLines, "\n")
	return success, output
end

return M
