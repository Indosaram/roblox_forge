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

	["units split a file heavier than half a share into per-test units plus a remainder"] = function()
		local timings = {
			files = { ["h.spec.luau"] = 900, ["l.spec.luau"] = 100 },
			tests = { ["h.spec.luau"] = { b = 600, a = 300 }, ["l.spec.luau"] = { x = 100 } },
		}
		local units, weights = specs.units({ "h.spec.luau", "l.spec.luau" }, 2, timings)
		local expected = { "h.spec.luau\ta", "h.spec.luau\tb", "h.spec.luau\t<unrecorded>", "l.spec.luau" }
		assert(table.concat(units, "|") == table.concat(expected, "|"), table.concat(units, "|"))
		assert(weights["h.spec.luau\ta"] == 300 and weights["h.spec.luau\tb"] == 600, "per-test weights")
		assert(weights["h.spec.luau\t<unrecorded>"] == 0 and weights["l.spec.luau"] == nil, "remainder/unsplit")

		-- A heavy file without per-test timings cannot be split and stays one unit.
		local single = specs.units({ "h.spec.luau", "l.spec.luau" }, 2, { files = timings.files, tests = {} })
		assert(table.concat(single, "|") == "h.spec.luau|l.spec.luau", table.concat(single, "|"))
	end,

	["partition assigns every unit exactly once, heaviest first to the lightest shard"] = function()
		local files = { "a.spec.luau", "b.spec.luau", "c.spec.luau", "d.spec.luau" }
		local timings = {
			files = { ["a.spec.luau"] = 50, ["b.spec.luau"] = 40, ["c.spec.luau"] = 30, ["d.spec.luau"] = 20 },
			tests = {},
		}
		local shards = specs.partition(files, 2, timings)
		assert(#shards == 2, "shards " .. #shards)
		-- LPT: a(50)->1, b(40)->2, c(30)->2 (40<50), d(20)->1 (50<70): loads 70 / 70.
		assert(table.concat(shards[1], ",") == "a.spec.luau,d.spec.luau", table.concat(shards[1], ","))
		assert(table.concat(shards[2], ",") == "b.spec.luau,c.spec.luau", table.concat(shards[2], ","))

		-- More jobs than units: empty shards are dropped, every unit still appears once.
		local wide = specs.partition({ "a.spec.luau", "b.spec.luau" }, 5, timings)
		assert(#wide == 2 and #wide[1] == 1 and #wide[2] == 1, "empty shards must be dropped")

		-- A split heavy file spreads its tests across shards.
		local split = specs.partition({ "h.spec.luau" }, 2, {
			files = { ["h.spec.luau"] = 200 },
			tests = { ["h.spec.luau"] = { a = 100, b = 100 } },
		})
		local seen: { [string]: number } = {}
		for _, shard in split do
			for _, unit in shard do
				seen[unit] = (seen[unit] or 0) + 1
			end
		end
		assert(#split == 2, "split file should use both shards")
		assert(seen["h.spec.luau\ta"] == 1 and seen["h.spec.luau\tb"] == 1, "each test once")
		assert(seen["h.spec.luau\t<unrecorded>"] == 1, "remainder once")
	end,

	["files entries select single tests, and the remainder selects only unrecorded tests"] = function()
		withTree({
			["s/m.spec.luau"] = "return { one = function() end, two = function() end, three = function() end }\n",
		}, function(root)
			local file = root .. "/s/m.spec.luau"
			local ok, output = specs.run({ files = { file .. "\ttwo" } })
			assert(ok, output)
			local got = lines(output)
			assert(#got == 2 and got[1] == "PASS " .. file .. " :: two", output)

			local timings = { files = { [file] = 2 }, tests = { [file] = { one = 1, two = 1 } } }
			ok, output = specs.run({ files = { file .. "\t<unrecorded>" }, timings = timings })
			assert(ok, output)
			got = lines(output)
			assert(#got == 2 and got[1] == "PASS " .. file .. " :: three", output)

			-- Split units together cover the file exactly once.
			ok, output = specs.run({
				files = { file .. "\tone", file .. "\ttwo", file .. "\t<unrecorded>" },
				timings = timings,
			})
			assert(ok, output)
			assert(string.match(lines(output)[4], "^specs: 3 passed, 0 failed, 1 files, "), output)
		end)
	end,

	["sharded run matches the serial test set, and a crashed shard fails the run"] = function()
		withTree({
			["p/a.spec.luau"] = "return { a1 = function() end, a2 = function() end }\n",
			["p/b.spec.luau"] = "return { b1 = function() end }\n",
		}, function(root)
			local okSerial, serial = specs.run({ roots = { root } })
			local okSharded, sharded = specs.run({ roots = { root }, jobs = 2 })
			assert(okSerial and okSharded, sharded)
			local a, b = lines(serial), lines(sharded)
			assert(#a == 4 and #b == 4, sharded)
			for index = 1, 3 do
				assert(a[index] == b[index], "line " .. index .. ": " .. tostring(b[index]))
			end
			assert(string.match(b[4], "^specs: 3 passed, 0 failed, 2 files, "), b[4])

			-- A spec that kills its own process leaves its shard without a report.
			fs.writeFile(
				root .. "/p/crash.spec.luau",
				'return { dies = function() require("@lune/process").exit(7) end }\n'
			)
			local okCrash, crashed = specs.run({ roots = { root }, jobs = 2, quiet = true })
			assert(not okCrash, "a crashed shard must fail the run: " .. crashed)
			assert(string.find(crashed, "SHARD %d+ exited 7 without a report"), crashed)
			assert(string.find(crashed, "FAIL (shards) :: worker :: ", 1, true), crashed)
		end)
	end,
}
