--!strict
-- `forge qa plan [--pack <slug>]`: read the pack's game.yml genres and
-- qa_scenarios, load the matching genre scenario files, validate them against
-- the pack's deterministic monetization, and write reports/qa-plan-<pack>.md.
-- `forge qa validate`: validate every genres/*/qa-scenarios/*.yml and exit 1
-- with `file: reason` for each violation.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local qa = require("../lib/qa")
local qascenario = require("../lib/qascenario")
local qaharness = require("../lib/qaharness")
local qastudio = require("../lib/qastudio")
local contract = require("../lib/genrecontract")
local registryLib = require("../lib/genreregistry")
local cliutil = require("../lib/cliutil")
local gameyml = require("../lib/gameyml")
local publication = require("../lib/packpublication")
local Journal = require("../../../core/domain/command/Journal")

local M = {}

local DEFAULT_PACK = "kaiju-egg-raiders"

-- purchase_sim slot -> the game.yml monetization list that declares it.
local SLOT_FIELDS: { [string]: string } = {
	gamepass = "gamepasses",
	product = "products",
	subscription = "subscriptions",
}

local function listYaml(dir: string): { string }
	local files: { string } = {}
	if not fs.isDir(dir) then
		return files
	end
	for _, entry in fs.readDir(dir) do
		if string.match(entry, "%.yml$") ~= nil then
			table.insert(files, entry)
		end
	end
	table.sort(files)
	return files
end

function M.validateRegistry(registry: registryLib.Registry): { string }
	local errors: { string } = {}
	for _, id in registry.order do
		local package = registry.packages[id]
		local dir = package.path .. "/qa-scenarios"
		for _, file in listYaml(dir) do
			local path = dir .. "/" .. file
			local scenario, reason = qa.decode(fs.readFile(path))
			if not scenario then
				table.insert(errors, path .. ": " .. tostring(reason))
			elseif scenario.kind == "native" or scenario.kind == "studio" then
				-- Executable run scenario: validated by the run schema, not the
				-- legacy plan schema, which knows none of these operations.
				for _, err in qascenario.validate(scenario) do
					table.insert(errors, path .. ": " .. err)
				end
				if scenario.genre ~= id then
					table.insert(errors, path .. ": genre does not match its directory")
				end
				if scenario.name ~= string.gsub(file, "%.yml$", "") then
					table.insert(errors, path .. ": name does not match its file")
				end
			else
				for _, err in
					qa.validate(scenario, {
						expectedGenre = id,
						expectedName = string.gsub(file, "%.yml$", ""),
						operations = package.generator.qa.operations,
						targets = package.generator.qa.targets,
					})
				do
					table.insert(errors, path .. ": " .. err)
				end
			end
		end
	end
	table.sort(errors)
	return errors
end
function M.planPack(_pack: string, game: any, registry: registryLib.Registry): ({ qa.Entry }, { string })
	local entries: { qa.Entry } = {}
	if not contract.dense(game.genres, 64) or not contract.dense(game.qa_scenarios, 1024) then
		return entries, { "malformed genre/scenario list" }
	end
	local errors: { string } = {}
	local slots = {}
	if type(game.monetization) == "table" then
		for slot, field in SLOT_FIELDS do
			if type(game.monetization[field]) == "table" and #game.monetization[field] > 0 then
				slots[slot] = true
			end
		end
	end
	for _, id in game.genres do
		local package = registry.packages[id]
		if not package then
			continue
		end
		for _, requested in game.qa_scenarios do
			if type(requested) ~= "string" then
				continue
			end
			local name = requested
			if game.genre_contract ~= nil then
				local genre, localName = string.match(requested, "^([^:]+):([^:]+)$")
				if genre ~= id or not localName then
					continue
				end
				name = localName
			end
			if not contract.id(name) then
				table.insert(errors, "unsafe scenario name: " .. name)
				continue
			end
			local path = package.path .. "/qa-scenarios/" .. name .. ".yml"
			if fs.isFile(path) then
				local scenario, reason = qa.decode(fs.readFile(path))
				if not scenario then
					table.insert(errors, path .. ": " .. tostring(reason))
				else
					local executable = scenario.kind == "native" or scenario.kind == "studio"
					local violations: { string } = if executable
						then qascenario.validate(scenario)
						else qa.validate(scenario, {
							expectedGenre = id,
							expectedName = name,
							availableSlots = slots,
							operations = package.generator.qa.operations,
							targets = package.generator.qa.targets,
						})
					if executable and (scenario.genre ~= id or scenario.name ~= name) then
						table.insert(violations, "scenario identity does not match selection")
					end
					for _, err in violations do
						table.insert(errors, path .. ": " .. err)
					end
					table.insert(entries, { genre = id, scenario = scenario })
				end
			end
		end
	end
	for _, err in qa.selection(game, registry, entries) do
		table.insert(errors, err)
	end
	table.sort(errors)
	return entries, errors
end
local function runPlan(pack: string, registry: registryLib.Registry, context: cliutil.CommandContext?): boolean
	local pending =
		publication.pending((if context and context.packsDir then context.packsDir else "games") .. "/" .. pack)
	if pending then
		stdio.ewrite(pending .. "\n")
		return false
	end
	local path = (if context and context.packsDir then context.packsDir else "games") .. "/" .. pack .. "/game.yml"
	local ok, game = pcall(function()
		return serde.decode("yaml", fs.readFile(path))
	end)
	if not ok or type(game) ~= "table" then
		stdio.ewrite("Error: invalid " .. path .. string.char(10))
		return false
	end
	local entries, errors = M.planPack(pack, game, registry)
	if game.genre_contract ~= nil then
		local configPath = (if context and context.packsDir then context.packsDir else "games")
			.. "/"
			.. pack
			.. "/econ.yml"
		local configOk, config = pcall(function()
			return serde.decode("yaml", fs.readFile(configPath))
		end)
		local result = gameyml.validate(game, { registry = registry, config = if configOk then config else nil })
		for _, err in result.errors do
			table.insert(errors, err)
		end
	end
	if #errors > 0 then
		stdio.ewrite(table.concat(errors, string.char(10)) .. string.char(10))
		return false
	end
	local reports = if context and context.reportsDir then context.reportsDir else "reports"
	if not fs.isDir(reports) then
		fs.writeDir(reports)
	end
	fs.writeFile(
		reports .. "/qa-plan-" .. pack .. ".md",
		qa.renderPlan({ pack = pack, genres = game.genres, scenarioNames = game.qa_scenarios, entries = entries })
	)
	return true
end
--- Loads the real pack target a native scenario runs against: the pack's own
--- genre_contract config and the matching runtime contracts from the registry.
--- No fabricated config: if the pack does not declare one, the run FAILS.
function M.loadTarget(
	pack: string,
	registry: registryLib.Registry,
	context: cliutil.CommandContext?,
	packsRoot: string?
): (qaharness.Target?, { string })
	local packsDir = packsRoot or (if context and context.packsDir then context.packsDir else "games")
	local packDir = packsDir .. "/" .. pack
	local pending = publication.pending(packDir)
	if pending then
		return nil, { pending }
	end
	local econPath = packDir .. "/econ.yml"
	if not fs.isFile(econPath) then
		return nil, { econPath .. ": missing pack config" }
	end
	local ok, config = pcall(function()
		return serde.decode("yaml", fs.readFile(econPath))
	end)
	if not ok or type(config) ~= "table" or type(config.genre_contract) ~= "table" then
		return nil, { econPath .. ": pack declares no genre_contract config" }
	end
	local packConfig = config.genre_contract
	local errors = contract.validatePack(packConfig, registry.runtimes)
	if #errors > 0 then
		return nil, errors
	end
	local contracts = {}
	for _, id in packConfig.order do
		table.insert(contracts, registry.runtimes[id])
	end
	return {
		packConfig = packConfig,
		contracts = contracts,
		controls = {},
		storeName = string.sub(pack, 1, 40) .. "-qa",
	}, {}
end

--- The pack's declared genres, for narrowing a bare scenario name. A pack that
--- cannot be read narrows nothing.
local function packGenres(packDir: string): { string }
	if not fs.isFile(packDir .. "/game.yml") then
		return {}
	end
	local ok, game = pcall(function()
		return serde.decode("yaml", fs.readFile(packDir .. "/game.yml"))
	end)
	if not ok or type(game) ~= "table" or type(game.genres) ~= "table" then
		return {}
	end
	local genres: { string } = {}
	for _, id in game.genres do
		if type(id) == "string" then
			table.insert(genres, id)
		end
	end
	return genres
end

export type Resolution = { path: string, genre: string, name: string }

--- Resolves a scenario reference for a pack.
---
--- A namespaced reference (`<genre>:<name>`) resolves directly, pack-local first,
--- so no directory order can decide it. A bare name is accepted only as a legacy
--- alias when exactly one of the pack's genres ships it; two candidates are a
--- usage error naming the namespaced forms. `:` is not a legal Windows file name
--- character, so a pack-local artifact uses the dotted form `<genre>.<name>.yml`
--- while the scenario's own genre and name fields carry the identity.
function M.resolveScenario(
	reference: string,
	pack: string,
	packsDir: string,
	registry: registryLib.Registry
): (Resolution?, { string })
	local genre, name = string.match(reference, "^([^:]+):([^:]+)$")
	if genre ~= nil and name ~= nil then
		if not contract.id(genre) or not contract.id(name) then
			return nil, { string.format("Error: unsafe scenario name '%s'", reference) }
		end
		if registry.packages[genre] == nil then
			return nil, { string.format("qa run: FAIL unknown genre '%s'", genre) }
		end
		local localPath = string.format("%s/%s/qa-scenarios/%s.%s.yml", packsDir, pack, genre, name)
		if fs.isFile(localPath) then
			return { path = localPath, genre = genre, name = name }, {}
		end
		local genrePath = string.format("%s/qa-scenarios/%s.yml", registry.packages[genre].path, name)
		if fs.isFile(genrePath) then
			return { path = genrePath, genre = genre, name = name }, {}
		end
		return nil, {
			string.format("qa run: FAIL scenario '%s' not found for pack '%s'", reference, pack),
		}
	end
	if not contract.id(reference) then
		return nil, { string.format("Error: unsafe scenario name '%s'", reference) }
	end
	local candidates: { string } = {}
	local seen: { [string]: boolean } = {}
	local function consider(id: string)
		local localPath = string.format("%s/%s/qa-scenarios/%s.%s.yml", packsDir, pack, id, reference)
		if fs.isFile(localPath) and not seen[localPath] then
			seen[localPath] = true
			table.insert(candidates, localPath)
			return
		end
		if registry.packages[id] == nil then
			return
		end
		local genrePath = string.format("%s/qa-scenarios/%s.yml", registry.packages[id].path, reference)
		if fs.isFile(genrePath) and not seen[genrePath] then
			seen[genrePath] = true
			table.insert(candidates, genrePath)
		end
	end
	local narrowed = packGenres(packsDir .. "/" .. pack)
	local ids: { string } = if #narrowed > 0 then narrowed else registry.order
	for _, id in ids do
		consider(id)
	end
	if #candidates == 0 then
		return nil, {
			string.format("qa run: FAIL scenario '%s' not found for pack '%s'", reference, pack),
		}
	end
	if #candidates > 1 then
		local forms: { string } = {}
		for _, path in candidates do
			local tail = string.match(path, "qa%-scenarios/(.+)%.yml$") or path
			local dottedGenre, dottedName = string.match(tail, "^([^%.]+)%.(.+)$")
			if dottedGenre ~= nil and dottedName ~= nil then
				table.insert(forms, dottedGenre .. ":" .. dottedName)
			else
				local found = nil
				for id in registry.packages do
					if string.sub(path, 1, #registry.packages[id].path) == registry.packages[id].path then
						found = id
					end
				end
				table.insert(forms, tostring(found) .. ":" .. tail)
			end
		end
		table.sort(forms)
		return nil,
			{
				string.format(
					"Error: scenario name '%s' is ambiguous for pack '%s'; use %s",
					reference,
					pack,
					table.concat(forms, " or ")
				),
			}
	end
	local path = candidates[1]
	local tail = string.match(path, "qa%-scenarios/(.+)%.yml$") or path
	local dottedGenre, dottedName = string.match(tail, "^([^%.]+)%.(.+)$")
	if dottedGenre ~= nil and dottedName ~= nil then
		return { path = path, genre = dottedGenre, name = dottedName }, {}
	end
	for id in registry.packages do
		if string.sub(path, 1, #registry.packages[id].path) == registry.packages[id].path then
			return { path = path, genre = id, name = tail }, {}
		end
	end
	return nil, { string.format("qa run: FAIL scenario '%s' is not a genre scenario", reference) }
end

--- `forge qa run --pack <slug> --scenario <name> [--native|--studio] [--record <journal.json>]`.
--- A missing scenario file, a scenario that drives nothing, and an
--- unreachable Studio client are all FAIL. There is no skip path.
function M.runScenario(args: { string }, registry: registryLib.Registry, context: cliutil.CommandContext?): boolean
	local pack: string? = nil
	local scenarioName: string? = nil
	local evidencePath: string? = nil
	local receiptPath: string? = nil
	local packsRoot: string? = nil
	local recordPath: string? = nil
	local mode: string? = nil
	local bootstrapOwned = false
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag == "--bootstrap-owned" then
			if bootstrapOwned then
				stdio.ewrite("Error: duplicate --bootstrap-owned\n")
				return false
			end
			bootstrapOwned = true
			index += 1
			continue
		end
		if flag == "--native" or flag == "--studio" then
			if mode ~= nil then
				stdio.ewrite("Error: --native and --studio are mutually exclusive\n")
				return false
			end
			mode = string.sub(flag, 3)
			index += 1
			continue
		end
		local value = args[index + 1]
		if value == nil or value == "" then
			stdio.ewrite("Error: " .. tostring(flag) .. " requires a value\n")
			return false
		end
		if flag == "--pack" then
			pack = value
		elseif flag == "--scenario" then
			scenarioName = value
		elseif flag == "--evidence" then
			evidencePath = value
		elseif flag == "--studio-receipt" then
			receiptPath = value
		elseif flag == "--packs-root" then
			packsRoot = value
		elseif flag == "--record" then
			recordPath = value
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge qa run\n")
			return false
		end
		index += 2
	end
	if pack == nil or scenarioName == nil then
		stdio.ewrite("Error: forge qa run requires --pack <slug> and --scenario <name>\n")
		return false
	end
	if not contract.id(scenarioName) and string.match(scenarioName, "^[a-z][a-z0-9%-]*:[a-z][a-z0-9%-]*$") == nil then
		stdio.ewrite("Error: unsafe scenario name '" .. tostring(scenarioName) .. "'\n")
		return false
	end
	mode = mode or "native"
	if bootstrapOwned and (mode ~= "studio" or receiptPath == nil or evidencePath == nil) then
		stdio.ewrite("Error: --bootstrap-owned requires --studio, --studio-receipt and --evidence\n")
		return false
	end
	local pending = publication.pending(
		(packsRoot or (if context and context.packsDir then context.packsDir else "games")) .. "/" .. pack
	)
	if pending then
		stdio.ewrite(pending .. "\n")
		return false
	end

	-- Locate the scenario for THIS pack. A namespaced reference resolves directly
	-- and a bare name resolves only when it is unambiguous, so no directory order
	-- decides which genre a scenario came from. A scenario that does not exist is
	-- a FAIL, never a silently empty run.
	local packsDir = packsRoot or (if context and context.packsDir then context.packsDir else "games")
	local resolution, resolutionErrors = M.resolveScenario(scenarioName :: string, pack :: string, packsDir, registry)
	if resolution == nil then
		for _, err in resolutionErrors do
			stdio.ewrite(err .. "\n")
		end
		return false
	end
	local scenarioPath: string = resolution.path
	local decodeOk, raw = pcall(function()
		return serde.decode("yaml", fs.readFile(scenarioPath))
	end)
	if not decodeOk then
		stdio.ewrite("qa run: FAIL " .. (scenarioPath :: string) .. ": " .. tostring(raw) .. "\n")
		return false
	end
	if raw.kind ~= "native" and raw.kind ~= "studio" then
		stdio.ewrite(
			string.format(
				"qa run: FAIL %s is a legacy '%s' scenario for `qa plan`/`qa validate`, not an executable run scenario (kind must be native|studio)\n",
				scenarioPath :: string,
				tostring(raw.kind)
			)
		)
		return false
	end
	if raw.contract_api ~= qascenario.CONTRACT_API then
		stdio.ewrite(
			string.format(
				"qa run: FAIL %s declares unsupported contract_api %s\n",
				scenarioPath :: string,
				tostring(raw.contract_api)
			)
		)
		return false
	end
	local scenarioErrors = qascenario.validate(raw)
	if #scenarioErrors > 0 then
		for _, err in scenarioErrors do
			stdio.ewrite((scenarioPath :: string) .. ": " .. err .. "\n")
		end
		return false
	end
	-- The crafting bootstrap is the mandatory reusable scenario for generated
	-- crafting packs; every other scenario retains its exact pack binding.
	local craftingBootstrap = raw.genre == "survival-coop" and raw.name == "bootstrap-crafting"
	if raw.pack ~= pack and not craftingBootstrap then
		stdio.ewrite(
			string.format("qa run: FAIL scenario declares pack '%s' but --pack is '%s'\n", tostring(raw.pack), pack)
		)
		return false
	end

	local outcome: any
	local startedAt = os.clock()
	if mode == "studio" then
		if recordPath ~= nil then
			stdio.ewrite("Error: --record requires a native run\n")
			return false
		end
		if raw.kind ~= "studio" then
			stdio.ewrite("qa run: FAIL --studio requires a scenario of kind 'studio'\n")
			return false
		end
		local studioOutcome = qastudio.run(raw, receiptPath, bootstrapOwned)
		for _, blocker in studioOutcome.blockers do
			stdio.ewrite("qa run: BLOCKED " .. blocker .. "\n")
		end
		outcome = studioOutcome
	else
		if raw.kind ~= "native" then
			stdio.ewrite("qa run: FAIL a studio scenario cannot be satisfied by a native run\n")
			return false
		end
		local target, targetErrors = M.loadTarget(pack :: string, registry, context, packsRoot)
		if target == nil then
			for _, err in targetErrors do
				stdio.ewrite("qa run: FAIL " .. err .. "\n")
			end
			return false
		end
		if craftingBootstrap and target.packConfig.configs["survival-coop"].mode ~= "crafting" then
			stdio.ewrite("qa run: FAIL bootstrap-crafting requires crafting config\n")
			return false
		end
		-- The journal names the scenario as <genre>:<name> so replay resolves it
		-- the same way; bind reusable scenarios to the target actually executed.
		local journal = if recordPath ~= nil
			then Journal.new({
				seed = raw.seed or 0,
				genre = raw.genre,
				scenario = raw.genre .. ":" .. raw.name,
				pack = pack,
			})
			else nil
		local nativeOutcome = qaharness.runNative(raw, target :: qaharness.Target, nil, { journal = journal })
		for _, failure in nativeOutcome.failures do
			stdio.ewrite("qa run: FAIL " .. failure .. "\n")
		end
		if journal ~= nil and recordPath ~= nil then
			local dir = string.match(recordPath, "^(.*)/[^/]+$")
			if dir ~= nil and not fs.isDir(dir) then
				fs.writeDir(dir)
			end
			fs.writeFile(recordPath, Journal.encode(journal) .. "\n")
		end
		outcome = nativeOutcome
	end

	local packSlug = pack :: string
	local scenarioId = scenarioName :: string
	local runMode = mode :: string
	if evidencePath ~= nil then
		local dir = string.match(evidencePath, "^(.*)/[^/]+$")
		if dir ~= nil and not fs.isDir(dir) then
			fs.writeDir(dir)
		end
		fs.writeFile(evidencePath, serde.encode("json", {
			command = string.format(
				"lune run cli/forge qa run --pack %s --scenario %s --%s",
				packSlug,
				scenarioId,
				runMode .. (if bootstrapOwned then " --bootstrap-owned" else "")
			),
			scenario = scenarioPath,
			mode = runMode,
			outcome = outcome,
		}, true) .. "\n")
		if bootstrapOwned then
			assert(outcome.discovery ~= nil, "BOOTSTRAP_DISCOVERY_REQUIRED")
			fs.writeFile(evidencePath .. ".discovery.json", serde.encode("json", outcome.discovery, true) .. "\n")
		end
	end
	local summary = ""
	if runMode == "native" then
		summary = string.format(
			" steps=%d assertions=%d seed=%s ms=%d",
			#outcome.steps,
			outcome.assertions,
			if outcome.seed ~= nil then string.format("%d", outcome.seed) else "none",
			math.floor((os.clock() - startedAt) * 1000)
		)
	end
	if outcome.ok then
		stdio.write(string.format("qa run: PASS %s (%s)%s\n", scenarioId, runMode, summary))
		return true
	end
	stdio.write(string.format("qa run: FAIL %s (%s)%s\n", scenarioId, runMode, summary))
	return false
end

function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local registry, registryErrors = registryLib.discover(if context then context.genresDir else nil)
	if not registry then
		stdio.ewrite(table.concat(registryErrors, string.char(10)) .. string.char(10))
		return false
	end
	local sub = args[2]
	if sub == "run" then
		return M.runScenario(args, registry, context)
	end
	if sub == "validate" then
		if #args > 2 then
			stdio.ewrite("Error: unknown argument '" .. tostring(args[3]) .. "' for forge qa validate\n")
			return false
		end
		local errors = M.validateRegistry(registry)
		if #errors > 0 then
			stdio.ewrite(table.concat(errors, string.char(10)) .. string.char(10))
			return false
		end
		return true
	end

	if sub == "plan" then
		local pack = DEFAULT_PACK
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
			else
				stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge qa plan\n")
				return false
			end
		end
		return runPlan(pack, registry, context)
	end

	stdio.ewrite("Error: forge qa requires 'run', 'plan' or 'validate', e.g. lune run cli/forge qa validate\n")
	return false
end

return M
