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

local function printStage(stage: string, pass: boolean, detail: string?)
	stdio.write(string.format("[%s] %s\n", stage, if pass then "PASS" else "FAIL"))
	if detail and detail ~= "" then
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

function M.run(args: { string }?): boolean
	local argv = args or process.args
	local selection, selectorErr = buildtargets.parseSelectors(argv, 2)
	if selection == nil then
		stdio.ewrite("check: " .. tostring(selectorErr) .. "\n")
		return false
	end

	local ready, prerequisiteError = run.preflight({ "selene", "stylua", "luau-lsp", "rojo", "lune" })
	if not ready then
		stdio.ewrite(tostring(prerequisiteError) .. "\n")
		return false
	end
	local anyFailed = false
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
	local registry, registryErrors = registryLib.discover()
	if not registry then
		anyFailed = true
	end
	printStage("genre-contract", registry ~= nil, table.concat(registryErrors, string.char(10)))
	if registry then
		local errors = qaCommand.validateRegistry(registry)
		if #errors > 0 then
			anyFailed = true
		end
		printStage("qa-schema", #errors == 0, table.concat(errors, string.char(10)))
	end

	-- Stage a: selene
	local seleneRes = run.exec("selene", { "." })
	local seleneOut = seleneRes.stdout
	if seleneRes.stderr ~= "" then
		seleneOut = seleneOut .. "\n" .. seleneRes.stderr
	end
	if not seleneRes.ok then
		anyFailed = true
		printStage("selene", false, seleneOut)
	else
		printStage("selene", true, seleneOut)
	end

	-- Stage b: stylua
	local styluaRes = run.exec("stylua", { "--check", "." })
	local styluaOut = styluaRes.stdout
	if styluaRes.stderr ~= "" then
		styluaOut = styluaOut .. "\n" .. styluaRes.stderr
	end
	if not styluaRes.ok then
		anyFailed = true
		printStage("stylua", false, styluaOut)
	else
		printStage("stylua", true, styluaOut)
	end

	-- Stage c: luau-lsp
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
		table.insert(lspLogs, string.format("luau-lsp (cli/lune): %d errors, %d warnings", luneErrors, luneWarnings))
		if luneOut ~= "" then
			table.insert(lspLogs, luneOut)
		end
	end

	local lspOutputText = table.concat(lspLogs, "\n")
	if not lspSuccess then
		anyFailed = true
		printStage("luau-lsp", false, lspOutputText)
	else
		printStage("luau-lsp", true, lspOutputText)
	end

	-- Stage d: econ codegen drift (must run before specs so a stale EconConfig fails early)
	local econFailed = false
	local econLogs: { string } = {}
	local gamePacks = listPacks()
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
	if econFailed then
		anyFailed = true
	end
	printStage("econ", not econFailed, table.concat(econLogs, "\n"))

	-- Stage d3: every pack's game.yml must be complete (no scaffold TBDs).
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
	if gameFailed then
		anyFailed = true
	end
	printStage("game", not gameFailed, table.concat(gameLogs, "\n"))

	-- Stage d2: asset manifests must gate cleanly and Assets.luau must not drift.
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
	if assetsFailed then
		anyFailed = true
	end
	printStage("assets", not assetsFailed, table.concat(assetsLogs, "\n"))

	-- Stage d4: every pack's locale table must cover its client literals and ko-kr.
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
	if localeFailed then
		anyFailed = true
	end
	printStage("locale", not localeFailed, table.concat(localeLogs, "\n"))

	-- Stage e: forge-lock pins must match the packages the pack references.
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
	if lockFailed then
		anyFailed = true
	end
	printStage("lock", not lockFailed, table.concat(lockLogs, "\n"))

	-- Stage f: specs, run as a child process so a broken module cannot wedge the checker
	local specsRes = run.exec("lune", { "run", "cli/forge", "specs-run" })
	local specsOut = specsRes.stdout
	if specsRes.stderr ~= "" then
		specsOut = specsOut .. "\n" .. specsRes.stderr
	end
	if not specsRes.ok then
		anyFailed = true
		printStage("specs", false, specsOut)
	else
		printStage("specs", true, specsOut)
	end

	-- Stage g/h: build and inspect every selected target. With no selector this
	-- is every declared pack under `games`; `--packs-root <dir>` swaps the
	-- discovery root (QA build matrices) for this stage only - every other stage
	-- keeps checking the repository's real packs. Each target is independent:
	-- one failing build never stops another target, and a target whose build
	-- failed is never inspected, so no stale artifact can report a pass.
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

	if buildFailed then
		anyFailed = true
	end
	printStage("build", not buildFailed, table.concat(buildLogs, "\n"))
	if inspectFailed then
		anyFailed = true
	end
	printStage("inspect", not inspectFailed, table.concat(inspectLogs, "\n"))

	return not anyFailed
end

return M
