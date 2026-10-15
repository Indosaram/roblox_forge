--!strict
local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local run = require("../lib/run")
local codegen = require("../lib/codegen")
local assetsLib = require("../lib/assets")
local gameYml = require("../lib/gameyml")
local lock = require("../lib/lock")
local buildtargets = require("../lib/buildtargets")
local publication = require("../lib/packpublication")

local registryLib = require("../lib/genreregistry")
local contract = require("../lib/genrecontract")
local qaCommand = require("./qa")
local Profile = require("../lib/profile")
local M = {}
function M.validatePackContract(game: any, config: any, registry: registryLib.Registry): { string }
	local result = gameYml.validate(game, { registry = registry, config = config })
	local _, qaErrors = qaCommand.planPack("check", game, registry)
	for _, err in qaErrors do
		table.insert(result.errors, err)
	end
	table.sort(result.errors)
	return result.errors
end

local DEFINITIONS_URL = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.70.1/scripts/globalTypes.d.luau"
local DEFINITIONS_SHA256 = "2857efa8245485f8c25c19c018ee1ef9b46afab4efd2ea70fc3257cd3faf7080"
local DEFINITIONS_CACHE_PATH = "build/cache/globalTypes.d.luau"
local PACKS_DIR = "games"
local function sourcePaths(root: string, luneOnly: boolean): { string }
	local paths = {}
	local function visit(directory: string)
		for _, name in fs.readDir(directory) do
			local path = directory .. "/" .. name
			if fs.isDir(path) then
				visit(path)
			elseif string.match(name, "%.luau$") then
				local source = fs.readFile(path)
				local hostOnly = string.find(source, 'require("@lune/', 1, true) ~= nil
					or string.match(source, "require%([\"'][^\"']*cli/forge/") ~= nil
					or string.find(source, '.spec")', 1, true) ~= nil
				if hostOnly == luneOnly then
					table.insert(paths, path)
				end
			end
		end
	end
	visit(root)
	table.sort(paths)
	return paths
end

local function rewriteSourcemapFilePaths(node: any, prefix: string)
	if typeof(node) ~= "table" then
		return
	end
	if node.filePaths and typeof(node.filePaths) == "table" then
		local newPaths = {}
		for _, path in node.filePaths do
			if typeof(path) == "string" then
				if string.sub(path, 1, 6) == "../../" then
					table.insert(newPaths, string.sub(path, 7))
				else
					table.insert(newPaths, prefix .. path)
				end
			else
				table.insert(newPaths, path)
			end
		end
		node.filePaths = newPaths
	end
	if node.children and typeof(node.children) == "table" then
		for _, child in node.children do
			rewriteSourcemapFilePaths(child, prefix)
		end
	end
end

local function ensureDefinitions(): (boolean, string)
	if fs.isFile(DEFINITIONS_CACHE_PATH) then
		local cached = fs.readFile(DEFINITIONS_CACHE_PATH)
		local hash = serde.hash("sha256", cached)
		if hash == DEFINITIONS_SHA256 then
			return true, DEFINITIONS_CACHE_PATH
		end
	end

	if not fs.isDir("build") then
		fs.writeDir("build")
	end
	if not fs.isDir("build/cache") then
		fs.writeDir("build/cache")
	end

	local requestOk, resp = pcall(net.request, DEFINITIONS_URL)
	if not requestOk then
		return false, "failed to download definitions from " .. DEFINITIONS_URL .. ": " .. tostring(resp)
	end
	if not resp.ok or resp.statusCode ~= 200 then
		return false,
			"failed to download definitions from " .. DEFINITIONS_URL .. " (status " .. tostring(resp.statusCode) .. ")"
	end

	local hash = serde.hash("sha256", resp.body)
	if hash ~= DEFINITIONS_SHA256 then
		return false, "definitions sha256 mismatch: expected " .. DEFINITIONS_SHA256 .. " but got " .. hash
	end

	fs.writeFile(DEFINITIONS_CACHE_PATH, resp.body)
	return true, DEFINITIONS_CACHE_PATH
end

-- Every stage line carries its wall time; tool detail is only shown on FAIL.
local function printStage(stage: string, pass: boolean, ms: number, detail: string?)
	stdio.write(string.format("[%s] %s (%.1f s)\n", stage, if pass then "PASS" else "FAIL", ms / 1000))
	if not pass and detail and detail ~= "" then
		local trimmed = string.gsub(detail, "^%s*(.-)%s*$", "%1")
		if trimmed ~= "" then
			stdio.write(trimmed .. "\n")
		end
	end
