--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local specs = require("./specs")
local tempdir = require("./tempdir")

-- Fake spec trees live under the git-ignored build/ directory because the
-- runner requires specs relative to the working directory (the repo root), so
-- only the unique leaf name comes from tempdir.path, not its scratch root.
local function withTree(files: { [string]: string }, body: (root: string) -> ())
	local root = "build/" .. (string.match(tempdir.path(".specs-fixture"), "[^/]+$") :: string)
	fs.writeDir(root)
	local ok, reason = xpcall(function()
		for path, source in files do
			local full = root .. "/" .. path
			local dir = string.match(full, "^(.*)/[^/]+$")
			if dir ~= nil then
				fs.writeDir(dir)
			end
			fs.writeFile(full, source)
		end
		body(root)
	end, debug.traceback)
	fs.removeDir(root)
	assert(ok, reason)
end

local TREE = {
	["zeta/z.spec.luau"] = 'return { ["b second"] = function() end, ["a first"] = function() end }\n',
	["alpha/a.spec.luau"] = 'return { ["passes"] = function() end, ["fails"] = function() error("boom") end }\n',
	["alpha/helper.luau"] = "return {}\n",
}

local function lines(output: string): { string }
	local list = {}
	for line in string.gmatch(output, "[^\n]+") do
		table.insert(list, line)
	end
	return list
end

return {
	["runs discovered specs in sorted file and test order"] = function()
		withTree(TREE, function(root)
			local ok, output = specs.run({ roots = { root } })
			assert(not ok, "a failing test must fail the run")
			local got = lines(output)
			local expected = {
				"FAIL " .. root .. "/alpha/a.spec.luau :: fails :: ",
				"PASS " .. root .. "/alpha/a.spec.luau :: passes",
				"PASS " .. root .. "/zeta/z.spec.luau :: a first",
				"PASS " .. root .. "/zeta/z.spec.luau :: b second",
			}
			assert(#got == 5, output)
			for index, prefix in expected do
				assert(string.sub(got[index], 1, #prefix) == prefix, "line " .. index .. ": " .. got[index])
			end
			assert(string.find(got[1], "boom", 1, true), got[1])
			assert(string.match(got[5], "^specs: 3 passed, 1 failed, 2 files, %d+%.%d+ s$"), got[5])
		end)
	end,

	["filters match spec path or path :: test name substrings"] = function()
		withTree(TREE, function(root)
			local ok, output = specs.run({ roots = { root }, filters = { "zeta/" } })
			assert(ok, output)
			local got = lines(output)
			assert(#got == 3 and string.match(got[3], "^specs: 2 passed, 0 failed, 1 files, "), output)

			ok, output = specs.run({ roots = { root }, filters = { "nomatch", "a.spec.luau :: pass" } })
			assert(ok, output)
			got = lines(output)
			assert(#got == 2 and got[1] == "PASS " .. root .. "/alpha/a.spec.luau :: passes", output)
			assert(string.match(got[2], "^specs: 1 passed, 0 failed, 1 files, "), output)
		end)
	end,

	["a filter matching zero tests fails the run"] = function()
		withTree(TREE, function(root)
			local ok, output = specs.run({ roots = { root }, filters = { "does-not-exist", "nor-this" } })
			assert(not ok, "zero matches must fail")
			assert(output == "specs: no tests matched does-not-exist, nor-this", output)
		end)
	end,

	["quiet prints only failures and the summary, slowest lists the slowest tests"] = function()
		withTree(TREE, function(root)
			local ok, output = specs.run({ roots = { root }, quiet = true })
			assert(not ok, output)
			local got = lines(output)
			assert(#got == 2, output)
			assert(string.sub(got[1], 1, 5) == "FAIL " and string.find(got[1], "boom", 1, true), got[1])
			assert(string.match(got[2], "^specs: 3 passed, 1 failed, 2 files, "), got[2])

			ok, output = specs.run({ roots = { root }, quiet = true, slowest = 2 })
			got = lines(output)
			assert(#got == 4, output)
			assert(string.match(got[2], "^SLOW %d+%.%d ms ") and string.match(got[3], "^SLOW "), output)
		end)
	end,

	["json report follows schema version 1"] = function()
		withTree(TREE, function(root)
			local jsonPath = root .. "/report.json"
			specs.run({ roots = { root }, quiet = true, json = jsonPath })
			local report = serde.decode("json", fs.readFile(jsonPath))
			assert(report.schemaVersion == 1, "schemaVersion")
			assert(report.passed == 3 and report.failed == 1 and report.files == 2, fs.readFile(jsonPath))
			assert(type(report.durationMs) == "number" and report.durationMs >= 0, "durationMs")
			assert(#report.failures == 1, "failures")
			local failure = report.failures[1]
			assert(failure.file == root .. "/alpha/a.spec.luau" and failure.test == "fails", "failure entry")
			assert(string.find(failure.error, "boom", 1, true), failure.error)
			assert(#report.tests == 4, "tests")
			assert(report.tests[2].test == "passes" and report.tests[2].ok == true, "sorted test entries")
			for _, entry in report.tests do
				assert(type(entry.file) == "string" and type(entry.ms) == "number", "test entry shape")
			end

			local passPath = root .. "/pass.json"
			specs.run({ roots = { root }, filters = { "zeta" }, json = passPath })
			local raw = fs.readFile(passPath)
			assert(string.find(raw, '"failures":[]', 1, true), raw)
		end)
	end,

	["compile failures stop the run even when filtered out"] = function()
		withTree({
			["ok/fine.spec.luau"] = "return { t = function() end }\n",
			["broken/bad.luau"] = "local = \n",
		}, function(root)
			local ok, output = specs.run({ roots = { root }, filters = { "fine" }, quiet = true })
			assert(not ok, output)
			local got = lines(output)
			assert(#got == 2, output)
			assert(
				string.sub(got[1], 1, #("FAIL " .. root .. "/broken/bad.luau :: compile :: "))
					== "FAIL " .. root .. "/broken/bad.luau :: compile :: ",
				got[1]
			)
		end)
	end,

	["path filters skip requiring non-matching specs, name-only filters fall back"] = function()
		withTree({
			["ok/fine.spec.luau"] = 'return { ["target test"] = function() end }\n',
		}, function(root)
			-- Requiring this spec leaves a marker file before its top-level error.
			local marker = root .. "/required.marker"
			fs.writeDir(root .. "/bad")
			fs.writeFile(
				root .. "/bad/explodes.spec.luau",
				string.format('require("@lune/fs").writeFile(%q, "x")\nerror("top-level boom")\n', marker)
			)
			local ok, output = specs.run({ roots = { root }, filters = { "fine" }, quiet = true })
			assert(ok, output)
			assert(not fs.isFile(marker), "a spec outside the path filter was required")
			assert(string.match(output, "^specs: 1 passed, 0 failed, 1 files, "), output)

			ok, output = specs.run({ roots = { root }, filters = { "target test" }, quiet = true })
			assert(ok, output)
			assert(fs.isFile(marker), "a test-name-only filter must search every spec")
			assert(string.match(output, "^specs: 1 passed, 0 failed, 1 files, "), output)
		end)
	end,
}
