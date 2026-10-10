--!strict
-- Specs for run: process.exec throws (rather than returning a non-ok result)
-- when the executable cannot be found (Lune 0.10.5), so forge check must pcall
-- it and report a failed stage instead of aborting with an uncaught error.

local process = require("@lune/process")
local run = require("./run")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local check = require("../commands/check")
local buildtargets = require("./buildtargets")
local identity = require("./buildidentity")
local generate = require("./genregenerate")
local publish = require("./genrepublish")

local function withExec(exec: (string, { string }) -> run.ExecResult, callback: () -> ())
	local original = run.exec
	run.exec = exec
	local ok, reason = xpcall(function()
		callback()
		return true
	end, debug.traceback)
	run.exec = original
	assert(ok, tostring(reason))
end

return {
	["real CLI runtime mismatch refuses before command imports or tool probes"] = function()
		local root = (process.env.TEMP or process.env.TMP or "/tmp")
			.. "/forge-runtime-"
			.. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
		assert(not fs.isDir(root), "fixture collision")
		fs.writeDir(root .. "/cli/forge/lib")
		local ok, reason = xpcall(function()
			fs.writeFile(root .. "/cli/forge/init.luau", fs.readFile("cli/forge/init.luau"))
			fs.writeFile(root .. "/cli/forge/lib/run.luau", fs.readFile("cli/forge/lib/run.luau"))
			-- A real runtime, with an incompatible release pin. Commands are deliberately
			-- absent: admission must precede their imports, not just their writes.
			fs.writeFile(root .. "/rokit.toml", '[tools]\nlune = "lune-org/lune@99.0.0"\n')
			local result = process.exec("lune", { "run", "cli/forge", "new", "fixture", "--genre", "collect-raid" }, {
				cwd = root,
			})
			assert(not result.ok and result.code == 1, "unsupported running runtime admitted")
			assert(string.find(result.stderr, "FORGE_RUNTIME_UNSUPPORTED:", 1, true), "runtime refusal missing")
			assert(not fs.isDir(root .. "/games") and not fs.isDir(root .. "/build"), "runtime refusal wrote output")
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
	["preflight rejects missing and unsupported tools without exposing child output"] = function()
		for _, output in { "missing", "stylua 0.0.0", "stylua 2.5.2-rc.1", "secret-value" } do
			withExec(function(tool, args)
				assert(tool == "stylua" and args[1] == "--version", "only version probe permitted")
				return { ok = output ~= "missing", code = 127, stdout = output, stderr = "secret-value" }
			end, function()
				local ok, reason = run.preflight({ "stylua" })
				assert(not ok and reason ~= nil, "unsupported prerequisite admitted")
				assert(not string.find(reason :: string, "secret-value", 1, true), "child output leaked")
			end)
		end
	end,
	["preflight admits manifest pins and requires every check dependency"] = function()
		local manifest = serde.decode("toml", fs.readFile("rokit.toml"))
		withExec(function(tool, args)
			assert(#args == 1 and args[1] == "--version", "only version probes permitted")
			local version = string.match(manifest.tools[tool], "@(.+)$") :: string
			local output = if tool == "luau-lsp" then version else tool .. " " .. version
			return { ok = true, code = 0, stdout = output .. "\n", stderr = "" }
		end, function()
			local ready, reason = run.preflight({ "selene", "stylua", "luau-lsp", "rojo", "lune" })
			assert(ready, tostring(reason))
		end)
		for _, missing in { "selene", "stylua", "luau-lsp", "rojo", "lune" } do
			local seen = false
			withExec(function(tool, args)
				assert(#args == 1 and args[1] == "--version", "check entered pipeline before admission")
				if tool == missing then
					seen = true
					return { ok = false, code = 127, stdout = "", stderr = "missing" }
				end
				local version = string.match(manifest.tools[tool], "@(.+)$") :: string
				return { ok = true, code = 0, stdout = tool .. " " .. version .. "\n", stderr = "" }
			end, function()
				assert(not check.run({ "check" }), "check admitted missing prerequisite")
				assert(seen, "dependency was not probed")
			end)
		end
	end,
	["missing formatter refuses assembly and direct publication before recovery or staging"] = function()
		local recover, ensureDir = publish.recover, publish.ensureDir
		local entered = false
		publish.recover = function(_destination, _observer)
			entered = true
			error("recovery must not run")
		end
		publish.ensureDir = function(_path)
			entered = true
			error("staging must not run")
		end
		local ok, reason = xpcall(function()
			withExec(function(tool, args)
				assert(tool == "stylua" and args[1] == "--version", "unexpected process")
				return { ok = false, code = 127, stdout = "", stderr = "missing" }
			end, function()
				local assembled, failure = pcall(function()
					generate.assemble({} :: any, {}, {} :: any, "unused")
				end)
				assert(
					not assembled and string.find(tostring(failure), "FORGE_TOOL_UNAVAILABLE", 1, true),
					"assembly did not refuse tool"
				)
				local assembly = { files = {}, order = {}, generation = {}, legacy = false }
				assert(not publish.write(assembly, "unused", "unused"), "publication admitted missing tool")
				assert(
					not publish.write(assembly, "unused", "unused", nil, nil, {}),
					"selected publication admitted missing tool"
				)
				assert(not entered, "recovery or staging entered before refusal")
			end)
		end, debug.traceback)
		publish.recover, publish.ensureDir = recover, ensureDir
		assert(ok, tostring(reason))
	end,
	["missing Rojo preserves existing artifact and sidecar before overlay creation"] = function()
		local root = (process.env.TEMP or process.env.TMP or "/tmp")
			.. "/forge-preflight-"
			.. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
		assert(not fs.isDir(root), "fixture collision")
		fs.writeDir(root)
		fs.writeFile(root .. "/old.rbxl", "old-place")
		fs.writeFile(root .. "/old.rbxl.identity.json", "old-identity")
		local prepare = identity.prepare
		local entered = false
		identity.prepare = function(_project, _pack, _output, _token)
			entered = true
			error("overlay must not run")
		end
		local ok, reason = xpcall(function()
			withExec(function(tool, args)
				assert(tool == "rojo" and args[1] == "--version", "build entered work before admission")
				return { ok = false, code = 127, stdout = "", stderr = "missing" }
			end, function()
				local result = buildtargets.runTarget({
					slug = "fixture",
					projectPath = root .. "/default.project.json",
					outputPath = root .. "/old.rbxl",
				} :: any)
				assert(not result.ok and not result.built and not result.removedStale, "missing tool mutated build")
				assert(not entered, "overlay created")
				assert(fs.readFile(root .. "/old.rbxl") == "old-place", "artifact modified")
				assert(fs.readFile(root .. "/old.rbxl.identity.json") == "old-identity", "identity modified")
				assert(#fs.readDir(root) == 2, "unexpected writes")
			end)
		end, debug.traceback)
		identity.prepare = prepare
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
	["F6: a missing executable is reported as a failed exec, not an uncaught error"] = function()
		local ok, result = pcall(function()
			return run.exec("this-tool-definitely-does-not-exist-xyz", {})
		end)
		assert(ok, "run.exec must not throw when the tool is missing: " .. tostring(result))
		local res = result :: run.ExecResult
		assert(not res.ok, "a missing executable must report ok = false")
		assert(res.code == 127, "a missing executable must report code 127, got " .. tostring(res.code))
		assert(res.stderr ~= "", "stderr must carry the underlying reason")
	end,

	["a real executable still runs and returns its exit code"] = function()
		local isWindows = process.os == "windows"
		local tool = if isWindows then "cmd" else "true"
		local args = if isWindows then { "/c", "exit", "0" } else {}
		local res = run.exec(tool, args)
		assert(res.ok, "a real executable must succeed: " .. res.stderr)
		assert(res.code == 0, "expected exit code 0, got " .. tostring(res.code))
	end,
}