end

local function parseLspDiagnostics(output: string): (number, number)
	local errors = 0
	local warnings = 0
	for line in string.gmatch(output, "[^\r\n]+") do
		if string.find(line, "^%s*%[INFO%]") or string.find(line, "^%s*%[WARN%]") or string.find(line, "^WARNING:") then
			continue
		end
		local _, _, diagType = string.find(line, "^.-%(%d+,%d+%):%s*([%w_]+):")
		if diagType then
			if string.find(string.lower(diagType), "error") or diagType == "UnknownSymbol" then
				errors += 1
			else
				warnings += 1
			end
		elseif string.find(line, "Cannot get ") and string.find(line, "path does not exist") then
			errors += 1
		end
	end
	return errors, warnings
end

local function listPacks(projectOnly: boolean?): { string }
	local packs: { string } = {}
	for _, name in fs.readDir(PACKS_DIR) do
		if
			fs.isDir(PACKS_DIR .. "/" .. name)
			and (
				fs.isFile(PACKS_DIR .. "/" .. name .. "/default.project.json")
				or (not projectOnly and fs.isFile(PACKS_DIR .. "/" .. name .. "/game.yml"))
			)
		then
			table.insert(packs, name)
		end
	end
	table.sort(packs)
	return packs
end

local function analyzePack(pack: string, defsPath: string): (boolean, { string })
	local logs: { string } = {}
	local projectPath = PACKS_DIR .. "/" .. pack .. "/default.project.json"
	local sourcemapPath = "build/sourcemap-" .. pack .. ".json"

	if not fs.isDir("build") then
		fs.writeDir("build")
	end

	local smRes = run.exec("rojo", { "sourcemap", projectPath, "-o", sourcemapPath })
	if not smRes.ok then
		table.insert(logs, "luau-lsp (roblox, " .. pack .. "): rojo sourcemap failed: " .. smRes.stderr)
		return false, logs
	end

	local parsedOk, parsed = pcall(function()
		return serde.decode("json", fs.readFile(sourcemapPath))
	end)
	if not parsedOk or typeof(parsed) ~= "table" then
		table.insert(logs, "luau-lsp (roblox, " .. pack .. "): could not parse sourcemap")
		return false, logs
	end
	rewriteSourcemapFilePaths(parsed, PACKS_DIR .. "/" .. pack .. "/")
	fs.writeFile(sourcemapPath, serde.encode("json", parsed))

	local args = {
		"analyze",
		"--definitions",
		"@roblox=" .. defsPath,
		"--sourcemap",
		sourcemapPath,
	}
	for _, root in { "core", "genres", PACKS_DIR .. "/" .. pack .. "/src" } do
		for _, path in sourcePaths(root, false) do
			table.insert(args, path)
		end
	end
	local res = run.exec("luau-lsp", args)
	local out = res.stdout
	if res.stderr ~= "" then
		out = out .. "\n" .. res.stderr
	end
	local errors, warnings = parseLspDiagnostics(out)
	table.insert(logs, string.format("luau-lsp (roblox, %s): %d errors, %d warnings", pack, errors, warnings))
	if out ~= "" then
		table.insert(logs, out)
	end
	return res.ok and errors == 0, logs
end

-- Stage ids in execution order. `build` also inspects every built place.
M.STAGES = {
	"genre-contract",
	"qa-schema",
	"selene",
	"stylua",
	"luau-lsp",
	"econ",
	"game",
	"assets",
	"locale",
	"lock",
	"specs",
	"build",
}

-- Tools each stage needs; only stages that run are preflighted.
local STAGE_TOOLS: { [string]: { string } } = {
	selene = { "selene" },
	stylua = { "stylua" },
	["luau-lsp"] = { "luau-lsp", "rojo" },
	locale = { "lune" },
	specs = { "lune" },
	build = { "rojo" },
}

-- Stages that read the genre registry.
local REGISTRY_STAGES = { "genre-contract", "qa-schema", "econ", "game", "lock" }

export type StageOptions = {
	run: { [string]: boolean },
	jsonPath: string?,
	rest: { string },
}

local function usageError(message: string): string
	return message .. "; valid stages: " .. table.concat(M.STAGES, ", ")
end

-- Splits --only/--skip/--json out of argv (from startIndex) and returns the
-- remaining target-selector args untouched.
function M.parseStageArgs(argv: { string }, startIndex: number?): (StageOptions?, string?)
	local known: { [string]: boolean } = {}
	for _, id in M.STAGES do
		known[id] = true
	end
	local only: { [string]: boolean }? = nil
	local skip: { [string]: boolean } = {}
	local jsonPath: string? = nil
	local rest: { string } = {}
	local seen: { [string]: boolean } = {}
	local index = startIndex or 1
	while index <= #argv do
		local arg = argv[index]
		if arg == "--only" or arg == "--skip" or arg == "--json" then
			if seen[arg] then
				return nil, "duplicate " .. arg
			end
			seen[arg] = true
			local value = argv[index + 1]
			if value == nil or value == "" or string.sub(value, 1, 2) == "--" then
				return nil,
					if arg == "--json" then "--json requires a path" else usageError(arg .. " requires a stage list")
			end
			if arg == "--json" then
				jsonPath = value
			else
				local set: { [string]: boolean } = {}
				for name in string.gmatch(value, "[^,]+") do
					local id = string.gsub(name, "^%s*(.-)%s*$", "%1")
					if not known[id] then
						return nil, usageError("unknown stage '" .. id .. "'")
					end
					set[id] = true
				end
				if arg == "--only" then
					only = set
				else
					skip = set
				end
			end
			index += 2
		else
			table.insert(rest, arg)
			index += 1
		end
	end
	local runSet: { [string]: boolean } = {}
	for _, id in M.STAGES do
		runSet[id] = (only == nil or only[id] == true) and not skip[id]
	end
	return { run = runSet, jsonPath = jsonPath, rest = rest }, nil
end

-- serde encodes an empty table as {}; `failed` is a list, so keep it [].
function M.encodeReport(report: { [string]: any }): string
	local encoded = serde.encode("json", report, true)
	encoded = string.gsub(encoded, '"failed":(%s*){}', '"failed":%1[]')
	return encoded
end

function M.run(args: { string }?): boolean
	local startedAt = os.clock()
	local argv = args or process.args
	local options, optionsErr = M.parseStageArgs(argv, 2)
	if options == nil then
		stdio.ewrite("check: " .. tostring(optionsErr) .. "\n")
		return false
	end
	local selection, selectorErr = buildtargets.parseSelectors(options.rest, 1)
	if selection == nil then
		stdio.ewrite("check: " .. tostring(selectorErr) .. "\n")
		return false
	end
	local enabled = options.run

	local tools: { string } = {}
	local toolSeen: { [string]: boolean } = {}
	for _, id in M.STAGES do
		if enabled[id] and STAGE_TOOLS[id] then
			for _, tool in STAGE_TOOLS[id] do
				if not toolSeen[tool] then
					toolSeen[tool] = true
					table.insert(tools, tool)
				end
			end
		end
	end
	local ready, prerequisiteError = run.preflight(tools)
	if not ready then
		stdio.ewrite(tostring(prerequisiteError) .. "\n")
		return false
	end
	-- Other check stages inspect real packs even when the build selector points
	-- elsewhere. Reject pending publication before any tool or source consumer.
	for _, pack in listPacks() do
		local pending = publication.pending(PACKS_DIR .. "/" .. pack)
		if pending then
			stdio.ewrite(pending .. "\n")
			return false
		end
	end
	local _, publicationErrors = buildtargets.resolveTargets(selection, "all")
	for _, err in publicationErrors do
		if string.find(err, "FORGE_PUBLICATION_PENDING:", 1, true) then
			stdio.ewrite(err .. "\n")
			return false
		end
	end

	local registry: registryLib.Registry? = nil
	local registryErrors: { string } = {}
	for _, id in REGISTRY_STAGES do
		if enabled[id] then
			registry, registryErrors = registryLib.discover()
			break
		end
	end
	local gamePacks = listPacks()

	local stageFns: { [string]: () -> (boolean, string) } = {}

	stageFns["genre-contract"] = function(): (boolean, string)
		return registry ~= nil, table.concat(registryErrors, "\n")
	end

	stageFns["qa-schema"] = function(): (boolean, string)
		if not registry then
			return false, "genre registry unavailable:\n" .. table.concat(registryErrors, "\n")
		end
		local errors = qaCommand.validateRegistry(registry)
		return #errors == 0, table.concat(errors, "\n")
	end

	stageFns.selene = function(): (boolean, string)
		local res = run.exec("selene", { "." })
		return res.ok, res.stdout .. (if res.stderr ~= "" then "\n" .. res.stderr else "")
	end

	stageFns.stylua = function(): (boolean, string)
		local res = run.exec("stylua", { "--check", "." })
		return res.ok, res.stdout .. (if res.stderr ~= "" then "\n" .. res.stderr else "")
	end

	stageFns["luau-lsp"] = function(): (boolean, string)
		local lspSuccess = true
		local lspLogs: { string } = {}

		if not fs.isDir("build") then
			fs.writeDir("build")
		end

		local defsOk, defsPathOrErr = ensureDefinitions()
		if not defsOk then
			lspSuccess = false
			table.insert(lspLogs, "definitions error: " .. defsPathOrErr)
		else
			local packs = listPacks(true)
			if #packs == 0 then
				lspSuccess = false
				table.insert(lspLogs, "error: no game packs found under " .. PACKS_DIR)
			end
			for _, pack in packs do
				local packOk, packLogs = analyzePack(pack, defsPathOrErr)
				if not packOk then
					lspSuccess = false
				end
				for _, line in packLogs do
					table.insert(lspLogs, line)
				end
			end

			-- Analyze Lune code (cli) with --platform=standard
			local luneArgs = { "analyze", "--platform=standard", "cli" }
			for _, root in { "core", "genres" } do
				for _, path in sourcePaths(root, true) do
					table.insert(luneArgs, path)
				end
			end
			local luneRes = run.exec("luau-lsp", luneArgs)
			if not luneRes.ok then
				lspSuccess = false
				table.insert(lspLogs, string.format("luau-lsp (cli/lune): exit code %d", luneRes.code))
			end
			local luneOut = luneRes.stdout
			if luneRes.stderr ~= "" then
				luneOut = luneOut .. "\n" .. luneRes.stderr
			end
			local luneErrors, luneWarnings = parseLspDiagnostics(luneOut)
			if luneErrors > 0 then
				lspSuccess = false
			end
			table.insert(
				lspLogs,
				string.format("luau-lsp (cli/lune): %d errors, %d warnings", luneErrors, luneWarnings)
			)
			if luneOut ~= "" then
				table.insert(lspLogs, luneOut)
			end
		end

		return lspSuccess, table.concat(lspLogs, "\n")
	end

	-- econ codegen drift (runs before specs so a stale EconConfig fails early)
	stageFns["econ"] = function(): (boolean, string)
		local econFailed = false
		local econLogs: { string } = {}
		for _, pack in gamePacks do
			local econPath = "games/" .. pack .. "/econ.yml"
			if fs.isFile(econPath) then
				local outputName = "EconConfig.luau"
				local genOk, generated = pcall(function()
					local name, content = codegen.generateDocument(fs.readFile(econPath), registry)
					outputName = name
					return content
				end)
				local generatedPath = "games/" .. pack .. "/src/shared/" .. outputName
				if not genOk then
					econFailed = true
					table.insert(econLogs, "econ drift: " .. econPath .. " does not generate: " .. tostring(generated))
				elseif not fs.isFile(generatedPath) or fs.readFile(generatedPath) ~= generated then
					econFailed = true
					table.insert(
						econLogs,
						"econ drift: " .. generatedPath .. " is out of date; run lune run cli/forge codegen"
					)
				end
			end
		end
		return not econFailed, table.concat(econLogs, "\n")
	end

	-- every pack's game.yml must be complete (no scaffold TBDs)
	stageFns["game"] = function(): (boolean, string)
		local gameFailed = false
		local gameLogs: { string } = {}
		for _, pack in gamePacks do
			local gamePath = "games/" .. pack .. "/game.yml"
			if fs.isFile(gamePath) then
				local gameOk, decodedGame = pcall(function()
					return serde.decode("yaml", fs.readFile(gamePath))
				end)
				if not gameOk then
					gameFailed = true
					table.insert(gameLogs, pack .. ": could not decode " .. gamePath)
				else
					local config = nil
					local configPath = "games/" .. pack .. "/econ.yml"
					if fs.isFile(configPath) then
						local configOk, decoded = pcall(function()
							return serde.decode("yaml", fs.readFile(configPath))
						end)
						if configOk then
							config = decoded
						end
					end
					local errors: { string } = if registry
						then M.validatePackContract(decodedGame, config, registry)
						else gameYml.validate(decodedGame).errors
					if #errors > 0 then
						gameFailed = true
						for _, err in errors do
							table.insert(gameLogs, pack .. ": " .. err)
						end
					end
				end
			end
		end
		return not gameFailed, table.concat(gameLogs, "\n")
	end

	-- asset manifests must gate cleanly and Assets.luau must not drift
	stageFns["assets"] = function(): (boolean, string)
		local assetsFailed = false
		local assetsLogs: { string } = {}
		for _, pack in gamePacks do
			local manifestPath = "games/" .. pack .. "/assets/manifest.yml"
			if fs.isFile(manifestPath) then
				local decodeOk, decoded = pcall(function()
					return serde.decode("yaml", fs.readFile(manifestPath))
				end)
				if not decodeOk or typeof(decoded) ~= "table" then
					assetsFailed = true
					table.insert(assetsLogs, pack .. ": failed to decode " .. manifestPath)
				else
					local manifest, parseErr = assetsLib.parseManifest(decoded)
					if manifest == nil then
						assetsFailed = true
						table.insert(assetsLogs, pack .. ": " .. (parseErr or "invalid manifest"))
					else
						local result = assetsLib.check(manifest, "staging")
						if not result.ok then
							assetsFailed = true
							for _, err in result.errors do
								table.insert(assetsLogs, pack .. ": " .. err)
							end
						end
						local framework = assetsLib.checkFramework(manifest)
						if not framework.ok then
							assetsFailed = true
							for _, err in framework.errors do
								table.insert(assetsLogs, pack .. ": " .. err)
							end
						end
						local generatedPath = "games/" .. pack .. "/src/shared/Assets.luau"
						local expected = assetsLib.renderLuau(manifest, pack)
						if not fs.isFile(generatedPath) or fs.readFile(generatedPath) ~= expected then
							assetsFailed = true
							table.insert(
								assetsLogs,
								"assets drift: "
									.. generatedPath
									.. " is out of date; run: lune run cli/forge assets codegen --pack "
									.. pack
							)
						end
					end
				end
			end
		end
		return not assetsFailed, table.concat(assetsLogs, "\n")
	end

	-- every pack's locale table must cover its client literals and ko-kr
	stageFns["locale"] = function(): (boolean, string)
		local localeFailed = false
		local localeLogs: { string } = {}
		for _, pack in listPacks() do
			if fs.isFile("games/" .. pack .. "/locale/strings.csv") then
				local res = run.exec("lune", { "run", "cli/forge", "locale", "check", "--pack", pack })
				local out = res.stdout
				if res.stderr ~= "" then
					out = out .. "\n" .. res.stderr
				end
				if not res.ok then
					localeFailed = true
				end
				if out ~= "" then
					table.insert(localeLogs, out)
				end
			end
		end
		return not localeFailed, table.concat(localeLogs, "\n")
	end

	-- forge-lock pins must match the packages the pack references
	stageFns["lock"] = function(): (boolean, string)
		local lockFailed = false
		local lockLogs: { string } = {}

		local function packageVersion(path: string): string?
			local readOk, text = pcall(fs.readFile, path)
			if not readOk then
				return nil
			end
			local decodeOk, decoded = pcall(function()
				return serde.decode("yaml", text)
			end)
			if not decodeOk or typeof(decoded) ~= "table" then
				return nil
			end
			local version = decoded.version
			return if typeof(version) == "string" and version ~= "" then version else nil
		end

		local coreVersion = packageVersion("core/forge-package.yml")
		if coreVersion == nil then
			lockFailed = true
			table.insert(lockLogs, "core: could not read a version from core/forge-package.yml")
		end

		for _, pack in listPacks() do
			local lockPath = "games/" .. pack .. "/forge-lock.yml"
			if not fs.isFile(lockPath) then
				lockFailed = true
				table.insert(lockLogs, pack .. ": missing " .. lockPath)
				continue
			end

			local decodeOk, decodedLock = pcall(function()
				return serde.decode("yaml", fs.readFile(lockPath))
			end)
			if not decodeOk then
				lockFailed = true
				table.insert(lockLogs, pack .. ": " .. lockPath .. " does not decode: " .. tostring(decodedLock))
				continue
			end

			local gameOk, game = pcall(function()
				return serde.decode("yaml", fs.readFile("games/" .. pack .. "/game.yml"))
			end)
			if not gameOk or type(game) ~= "table" or not contract.dense(game.genres, 64) or #game.genres == 0 then
				lockFailed = true
				table.insert(lockLogs, pack .. ": invalid genres list")
				continue
			end
			local packGenres: { string } = game.genres
			local expectedGenres: { [string]: string } = {}
			local seen = {}
			for _, id in packGenres do
				if not contract.id(id) or seen[id] or not registry or not registry.packages[id] then
					lockFailed = true
					table.insert(lockLogs, pack .. ": invalid/duplicate/unknown genre " .. tostring(id))
				else
					expectedGenres[id] = registry.packages[id].manifest.version
				end
				seen[id] = true
			end

			if coreVersion ~= nil then
				local errors = lock.validate(lock.fromTable(decodedLock), {
					core = coreVersion,
					genres = expectedGenres,
					packGenres = packGenres,
				})
				for _, err in errors do
					lockFailed = true
					table.insert(lockLogs, pack .. ": " .. err)
				end
			end
		end
		return not lockFailed, table.concat(lockLogs, "\n")
	end

	-- specs run as a child process so a broken module cannot wedge the checker.
	-- "--quiet" keeps passing spec output out of the log; older specs-run ignores it.
	stageFns.specs = function(): (boolean, string)
		local res = run.exec("lune", { "run", "cli/forge", "specs-run", "--quiet" })
		return res.ok, res.stdout .. (if res.stderr ~= "" then "\n" .. res.stderr else "")
	end

	-- build and inspect every selected target. With no selector this is every
	-- declared pack under `games`; `--packs-root <dir>` swaps the discovery root
	-- (QA build matrices) for this stage only. Each target is independent: one
	-- failing build never stops another target, and a target whose build failed
	-- is never inspected, so no stale artifact can report a pass.
	stageFns["build"] = function(): (boolean, string)
		local targets, resolveErrors = buildtargets.resolveTargets(selection, "all")
		local buildLogs: { string } = {}
		local inspectLogs: { string } = {}
		local buildFailed = #resolveErrors > 0
		local inspectFailed = #resolveErrors > 0
		for _, err in resolveErrors do
			table.insert(buildLogs, "ERROR: " .. err)
			table.insert(inspectLogs, "ERROR: " .. err)
		end

		for _, result in buildtargets.runTargets(targets) do
			for _, log in result.logs do
				table.insert(buildLogs, log)
			end
			table.insert(buildLogs, buildtargets.formatBuild(result))
			table.insert(inspectLogs, buildtargets.formatInspect(result))
			if not result.built then
				buildFailed = true
				inspectFailed = true
			elseif not result.ok then
				inspectFailed = true
			end
			for _, err in result.errors do
				if result.built then
					table.insert(inspectLogs, "ERROR: " .. err)
				else
					table.insert(buildLogs, "ERROR: " .. err)
				end
			end
		end

		local detail = "build:\n" .. table.concat(buildLogs, "\n") .. "\ninspect:\n" .. table.concat(inspectLogs, "\n")
		return not buildFailed and not inspectFailed, detail
	end

	local profile = Profile.new()
	local stages: { { id: string, ok: boolean, skipped: boolean, ms: number } } = {}
	local failed: { string } = {}
	local ran = 0
	for _, id in M.STAGES do
		if not enabled[id] then
			table.insert(stages, { id = id, ok = true, skipped = true, ms = 0 })
			continue
		end
		local invoked, ok, detail = pcall(function()
			return profile:span(id, stageFns[id])
		end)
		local ms = 0
		for _, row in profile:report() do
			if row.name == id then
				ms = row.totalMs
			end
		end
		if not invoked then
			ok, detail = false, "stage error: " .. tostring(ok)
		end
		ran += 1
		printStage(id, ok == true, ms, detail)
		table.insert(stages, { id = id, ok = ok == true, skipped = false, ms = ms })
		if ok ~= true then
			table.insert(failed, id)
		end
	end

	local passed = #failed == 0
	local totalMs = (os.clock() - startedAt) * 1000
	if passed then
		stdio.write(string.format("check: PASS (%d stages, %.1f s)\n", ran, totalMs / 1000))
	else
		stdio.write(string.format("check: FAIL stages=%s (%.1f s)\n", table.concat(failed, ","), totalMs / 1000))
	end

	if options.jsonPath then
		local report = { schemaVersion = 1, ok = passed, stages = stages, failed = failed }
		local wrote, writeErr = pcall(fs.writeFile, options.jsonPath, M.encodeReport(report))
		if not wrote then
			stdio.ewrite("check: could not write " .. options.jsonPath .. ": " .. tostring(writeErr) .. "\n")
			return false
		end
	end

	return passed
end

return M
